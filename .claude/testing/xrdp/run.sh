#!/usr/bin/env bash
# .claude/testing/xrdp/run.sh — entry point for the add_xfce_xrdp.sh / add_gnome_xrdp.sh
# test harness. Must run INSIDE the driver container with /var/run/docker.sock mounted,
# mirroring .claude/testing/own-script/run.sh. Heaviest suite in this repo: real desktop
# environment installs (XFCE and GNOME) in every end-to-end scenario.
set -euo pipefail
IFS=$'\n\t'

: "${HOST_REPO_PATH:?HOST_REPO_PATH is not set}"

readonly TESTING_DIR="/work/repo/.claude/testing/xrdp"
readonly REPO_MOUNT_SRC="${HOST_REPO_PATH}"
RESULTS_DIR="/work/results/$(date +%Y%m%d_%H%M%S)"
readonly RESULTS_DIR
readonly FULL_CLEAN="${FULL_CLEAN:-1}"

mkdir -p "${RESULTS_DIR}"

# shellcheck source=./lib.sh
source "${TESTING_DIR}/lib.sh"
# shellcheck source=./scenarios.sh
source "${TESTING_DIR}/scenarios.sh"

trap full_teardown EXIT

main() {
  sep
  info "test_xrdp: starting run, results -> ${RESULTS_DIR}"
  sep

  if ! docker info > /dev/null 2>&1; then
    err_ "No access to the Docker daemon (check /var/run/docker.sock mount)"
    exit 1
  fi

  CREATED_VOLUME="xrdp-test-aptcache-$$"
  docker volume create "${CREATED_VOLUME}" > /dev/null

  run_all_scenarios

  set +e
  print_summary | tee "${RESULTS_DIR}/summary.md" >&2
  local overall_rc=$?
  set -e

  sep
  if [[ "${overall_rc}" -eq 0 ]]; then
    ok "All scenarios passed. Full report: ${RESULTS_DIR}/summary.md"
  else
    err_ "Some scenarios failed. Full report: ${RESULTS_DIR}/summary.md"
  fi
  sep

  exit "${overall_rc}"
}

main "$@"
