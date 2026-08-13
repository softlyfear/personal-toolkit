#!/usr/bin/env bash
# .claude/testing/svcctl/run.sh — entry point for the service-manager.sh / install_svcctl.sh
# test harness. Must run INSIDE the driver container with /var/run/docker.sock mounted,
# mirroring .claude/testing/own-script/run.sh.
set -euo pipefail

: "${HOST_REPO_PATH:?HOST_REPO_PATH is not set}"

readonly TESTING_DIR="/work/repo/.claude/testing/svcctl"
readonly REPO_MOUNT_SRC="$HOST_REPO_PATH"
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
  info "test_svcctl: starting run, results -> ${RESULTS_DIR}"
  sep

  if ! docker info >/dev/null 2>&1; then
    err_ "No access to the Docker daemon (check /var/run/docker.sock mount)"
    exit 1
  fi

  CREATED_VOLUME="svcctl-test-aptcache-$$"
  docker volume create "$CREATED_VOLUME" >/dev/null

  run_all_scenarios

  set +e
  print_summary | tee "${RESULTS_DIR}/summary.md" >&2
  local overall_rc=$?
  set -e

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
