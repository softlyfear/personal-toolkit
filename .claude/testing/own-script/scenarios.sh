#!/usr/bin/env bash
# .claude/testing/own-script/scenarios.sh — scenario matrix for configuring_server.sh.
# Source-only, via run.sh (after lib.sh). Ubuntu only, full run only, in a real systemd
# container — even the branches that fail on argument parsing use the same image as the
# end-to-end scenarios.
#
# Prompt line format: "<regexp-pattern><TAB><response>". TAB must be a real 0x09 byte
# (the TAB variable, not "\t" — bash doesn't expand that as an escape outside $'...').
# Patterns are short substrings without ( ) [ ] . * + ? to avoid escaping Tcl regexp
# metacharacters.
set -euo pipefail

readonly TAB=$'\t'
readonly MANUAL_TEST_PASSWORD='Str0ngP@ssword!1'

# --- Verify functions ---

verify_help()                 { assert_shell "log contains Usage:" "grep -q 'Usage:' '$2'"; }
verify_bad_port()              { assert_shell "log contains Invalid SSH port" "grep -q 'Invalid SSH port' '$2'"; }
verify_unknown_flag()          { assert_shell "log contains Unknown option" "grep -q 'Unknown option' '$2'"; }
verify_user_root_rejected()    { assert_shell "log contains 'root is not allowed'" "grep -q 'root is not allowed' '$2'"; }
verify_password_file_missing() { assert_shell "log contains 'password-file not found'" "grep -q 'password-file not found' '$2'"; }
verify_invalid_key_rsa()       { assert_shell "log contains ssh-rsa rejection" "grep -q 'ssh-rsa is not supported' '$2'"; }

verify_key_nopasswd() {
  local name="$1" rc=0
  local cfg; cfg="$(sshd_effective "$name")"
  assert_match "AuthenticationMethods=publickey" "$cfg" 'authenticationmethods publickey' || rc=1
  assert_match "PermitRootLogin=no"              "$cfg" 'permitrootlogin no'             || rc=1
  assert_match "Effective port 2244"              "$cfg" 'port 2244'                      || rc=1
  assert_shell "sudoers: NOPASSWD for tester6"    "docker exec $name grep -q NOPASSWD /etc/sudoers.d/tester6" || rc=1
  assert_shell "sshd listening on :2244"          "docker exec $name ss -tln | grep -q ':2244 '"               || rc=1
  assert_shell "UFW: LIMIT on 2244/tcp"           "docker exec $name ufw status | grep -qE '2244/tcp[[:space:]]+LIMIT'" || rc=1
  assert_shell "Fail2Ban active"                  "docker exec $name systemctl is-active --quiet fail2ban"      || rc=1
  assert_shell "ssh.socket masked (port!=22)"     "docker exec $name systemctl is-enabled ssh.socket 2>&1 | grep -q masked" || rc=1
  return "$rc"
}

verify_key_password_autogen() {
  local name="$1" rc=0
  local cfg; cfg="$(sshd_effective "$name")"
  assert_match "Effective port 2255" "$cfg" 'port 2255' || rc=1
  assert_shell "sudoers.d/tester7 has no NOPASSWD file" "! docker exec $name test -f /etc/sudoers.d/tester7" || rc=1
  assert_shell "tester7 in sudo group"                  "docker exec $name id -nG tester7 | grep -qw sudo"    || rc=1
  assert_shell "password actually set for tester7 (auto)" "docker exec $name bash -c 'getent shadow tester7 | cut -d: -f2 | grep -vqE \"^[!*]\"'" || rc=1
  return "$rc"
}

verify_key_password_manual() {
  local name="$1" rc=0
  local cfg; cfg="$(sshd_effective "$name")"
  assert_match "Effective port 2244" "$cfg" 'port 2244' || rc=1
  assert_shell "sudoers.d/tester8 has no NOPASSWD file" "! docker exec $name test -f /etc/sudoers.d/tester8" || rc=1
  assert_shell "tester8 in sudo group"                  "docker exec $name id -nG tester8 | grep -qw sudo"    || rc=1
  assert_shell "password actually set for tester8 (manual entry)" "docker exec $name bash -c 'getent shadow tester8 | cut -d: -f2 | grep -vqE \"^[!*]\"'" || rc=1
  return "$rc"
}

verify_password_only_preset() {
  local name="$1" rc=0
  local cfg; cfg="$(sshd_effective "$name")"
  assert_match "AuthenticationMethods=password" "$cfg" 'authenticationmethods password' || rc=1
  assert_match "PubkeyAuthentication=no"        "$cfg" 'pubkeyauthentication no'        || rc=1
  assert_shell "ssh.socket masked (port!=22)" "docker exec $name systemctl is-enabled ssh.socket 2>&1 | grep -q masked" || rc=1
  assert_shell "password actually set for tester9" "docker exec $name bash -c 'getent shadow tester9 | cut -d: -f2 | grep -vqE \"^[!*]\"'" || rc=1
  return "$rc"
}

verify_password_only_interactive() {
  local name="$1" rc=0
  local cfg; cfg="$(sshd_effective "$name")"
  assert_match "AuthenticationMethods=password" "$cfg" 'authenticationmethods password' || rc=1
  assert_shell "tester10 in sudo group"          "docker exec $name id -nG tester10 | grep -qw sudo" || rc=1
  assert_shell "password actually set for tester10" "docker exec $name bash -c 'getent shadow tester10 | cut -d: -f2 | grep -vqE \"^[!*]\"'" || rc=1
  return "$rc"
}

verify_port22_edge() {
  local name="$1" rc=0
  local cfg; cfg="$(sshd_effective "$name")"
  assert_match "Effective port 22" "$cfg" 'port 22' || rc=1
  assert_shell "ssh.socket untouched at port 22 (stays active)" \
    "docker exec $name systemctl is-active --quiet ssh.socket" || rc=1
  return "$rc"
}

verify_provider_cleanup() {
  local name="$1" rc=0
  local cfg; cfg="$(sshd_effective "$name")"
  assert_match "AuthenticationMethods=publickey" "$cfg" 'authenticationmethods publickey' || rc=1
  assert_match "Effective port 2244"              "$cfg" 'port 2244'                      || rc=1
  assert_shell "sudoers: NOPASSWD for tester13"   "docker exec $name grep -q NOPASSWD /etc/sudoers.d/tester13" || rc=1
  assert_shell "provider default user 'user' removed" "! docker exec $name id user" || rc=1
  return "$rc"
}

verify_existing_system_account() {
  local name="$1" rc=0
  assert_shell "svcacct in sudo group"        "docker exec $name id -nG svcacct | grep -qw sudo" || rc=1
  assert_shell "sudoers: NOPASSWD for svcacct" "docker exec $name grep -q NOPASSWD /etc/sudoers.d/svcacct" || rc=1
  assert_shell "authorized_keys set up for svcacct" "docker exec $name test -s /home/svcacct/.ssh/authorized_keys" || rc=1
  return "$rc"
}

# --- Presetup functions: container state before the interactive run ---

presetup_password_file()  { docker exec "$1" bash -c 'printf "Str0ngP@ssphrase!23\n" > /root/.testpass && chmod 600 /root/.testpass'; }
presetup_provider_user()  { docker exec "$1" useradd -m -s /bin/bash user; }
presetup_system_account() { docker exec "$1" useradd -r -m -d /home/svcacct -s /bin/bash svcacct; }

# --- Orchestration ---

run_all_scenarios() {
  sep; info "Argument parsing (full container, dialog never reaches a prompt)"; sep

  local -a args prompts

  args=(--help); prompts=()
  run_heavy_scenario 01_HELP ubuntu:26.04 0 verify_help - args prompts || true

  args=(99999); prompts=()
  run_heavy_scenario 02_BAD_PORT ubuntu:26.04 1 verify_bad_port - args prompts || true

  args=(--bogus); prompts=()
  run_heavy_scenario 03_UNKNOWN_FLAG ubuntu:26.04 1 verify_unknown_flag - args prompts || true

  args=(--user root); prompts=()
  run_heavy_scenario 04_USER_ROOT_REJECTED ubuntu:26.04 1 verify_user_root_rejected - args prompts || true

  args=(--password-file /nonexistent/path); prompts=()
  run_heavy_scenario 05_PASSWORD_FILE_MISSING ubuntu:26.04 1 verify_password_file_missing - args prompts || true

  sep; info "End-to-end scenarios (full dialog, real systemctl/ufw/fail2ban)"; sep

  args=(--user tester6)
  prompts=(
    "Use SSH key-only access${TAB}__NL__"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
  )
  run_heavy_scenario 06_KEY_NOPASSWD ubuntu:26.04 0 verify_key_nopasswd - args prompts || true

  args=(2255 --user tester7)
  prompts=(
    "Use SSH key-only access${TAB}y"
    "Enable passwordless sudo${TAB}n"
    "Generate secure password automatically${TAB}__NL__"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
  )
  run_heavy_scenario 07_KEY_PASSWORD_AUTOGEN ubuntu:26.04 0 verify_key_password_autogen - args prompts || true

  args=(--user tester8)
  prompts=(
    "Use SSH key-only access${TAB}y"
    "Enable passwordless sudo${TAB}n"
    "Generate secure password automatically${TAB}n"
    "Set password for${TAB}${MANUAL_TEST_PASSWORD}"
    "Confirm password${TAB}${MANUAL_TEST_PASSWORD}"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
  )
  run_heavy_scenario 08_KEY_PASSWORD_MANUAL ubuntu:26.04 0 verify_key_password_manual - args prompts || true

  args=(--user tester9 --password-file /root/.testpass)
  prompts=("Use SSH key-only access${TAB}n")
  run_heavy_scenario 09_PASSWORD_ONLY_PRESET ubuntu:26.04 0 verify_password_only_preset presetup_password_file args prompts || true

  args=()
  prompts=(
    "Use SSH key-only access${TAB}n"
    "Enter sudo username${TAB}tester10"
    "Generate secure password automatically${TAB}__NL__"
  )
  run_heavy_scenario 10_PASSWORD_ONLY_INTERACTIVE ubuntu:26.04 0 verify_password_only_interactive - args prompts || true

  args=(22 --user tester11)
  prompts=(
    "Use SSH key-only access${TAB}__NL__"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
  )
  run_heavy_scenario 11_PORT_22_EDGE ubuntu:26.04 0 verify_port22_edge - args prompts || true

  args=(--user tester12)
  prompts=(
    "Use SSH key-only access${TAB}__NL__"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_RSA_PUB}"
  )
  run_heavy_scenario 12_INVALID_KEY_RSA ubuntu:26.04 1 verify_invalid_key_rsa - args prompts || true

  args=(--user tester13)
  prompts=(
    "Use SSH key-only access${TAB}__NL__"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
  )
  run_heavy_scenario 13_PROVIDER_USER_CLEANUP ubuntu:26.04 0 verify_provider_cleanup presetup_provider_user args prompts || true

  args=(--user svcacct)
  prompts=(
    "Use SSH key-only access${TAB}__NL__"
    "Grant sudo and SSH key access${TAB}y"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
  )
  run_heavy_scenario 14_EXISTING_SYSTEM_ACCOUNT ubuntu:26.04 0 verify_existing_system_account presetup_system_account args prompts || true

  sep; info "15 — idempotency: re-run on the same container"; sep
  run_idempotent_rerun || true
}

run_idempotent_rerun() {
  local scen_id="15_IDEMPOTENT_RERUN"
  local tag="cfgsrv-test:${scen_id,,}" cname="cfgsrv-test-${scen_id,,}"
  local log1="${RESULTS_DIR}/${scen_id}_run1.log" log2="${RESULTS_DIR}/${scen_id}_run2.log"
  local -a args=(--user tester15)
  local -a prompts=(
    "Use SSH key-only access${TAB}__NL__"
    "Enable passwordless sudo${TAB}y"
    "Paste your SSH PUBLIC KEY${TAB}${FIXTURE_ED25519_PUB}"
  )
  local prompts_file; prompts_file="$(mktemp)"
  printf '%s\n' "${prompts[@]}" > "$prompts_file"

  build_target_image ubuntu:26.04 "$tag"
  start_target_container "$tag" "$cname"

  if ! wait_for_boot "$cname" 60; then
    record_result "$scen_id" FAIL "systemd did not come up"
    cleanup_scenario "$cname" "$tag" "$prompts_file"
    return 1
  fi

  local rc1=0 rc2=0
  run_interactive "$cname" "${args[@]}" -- "$prompts_file" "$log1" 600 || rc1=$?
  run_interactive "$cname" "${args[@]}" -- "$prompts_file" "$log2" 600 || rc2=$?

  local status="PASS" note=""
  if [[ "$rc1" != 0 || "$rc2" != 0 ]]; then
    status="FAIL"; note="run1=$rc1 run2=$rc2 (expected both 0)"
  else
    local dup
    dup="$(docker exec "$cname" bash -c "ufw status numbered | grep -cE '2244/tcp[[:space:]]+LIMIT'" || echo 0)"
    if [[ "$dup" != "1" ]]; then
      status="FAIL"; note="UFW LIMIT rules on 2244/tcp: $dup (expected exactly 1)"
    fi
  fi

  record_result "$scen_id" "$status" "$note"
  cleanup_scenario "$cname" "$tag" "$prompts_file"
}
