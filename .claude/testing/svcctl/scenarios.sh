# .claude/testing/svcctl/scenarios.sh — scenario matrix for service-manager.sh and
# install_svcctl.sh. Source-only, via run.sh (after lib.sh). Ubuntu only, real
# systemctl/apt-get in a real systemd container. install_svcctl.sh scenarios hit the
# REAL raw.githubusercontent.com/softlyfear/my-script/main URL — they verify the
# currently-pushed origin/main content, not local working-tree edits.
set -euo pipefail

# --- Verify functions for the simple (single-invocation) scenarios ---

verify_usage()          { assert_shell "log contains Usage:" "grep -q 'Usage:' '$2'"; }
verify_invalid_action() { assert_shell "log contains 'Invalid action'" "grep -q 'Invalid action' '$2'"; }
verify_invalid_service() { assert_shell "log contains 'not allowed'" "grep -q 'not allowed' '$2'"; }

verify_status_all_uninstalled() {
  local rc=0
  assert_match "attempted postgresql status" "$(cat "$2")" 'status postgresql' || rc=1
  assert_match "attempted docker status"     "$(cat "$2")" 'status docker'     || rc=1
  return "$rc"
}

# --- Presetup helpers ---

presetup_install_postgresql() { docker exec "$1" bash -c 'apt-get update -qq && apt-get install -y -qq postgresql >/dev/null'; }
presetup_install_docker()     { docker exec "$1" bash -c 'apt-get update -qq && apt-get install -y -qq docker.io >/dev/null'; }
presetup_install_both()       { presetup_install_postgresql "$1"; presetup_install_docker "$1"; }
presetup_remove_wget()        { docker exec "$1" bash -c 'apt-get remove -y -qq wget >/dev/null'; }
presetup_remove_sudo() {
  # sudo's prerm script refuses removal without a root password set, unless this is
  # exported — a real safety guard in the package itself, not something worth testing.
  docker exec "$1" bash -c 'SUDO_FORCE_REMOVE=yes apt-get remove -y --purge -qq sudo >/dev/null'
}
presetup_nonroot_user() {
  docker exec "$1" useradd -m -s /bin/bash svctester
  docker exec "$1" bash -c "echo 'svctester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/svctester && chmod 440 /etc/sudoers.d/svctester"
}

# --- Orchestration ---

run_all_scenarios() {
  sep; info "service-manager.sh: argument parsing"; sep

  run_simple_scenario 01_TOO_FEW_ARGS 1 verify_usage - start || true
  run_simple_scenario 02_INVALID_ACTION 1 verify_invalid_action - fakeaction postgresql || true
  run_simple_scenario 03_INVALID_SERVICE 1 verify_invalid_service - start bogus-service || true

  sep; info "service-manager.sh: status against uninstalled services (should warn, not fail)"; sep
  run_simple_scenario 04_STATUS_ALL_UNINSTALLED 0 verify_status_all_uninstalled - status all || true

  sep; info "05 — postgresql lifecycle (start/status/restart/enable/disable/stop + pg alias)"; sep
  run_postgresql_lifecycle || true

  sep; info "06 — docker lifecycle (start/status/restart/enable/disable/stop)"; sep
  run_docker_lifecycle || true

  sep; info "07 — 'all' target reaches both services"; sep
  run_all_target_status || true

  sep; info "install_svcctl.sh: fresh install + idempotent reinstall"; sep
  run_install_fresh_then_idempotent || true

  sep; info "08 — install_svcctl.sh: missing required command (wget)"; sep
  run_install_missing_wget || true

  sep; info "09 — install_svcctl.sh: non-root with NOPASSWD sudo"; sep
  run_install_nonroot_sudo || true

  sep; info "10 — install_svcctl.sh: non-root, sudo absent"; sep
  run_install_nonroot_no_sudo || true
}

run_postgresql_lifecycle() {
  local scen_id="05_POSTGRESQL_LIFECYCLE"
  local log="${RESULTS_DIR}/${scen_id}.log"
  local out tag cname
  out="$(start_scenario_container "$scen_id")" || return 1
  read -r tag cname <<< "$out"
  presetup_install_postgresql "$cname"

  local rc=0 status="PASS" note=""
  {
    run_svcctl "$cname" "$log" start postgresql || { status="FAIL"; note="start failed"; }
    docker exec "$cname" systemctl is-active --quiet postgresql \
      || { status="FAIL"; note="not active after start"; }
    run_svcctl "$cname" "$log" restart postgresql \
      || { status="FAIL"; note="restart failed"; }
    docker exec "$cname" systemctl is-active --quiet postgresql \
      || { status="FAIL"; note="not active after restart"; }
    run_svcctl "$cname" "$log" enable postgresql \
      || { status="FAIL"; note="enable failed"; }
    docker exec "$cname" systemctl is-enabled --quiet postgresql \
      || { status="FAIL"; note="not enabled after enable"; }
    run_svcctl "$cname" "$log" status pg \
      || { status="FAIL"; note="status via 'pg' alias failed"; }
    run_svcctl "$cname" "$log" disable postgresql \
      || { status="FAIL"; note="disable failed"; }
    docker exec "$cname" systemctl is-enabled --quiet postgresql \
      && { status="FAIL"; note="still enabled after disable"; }
    run_svcctl "$cname" "$log" stop postgresql \
      || { status="FAIL"; note="stop failed"; }
    docker exec "$cname" systemctl is-active --quiet postgresql \
      && { status="FAIL"; note="still active after stop"; }
  } >>"$log" 2>&1 || true

  record_result "$scen_id" "$status" "$note"
  cleanup_scenario "$cname" "$tag"
}

run_docker_lifecycle() {
  local scen_id="06_DOCKER_LIFECYCLE"
  local log="${RESULTS_DIR}/${scen_id}.log"
  local out tag cname
  out="$(start_scenario_container "$scen_id")" || return 1
  read -r tag cname <<< "$out"
  presetup_install_docker "$cname"

  local status="PASS" note=""
  {
    run_svcctl "$cname" "$log" start docker || { status="FAIL"; note="start failed"; }
    docker exec "$cname" systemctl is-active --quiet docker \
      || { status="FAIL"; note="not active after start"; }
    run_svcctl "$cname" "$log" restart docker \
      || { status="FAIL"; note="restart failed"; }
    run_svcctl "$cname" "$log" enable docker \
      || { status="FAIL"; note="enable failed"; }
    docker exec "$cname" systemctl is-enabled --quiet docker \
      || { status="FAIL"; note="not enabled after enable"; }
    run_svcctl "$cname" "$log" disable docker \
      || { status="FAIL"; note="disable failed"; }
    run_svcctl "$cname" "$log" stop docker \
      || { status="FAIL"; note="stop failed"; }
    docker exec "$cname" systemctl is-active --quiet docker \
      && { status="FAIL"; note="still active after stop"; }
  } >>"$log" 2>&1 || true

  record_result "$scen_id" "$status" "$note"
  cleanup_scenario "$cname" "$tag"
}

run_all_target_status() {
  local scen_id="07_ALL_TARGET_STATUS"
  local log="${RESULTS_DIR}/${scen_id}.log"
  local out tag cname
  out="$(start_scenario_container "$scen_id")" || return 1
  read -r tag cname <<< "$out"
  presetup_install_both "$cname"

  local rc=0
  run_svcctl "$cname" "$log" status all || rc=$?

  local status="PASS" note=""
  if [[ "$rc" != 0 ]]; then
    status="FAIL"; note="exit=$rc, expected 0"
  else
    assert_match "reached postgresql" "$(cat "$log")" 'status postgresql' >>"$log" 2>&1 || { status="FAIL"; note="postgresql not reached"; }
    assert_match "reached docker"     "$(cat "$log")" 'status docker'     >>"$log" 2>&1 || { status="FAIL"; note="docker not reached"; }
  fi
  record_result "$scen_id" "$status" "$note"
  cleanup_scenario "$cname" "$tag"
}

run_install_fresh_then_idempotent() {
  local scen_id="INSTALL_SVCCTL_FRESH_AND_IDEMPOTENT"
  local log1="${RESULTS_DIR}/${scen_id}_fresh.log" log2="${RESULTS_DIR}/${scen_id}_idempotent.log"
  local out tag cname
  out="$(start_scenario_container "$scen_id")" || return 1
  read -r tag cname <<< "$out"

  local rc1=0 rc2=0
  run_install_svcctl "$cname" "$log1" || rc1=$?

  local status="PASS" note=""
  if [[ "$rc1" != 0 ]]; then
    status="FAIL"; note="fresh install exit=$rc1 (see $log1)"
  else
    assert_shell "svctl installed at /usr/local/bin/svcctl" "docker exec $cname test -x /usr/local/bin/svcctl" >>"$log1" 2>&1 \
      || { status="FAIL"; note="binary missing after install"; }
    assert_shell "svcctl owned by root:root" "[ \"\$(docker exec $cname stat -c '%U:%G' /usr/local/bin/svcctl)\" = 'root:root' ]" >>"$log1" 2>&1 \
      || { status="FAIL"; note="wrong ownership"; }
    assert_shell "svcctl mode 755" "[ \"\$(docker exec $cname stat -c '%a' /usr/local/bin/svcctl)\" = '755' ]" >>"$log1" 2>&1 \
      || { status="FAIL"; note="wrong permissions"; }
    assert_shell "installed svcctl runs (usage on bad args)" "docker exec $cname svcctl 2>&1 | grep -q Usage:" >>"$log1" 2>&1 \
      || { status="FAIL"; note="installed binary does not run"; }

    run_install_svcctl "$cname" "$log2" || rc2=$?
    if [[ "$rc2" != 0 ]]; then
      status="FAIL"; note="idempotent reinstall exit=$rc2 (see $log2)"
    else
      assert_shell "idempotent rerun reports already up to date" "grep -q 'already up to date' '$log2'" >>"$log2" 2>&1 \
        || { status="FAIL"; note="idempotent rerun did not short-circuit"; }
    fi
  fi

  record_result "$scen_id" "$status" "$note"
  cleanup_scenario "$cname" "$tag"
}

run_install_missing_wget() {
  local scen_id="08_INSTALL_SVCCTL_MISSING_WGET"
  local log="${RESULTS_DIR}/${scen_id}.log"
  local out tag cname
  out="$(start_scenario_container "$scen_id")" || return 1
  read -r tag cname <<< "$out"
  presetup_remove_wget "$cname"

  local rc=0
  run_install_svcctl "$cname" "$log" || rc=$?

  local status="PASS" note=""
  if [[ "$rc" != 1 ]]; then
    status="FAIL"; note="exit=$rc, expected 1"
  else
    assert_shell "log names wget as the missing command" "grep -q 'Required command not found: wget' '$log'" >>"$log" 2>&1 \
      || { status="FAIL"; note="wrong/missing error message"; }
  fi
  record_result "$scen_id" "$status" "$note"
  cleanup_scenario "$cname" "$tag"
}

run_install_nonroot_sudo() {
  local scen_id="09_INSTALL_SVCCTL_NONROOT_SUDO"
  local log="${RESULTS_DIR}/${scen_id}.log"
  local out tag cname
  out="$(start_scenario_container "$scen_id")" || return 1
  read -r tag cname <<< "$out"
  presetup_nonroot_user "$cname"

  local rc=0
  run_install_svcctl "$cname" "$log" -u svctester || rc=$?

  local status="PASS" note=""
  if [[ "$rc" != 0 ]]; then
    status="FAIL"; note="exit=$rc, expected 0 (see $log)"
  else
    assert_shell "svcctl installed via sudo path" "docker exec $cname test -x /usr/local/bin/svcctl" >>"$log" 2>&1 \
      || { status="FAIL"; note="binary missing"; }
    assert_shell "svcctl still root-owned despite non-root installer" "[ \"\$(docker exec $cname stat -c '%U' /usr/local/bin/svcctl)\" = 'root' ]" >>"$log" 2>&1 \
      || { status="FAIL"; note="not root-owned"; }
  fi
  record_result "$scen_id" "$status" "$note"
  cleanup_scenario "$cname" "$tag"
}

run_install_nonroot_no_sudo() {
  local scen_id="10_INSTALL_SVCCTL_NONROOT_NO_SUDO"
  local log="${RESULTS_DIR}/${scen_id}.log"
  local out tag cname
  out="$(start_scenario_container "$scen_id")" || return 1
  read -r tag cname <<< "$out"
  presetup_nonroot_user "$cname"
  presetup_remove_sudo "$cname"

  local rc=0
  run_install_svcctl "$cname" "$log" -u svctester || rc=$?

  local status="PASS" note=""
  if [[ "$rc" != 1 ]]; then
    status="FAIL"; note="exit=$rc, expected 1"
  else
    assert_shell "log names sudo as required" "grep -q 'sudo is required when running as non-root user' '$log'" >>"$log" 2>&1 \
      || { status="FAIL"; note="wrong/missing error message"; }
  fi
  record_result "$scen_id" "$status" "$note"
  cleanup_scenario "$cname" "$tag"
}
