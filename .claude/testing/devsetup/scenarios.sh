# shellcheck shell=bash
# .claude/testing/devsetup/scenarios.sh — scenario matrix for dev-tools/install-dev-tools.sh.
# Source-only, via run.sh (after lib.sh). Ubuntu only, real apt-get/systemctl in a real
# systemd container. uv scenarios hit the real astral.sh network endpoint (third-party,
# not checksum-pinned in this repo — see install_uv() comment in the script itself).
set -euo pipefail

readonly TAB=$'\t'

# --- Verify functions ---

verify_help() { assert_shell "log contains Usage:" "grep -q 'Usage:' '$2'"; }

verify_unknown_tool() { assert_shell "log contains 'Unknown tool'" "grep -q 'Unknown tool' '$2'"; }

verify_all_tools() {
  local name="$1" rc=0
  assert_shell "git installed" "docker exec ${name} bash -c 'command -v git'" || rc=1
  assert_shell "make installed" "docker exec ${name} bash -c 'command -v make'" || rc=1
  assert_shell "postgresql active" "docker exec ${name} systemctl is-active --quiet postgresql" || rc=1
  assert_shell "docker active" "docker exec ${name} systemctl is-active --quiet docker" || rc=1
  assert_shell "uv installed" "docker exec ${name} test -x /root/.local/bin/uv" || rc=1
  assert_shell "log warns PATH for uv" "grep -q '~/.local/bin' '$2'" || rc=1
  return "${rc}"
}

verify_git_only() {
  local name="$1" rc=0
  assert_shell "git installed" "docker exec ${name} bash -c 'command -v git'" || rc=1
  assert_shell "make NOT installed" "! docker exec ${name} bash -c 'command -v make'" || rc=1
  return "${rc}"
}

verify_make_only() {
  local name="$1" rc=0
  assert_shell "make installed" "docker exec ${name} bash -c 'command -v make'" || rc=1
  assert_shell "git NOT installed" "! docker exec ${name} bash -c 'command -v git'" || rc=1
  return "${rc}"
}

verify_postgresql_only() {
  local name="$1" rc=0
  assert_shell "postgresql active" "docker exec ${name} systemctl is-active --quiet postgresql" || rc=1
  assert_shell "postgresql enabled" "docker exec ${name} systemctl is-enabled --quiet postgresql" || rc=1
  return "${rc}"
}

verify_docker_only() {
  local name="$1" rc=0
  assert_shell "docker active" "docker exec ${name} systemctl is-active --quiet docker" || rc=1
  assert_shell "docker enabled" "docker exec ${name} systemctl is-enabled --quiet docker" || rc=1
  return "${rc}"
}

verify_git_make() {
  local name="$1" rc=0
  assert_shell "git installed" "docker exec ${name} bash -c 'command -v git'" || rc=1
  assert_shell "make installed" "docker exec ${name} bash -c 'command -v make'" || rc=1
  assert_shell "postgresql NOT active" "! docker exec ${name} systemctl is-active --quiet postgresql" || rc=1
  return "${rc}"
}

verify_uv_only() {
  local name="$1" rc=0
  assert_shell "uv installed" "docker exec ${name} test -x /root/.local/bin/uv" || rc=1
  return "${rc}"
}

verify_interactive_git_make() {
  local name="$1" rc=0
  assert_shell "git installed (interactive y)" "docker exec ${name} bash -c 'command -v git'" || rc=1
  assert_shell "make installed (interactive y)" "docker exec ${name} bash -c 'command -v make'" || rc=1
  assert_shell "uv NOT installed (interactive n)" "! docker exec ${name} test -x /root/.local/bin/uv" || rc=1
  assert_shell "postgresql NOT active (interactive n)" "! docker exec ${name} systemctl is-active --quiet postgresql" || rc=1
  assert_shell "docker NOT active (interactive n)" "! docker exec ${name} systemctl is-active --quiet docker" || rc=1
  return "${rc}"
}

verify_no_tools_selected() { assert_shell "log contains 'No tools selected'" "grep -q 'No tools selected' '$2'"; }

# --- Orchestration ---

run_all_scenarios() {
  sep
  info "Argument parsing (no apt-get reached)"
  sep

  local -a args prompts=()

  args=(--help)
  run_scenario 01_HELP 0 verify_help - args || true

  args=(bogus-tool)
  run_scenario 02_UNKNOWN_TOOL 1 verify_unknown_tool - args || true

  sep
  info "Real installs — each builds/starts its own container"
  sep

  args=()
  run_scenario 03_NO_ARGS_DEFAULT_ALL 0 verify_all_tools - args || true

  args=(git)
  run_scenario 04_GIT_ONLY 0 verify_git_only - args || true

  args=(make)
  run_scenario 05_MAKE_ONLY 0 verify_make_only - args || true

  args=(postgresql)
  run_scenario 06_POSTGRESQL_ONLY 0 verify_postgresql_only - args || true

  args=(docker)
  run_scenario 07_DOCKER_ONLY 0 verify_docker_only - args || true

  args=(git make)
  run_scenario 08_MULTIPLE_TOOLS 0 verify_git_make - args || true

  args=(uv)
  run_scenario 09_UV_ONLY 0 verify_uv_only - args || true

  sep
  info "--interactive dialog"
  sep

  args=(--interactive)
  prompts=(
    "Install git${TAB}y"
    "Install uv${TAB}n"
    "Install make${TAB}y"
    "Install postgresql${TAB}n"
    "Install docker${TAB}n"
  )
  run_scenario 10_INTERACTIVE_MIXED 0 verify_interactive_git_make - args prompts || true

  # shellcheck disable=SC2034 # assigned here, consumed by name (nameref) in the helper below
  args=(--interactive)
  # shellcheck disable=SC2034 # assigned here, consumed by name (nameref) in the helper below
  prompts=(
    "Install git${TAB}n"
    "Install uv${TAB}n"
    "Install make${TAB}n"
    "Install postgresql${TAB}n"
    "Install docker${TAB}n"
  )
  run_scenario 11_INTERACTIVE_NONE_SELECTED 0 verify_no_tools_selected - args prompts || true

  sep
  info "12 — idempotency: install git twice on the same container"
  sep
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  run_idempotent_rerun || true
}

run_idempotent_rerun() {
  local scen_id="12_IDEMPOTENT_RERUN"
  local tag="devsetup-test:${scen_id,,}" cname="devsetup-test-${scen_id,,}"
  # shellcheck disable=SC2154 # set as readonly by run.sh before this file is sourced
  local log1="${RESULTS_DIR}/${scen_id}_run1.log" log2="${RESULTS_DIR}/${scen_id}_run2.log"

  build_target_image ubuntu:latest "${tag}"
  start_target_container "${tag}" "${cname}"

  if ! wait_for_boot "${cname}" 60; then
    record_result "${scen_id}" FAIL "systemd did not come up"
    cleanup_scenario "${cname}" "${tag}"
    return 1
  fi

  local rc1=0 rc2=0
  run_noninteractive "${cname}" "${log1}" git || rc1=$?
  run_noninteractive "${cname}" "${log2}" git || rc2=$?

  local status="PASS" note=""
  if [[ "${rc1}" != 0 || "${rc2}" != 0 ]]; then
    status="FAIL"
    note="run1=${rc1} run2=${rc2} (expected both 0)"
  fi

  record_result "${scen_id}" "${status}" "${note}"
  cleanup_scenario "${cname}" "${tag}"
}
