#!/usr/bin/env bash
# .claude/testing/svcctl/run.sh — entry point for the service-manager.sh / install_svcctl.sh
# test harness. Must run INSIDE the driver container with /var/run/docker.sock mounted,
# mirroring .claude/testing/own-script/run.sh.
set -euo pipefail
IFS=$'\n\t'

: "${HOST_REPO_PATH:?HOST_REPO_PATH is not set}"

readonly TESTING_DIR="/work/repo/.claude/testing/svcctl"
readonly REPO_MOUNT_SRC="${HOST_REPO_PATH}"
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
  info "test_svcctl: starting run"
  sep

  if ! docker info > /dev/null 2>&1; then
    err_ "No access to the Docker daemon (check /var/run/docker.sock mount)"
    exit 1
  fi

  CREATED_VOLUME="svcctl-test-aptcache-$$"
  docker volume create "${CREATED_VOLUME}" > /dev/null

  run_all_scenarios

  set +e
  print_summary >&2
  local overall_rc=$?
  set -e

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
