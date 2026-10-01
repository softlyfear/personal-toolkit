#!/usr/bin/env bash
#
# run-suite.sh — build one Docker scenario suite's driver image, run the suite, remove the image.
#
# Usage:    bash .claude/skills/docker-suite/scripts/run-suite.sh <suite> [scenario-filter]
#           suite: own-script | devsetup | svcctl | sysupdate | xrdp
# Requires: docker (daemon reachable), git
#
set -euo pipefail
IFS=$'\n\t'

readonly SUITES=(own-script devsetup svcctl sysupdate xrdp)
readonly USAGE="usage: run-suite.sh <own-script|devsetup|svcctl|sysupdate|xrdp> [scenario-filter]"

# Global, not local: the EXIT trap fires after main has returned.
DRIVER_TAG=""

info() { echo -e "\033[35m[INFO]  $1\033[0m" >&2; }
err() {
  echo -e "\033[31m[ERROR] $1\033[0m" >&2
  exit 1
}

usage_error() {
  printf '%s\n' "${USAGE}" >&2
  exit 2
}

# is_known_suite <name> — true for a directory under .claude/testing/ with a scenario suite.
is_known_suite() {
  local suite="$1" known
  for known in "${SUITES[@]}"; do
    [[ ${suite} == "${known}" ]] && return 0
  done
  return 1
}

remove_driver_image() {
  [[ -n ${DRIVER_TAG} ]] || return 0
  docker rmi "${DRIVER_TAG}" > /dev/null 2>&1 || true
}

main() {
  (($# >= 1 && $# <= 2)) || usage_error
  local suite="$1" filter="${2:-}"
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  is_known_suite "${suite}" || usage_error

  command -v docker > /dev/null || err "docker is not installed"
  docker info > /dev/null 2>&1 || err "the Docker daemon is not reachable (Docker Desktop not running?)"

  local toplevel
  toplevel="$(git rev-parse --show-toplevel)"
  cd "${toplevel}" || err "cannot enter ${toplevel}"
  # $(pwd), not the rev-parse output: under Git Bash it yields the /c/... form Docker Desktop
  # accepts in -v, where rev-parse prints C:/...
  local repo
  repo="$(pwd)"
  local images_dir=".claude/testing/${suite}/images"
  [[ -f "${images_dir}/driver.Dockerfile" ]] || err "${images_dir}/driver.Dockerfile not found"

  DRIVER_TAG="${suite}-test-driver"
  trap remove_driver_image EXIT

  info "building ${DRIVER_TAG}"
  docker build --quiet -t "${DRIVER_TAG}" -f "${images_dir}/driver.Dockerfile" "${images_dir}" > /dev/null

  info "running the ${suite} suite${filter:+ (filter: ${filter})}"
  # MSYS_NO_PATHCONV stops Git Bash from rewriting the -v paths; a no-op elsewhere.
  MSYS_NO_PATHCONV=1 docker run --rm \
    -e HOST_REPO_PATH="${repo}" \
    -e FULL_CLEAN=1 \
    -e SCENARIO_FILTER="${filter}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${repo}:/work/repo:ro" \
    "${DRIVER_TAG}" bash "/work/repo/.claude/testing/${suite}/run.sh"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
