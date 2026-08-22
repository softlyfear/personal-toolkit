#!/usr/bin/env bash
# .claude/testing/own-script/run.sh — entry point for the configuring_server.sh test harness.
# Must run INSIDE the driver container (images/driver.Dockerfile) with /var/run/docker.sock
# mounted. See .claude/commands/test_own_script.md for the full launch command.
#
# HOST_REPO_PATH is required: the repo path AS SEEN BY THE DOCKER DAEMON (normally the same
# as "$(pwd)" on the host) — NOT a path inside the driver container. Bind mounts for scenario
# containers are resolved by the daemon relative to the host, not the calling process
# (the docker-outside-of-docker trap).
set -euo pipefail
IFS=$'\n\t'

: "${HOST_REPO_PATH:?HOST_REPO_PATH is not set — run via .claude/commands/test_own_script.md}"

readonly TESTING_DIR="/work/repo/.claude/testing/own-script" # path inside the driver container
readonly REPO_MOUNT_SRC="${HOST_REPO_PATH}"                  # path as seen by the daemon
# Deliberately inside the container: scenario logs are working files, not artefacts,
# and are discarded with the container instead of accumulating in the repo.
RESULTS_DIR="/tmp/results/$(date +%Y%m%d_%H%M%S)"
readonly RESULTS_DIR
readonly FULL_CLEAN="${FULL_CLEAN:-1}"

mkdir -p "${RESULTS_DIR}"

# shellcheck source=./lib.sh
source "${TESTING_DIR}/lib.sh"
# shellcheck source=./scenarios.sh
source "${TESTING_DIR}/scenarios.sh"

trap full_teardown EXIT

# Scenario logs live only in this container, so anything a failure needs must be on
# stderr before it exits.
dump_failed_logs() {
  local row id status note
  for row in "${RESULTS_ROWS[@]}"; do
    IFS='|' read -r id status note <<< "${row}"
    if [[ "${status}" == "PASS" ]]; then
      continue
    fi
    sep
    err_ "${id} — tail of scenario log:"
    tail -n 40 "${RESULTS_DIR}/${id}"*.log 2> /dev/null >&2 || true
  done
}

main() {
  sep
  info "test_own_script: starting run"
  sep

  if ! docker info > /dev/null 2>&1; then
    err_ "No access to the Docker daemon (check /var/run/docker.sock mount)"
    exit 1
  fi

  CREATED_VOLUME="cfgsrv-test-aptcache-$$"
  docker volume create "${CREATED_VOLUME}" > /dev/null

  info "Generating disposable test SSH keys (mktemp, never committed)..."
  generate_fixture_keys

  run_all_scenarios

  set +e
  print_summary >&2
  local overall_rc=$?
  set -e

  cleanup_fixture_keys

  sep
  if [[ "${overall_rc}" -eq 0 ]]; then
    ok "All scenarios passed"
  else
    dump_failed_logs
    err_ "Some scenarios failed (logs above)"
  fi
  sep

  exit "${overall_rc}"
}

main "$@"
