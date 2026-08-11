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

: "${HOST_REPO_PATH:?HOST_REPO_PATH is not set — run via .claude/commands/test_own_script.md}"

readonly TESTING_DIR="/work/repo/.claude/testing/own-script"  # path inside the driver container
readonly REPO_MOUNT_SRC="$HOST_REPO_PATH"                     # path as seen by the daemon
# /work/repo is mounted :ro (see test_own_script.md); results need a separate writable mount.
readonly RESULTS_DIR="/work/results/$(date +%Y%m%d_%H%M%S)"
readonly FULL_CLEAN="${FULL_CLEAN:-1}"

mkdir -p "$RESULTS_DIR"

# shellcheck source=./lib.sh
source "${TESTING_DIR}/lib.sh"
# shellcheck source=./scenarios.sh
source "${TESTING_DIR}/scenarios.sh"

trap full_teardown EXIT

main() {
  sep
  info "test_own_script: starting run, results -> ${RESULTS_DIR}"
  sep

  if ! docker info >/dev/null 2>&1; then
    err_ "No access to the Docker daemon (check /var/run/docker.sock mount)"
    exit 1
  fi

  CREATED_VOLUME="cfgsrv-test-aptcache-$$"
  docker volume create "$CREATED_VOLUME" >/dev/null

  info "Generating disposable test SSH keys (mktemp, never committed)..."
  generate_fixture_keys

  run_all_scenarios

  set +e
  print_summary | tee "${RESULTS_DIR}/summary.md" >&2
  local overall_rc=$?
  set -e

  cleanup_fixture_keys

  sep
  if [[ "$overall_rc" -eq 0 ]]; then
    ok "All scenarios passed. Full report: ${RESULTS_DIR}/summary.md"
  else
    err_ "Some scenarios failed. Full report: ${RESULTS_DIR}/summary.md"
  fi
  sep

  exit "$overall_rc"
}

main "$@"
