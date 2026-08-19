# shellcheck shell=bash
# .claude/testing/sysupdate/scenarios.sh — scenario matrix for update_system_all.sh and
# install_sysupdate.sh. Source-only, via run.sh (after lib.sh). Ubuntu only, real
# apt-get in a real systemd container. install_sysupdate.sh scenarios hit the REAL
# raw.githubusercontent.com/softlyfear/my-script/main URL — they verify the
# currently-pushed origin/main content, not local working-tree edits.
set -euo pipefail

presetup_reboot_required() { docker exec "$1" bash -c 'touch /var/run/reboot-required'; }
presetup_remove_wget() { docker exec "$1" bash -c 'apt-get remove -y -qq wget >/dev/null'; }
presetup_remove_sudo() {
  # sudo's prerm script refuses removal without a root password set, unless this is
  # exported — a real safety guard in the package itself, not something worth testing.
  docker exec "$1" bash -c 'SUDO_FORCE_REMOVE=yes apt-get remove -y --purge -qq sudo >/dev/null'
}
presetup_nonroot_user() {
  docker exec "$1" useradd -m -s /bin/bash updatetester
  docker exec "$1" bash -c "echo 'updatetester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/updatetester && chmod 440 /etc/sudoers.d/updatetester"
}

verify_fresh_run() {
  local rc=0
  assert_shell "APT step completed" "grep -q 'APT updates completed' '$2'" || rc=1
  assert_shell "snap absent, skipped" "grep -q 'snap not found, skipping' '$2'" || rc=1
  assert_shell "flatpak absent, skipped" "grep -q 'flatpak not found, skipping' '$2'" || rc=1
  assert_shell "overall completion" "grep -q 'System update complete' '$2'" || rc=1
  assert_shell "no reboot-required warning" "! grep -q 'REBOOT REQUIRED' '$2'" || rc=1
  return "${rc}"
}

verify_reboot_required() { assert_shell "log warns REBOOT REQUIRED" "grep -q 'REBOOT REQUIRED' '$2'"; }

verify_nonroot_sudo_run() { assert_shell "APT step completed as non-root+sudo" "grep -q 'APT updates completed' '$2'"; }

verify_nonroot_no_sudo() { assert_shell "log demands sudo" "grep -q 'sudo is required when running as non-root user' '$2'"; }

run_all_scenarios() {
  sep
  info "01 — fresh full run (apt update/full-upgrade/autoremove/autoclean, snap+flatpak absent)"
  sep
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  run_simple 01_FRESH_FULL_RUN 0 verify_fresh_run - run_update_system_all || true

  sep
  info "02 — reboot-required file present"
  sep
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  run_simple 02_REBOOT_REQUIRED 0 verify_reboot_required presetup_reboot_required run_update_system_all || true

  sep
  info "03 — non-root with NOPASSWD sudo"
  sep
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  run_simple 03_NONROOT_SUDO 0 verify_nonroot_sudo_run presetup_nonroot_user run_update_system_all -u updatetester || true

  sep
  info "04 — non-root, sudo absent"
  sep
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  run_nonroot_no_sudo || true

  sep
  info "05 — idempotency: re-run on the same container"
  sep
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  run_idempotent_rerun || true

  sep
  info "install_sysupdate.sh: fresh install + idempotent reinstall"
  sep
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  run_install_fresh_then_idempotent || true

  sep
  info "06 — install_sysupdate.sh: missing required command (wget)"
  sep
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  run_install_missing_wget || true

  sep
  info "07 — install_sysupdate.sh: non-root with NOPASSWD sudo"
  sep
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  run_install_nonroot_sudo || true

  sep
  info "08 — install_sysupdate.sh: non-root, sudo absent"
  sep
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  run_install_nonroot_no_sudo || true
}

# run_simple <id> <expected_exit> <verify_fn|-> <presetup_fn|-> <runner_fn> [runner_extra_args...]
run_simple() {
  local scen_id="$1" expected_exit="$2" verify_fn="$3" presetup_fn="$4" runner_fn="$5"
  shift 5
  # shellcheck disable=SC2154 # set as readonly by run.sh before this file is sourced
  local log_file="${RESULTS_DIR}/${scen_id}.log"
  local out tag cname
  out="$(start_scenario_container "${scen_id}")" || return 1
  IFS=' ' read -r tag cname <<< "${out}"

  [[ "${presetup_fn}" != "-" ]] && "${presetup_fn}" "${cname}"

  local rc=0
  "${runner_fn}" "${cname}" "${log_file}" "$@" || rc=$?

  local status="PASS" note=""
  if [[ "${rc}" != "${expected_exit}" ]]; then
    status="FAIL"
    note="exit=${rc}, expected ${expected_exit} (see ${log_file})"
  elif [[ "${verify_fn}" != "-" ]]; then
    # shellcheck disable=SC2094 # the log file is appended to and inspected by the same helper on purpose
    if ! "${verify_fn}" "${cname}" "${log_file}" >> "${log_file}" 2>&1; then
      status="FAIL"
      note="verify failed, see ${log_file}"
    fi
  fi
  record_result "${scen_id}" "${status}" "${note}"
  cleanup_scenario "${cname}" "${tag}"
}

run_nonroot_no_sudo() {
  local scen_id="04_NONROOT_NO_SUDO"
  local log="${RESULTS_DIR}/${scen_id}.log"
  local out tag cname
  out="$(start_scenario_container "${scen_id}")" || return 1
  IFS=' ' read -r tag cname <<< "${out}"
  presetup_nonroot_user "${cname}"
  presetup_remove_sudo "${cname}"

  local rc=0
  run_update_system_all "${cname}" "${log}" -u updatetester || rc=$?

  local status="PASS" note=""
  if [[ "${rc}" != 1 ]]; then
    status="FAIL"
    note="exit=${rc}, expected 1"
  else
    # shellcheck disable=SC2094,SC2310 # the log file is appended to and inspected by the same helper on purpose; predicate; its return code is handled by this conditional
    verify_nonroot_no_sudo "${cname}" "${log}" >> "${log}" 2>&1 || {
      status="FAIL"
      note="wrong/missing error message"
    }
  fi
  record_result "${scen_id}" "${status}" "${note}"
  cleanup_scenario "${cname}" "${tag}"
}

run_idempotent_rerun() {
  local scen_id="05_IDEMPOTENT_RERUN"
  local log1="${RESULTS_DIR}/${scen_id}_run1.log" log2="${RESULTS_DIR}/${scen_id}_run2.log"
  local out tag cname
  out="$(start_scenario_container "${scen_id}")" || return 1
  IFS=' ' read -r tag cname <<< "${out}"

  local rc1=0 rc2=0
  run_update_system_all "${cname}" "${log1}" || rc1=$?
  run_update_system_all "${cname}" "${log2}" || rc2=$?

  local status="PASS" note=""
  if [[ "${rc1}" != 0 || "${rc2}" != 0 ]]; then
    status="FAIL"
    note="run1=${rc1} run2=${rc2} (expected both 0)"
  fi
  record_result "${scen_id}" "${status}" "${note}"
  cleanup_scenario "${cname}" "${tag}"
}

run_install_fresh_then_idempotent() {
  local scen_id="INSTALL_SYSUPDATE_FRESH_AND_IDEMPOTENT"
  local log1="${RESULTS_DIR}/${scen_id}_fresh.log" log2="${RESULTS_DIR}/${scen_id}_idempotent.log"
  local out tag cname
  out="$(start_scenario_container "${scen_id}")" || return 1
  IFS=' ' read -r tag cname <<< "${out}"

  local rc1=0 rc2=0
  run_install_sysupdate "${cname}" "${log1}" || rc1=$?

  local status="PASS" note=""
  if [[ "${rc1}" != 0 ]]; then
    status="FAIL"
    note="fresh install exit=${rc1} (see ${log1})"
  else
    assert_shell "sysupdate installed at /usr/local/bin/sysupdate" "docker exec ${cname} test -x /usr/local/bin/sysupdate" >> "${log1}" 2>&1 \
      || {
        status="FAIL"
        note="binary missing after install"
      }
    assert_shell "sysupdate owned by root:root" "[ \"\$(docker exec ${cname} stat -c '%U:%G' /usr/local/bin/sysupdate)\" = 'root:root' ]" >> "${log1}" 2>&1 \
      || {
        status="FAIL"
        note="wrong ownership"
      }
    assert_shell "sysupdate mode 755" "[ \"\$(docker exec ${cname} stat -c '%a' /usr/local/bin/sysupdate)\" = '755' ]" >> "${log1}" 2>&1 \
      || {
        status="FAIL"
        note="wrong permissions"
      }

    run_install_sysupdate "${cname}" "${log2}" || rc2=$?
    if [[ "${rc2}" != 0 ]]; then
      status="FAIL"
      note="idempotent reinstall exit=${rc2} (see ${log2})"
    else
      assert_shell "idempotent rerun reports already up to date" "grep -q 'already up to date' '${log2}'" >> "${log2}" 2>&1 \
        || {
          status="FAIL"
          note="idempotent rerun did not short-circuit"
        }
    fi
  fi

  record_result "${scen_id}" "${status}" "${note}"
  cleanup_scenario "${cname}" "${tag}"
}

run_install_missing_wget() {
  local scen_id="06_INSTALL_SYSUPDATE_MISSING_WGET"
  local log="${RESULTS_DIR}/${scen_id}.log"
  local out tag cname
  out="$(start_scenario_container "${scen_id}")" || return 1
  IFS=' ' read -r tag cname <<< "${out}"
  presetup_remove_wget "${cname}"

  local rc=0
  run_install_sysupdate "${cname}" "${log}" || rc=$?

  local status="PASS" note=""
  if [[ "${rc}" != 1 ]]; then
    status="FAIL"
    note="exit=${rc}, expected 1"
  else
    assert_shell "log names wget as the missing command" "grep -q 'Required command not found: wget' '${log}'" >> "${log}" 2>&1 \
      || {
        status="FAIL"
        note="wrong/missing error message"
      }
  fi
  record_result "${scen_id}" "${status}" "${note}"
  cleanup_scenario "${cname}" "${tag}"
}

run_install_nonroot_sudo() {
  local scen_id="07_INSTALL_SYSUPDATE_NONROOT_SUDO"
  local log="${RESULTS_DIR}/${scen_id}.log"
  local out tag cname
  out="$(start_scenario_container "${scen_id}")" || return 1
  IFS=' ' read -r tag cname <<< "${out}"
  presetup_nonroot_user "${cname}"

  local rc=0
  run_install_sysupdate "${cname}" "${log}" -u updatetester || rc=$?

  local status="PASS" note=""
  if [[ "${rc}" != 0 ]]; then
    status="FAIL"
    note="exit=${rc}, expected 0 (see ${log})"
  else
    assert_shell "sysupdate installed via sudo path" "docker exec ${cname} test -x /usr/local/bin/sysupdate" >> "${log}" 2>&1 \
      || {
        status="FAIL"
        note="binary missing"
      }
    assert_shell "sysupdate still root-owned despite non-root installer" "[ \"\$(docker exec ${cname} stat -c '%U' /usr/local/bin/sysupdate)\" = 'root' ]" >> "${log}" 2>&1 \
      || {
        status="FAIL"
        note="not root-owned"
      }
  fi
  record_result "${scen_id}" "${status}" "${note}"
  cleanup_scenario "${cname}" "${tag}"
}

run_install_nonroot_no_sudo() {
  local scen_id="08_INSTALL_SYSUPDATE_NONROOT_NO_SUDO"
  local log="${RESULTS_DIR}/${scen_id}.log"
  local out tag cname
  out="$(start_scenario_container "${scen_id}")" || return 1
  IFS=' ' read -r tag cname <<< "${out}"
  presetup_nonroot_user "${cname}"
  presetup_remove_sudo "${cname}"

  local rc=0
  run_install_sysupdate "${cname}" "${log}" -u updatetester || rc=$?

  local status="PASS" note=""
  if [[ "${rc}" != 1 ]]; then
    status="FAIL"
    note="exit=${rc}, expected 1"
  else
    assert_shell "log names sudo as required" "grep -q 'sudo is required when running as non-root user' '${log}'" >> "${log}" 2>&1 \
      || {
        status="FAIL"
        note="wrong/missing error message"
      }
  fi
  record_result "${scen_id}" "${status}" "${note}"
  cleanup_scenario "${cname}" "${tag}"
}
