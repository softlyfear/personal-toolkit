# shellcheck shell=bash
# .claude/testing/svcctl/lib.sh — shared functions for the service-manager.sh /
# install_svcctl.sh test harness. Source-only, via run.sh.
set -euo pipefail

info() { echo -e "\033[35m[INFO]  $1\033[0m" >&2; }
ok() { echo -e "\033[32m[OK]    $1\033[0m" >&2; }
warn() { echo -e "\033[33m[WARN]  $1\033[0m" >&2; }
err_() { echo -e "\033[31m[ERROR] $1\033[0m" >&2; }
sep() { echo -e "\033[35m-----------------------------------------------------------------\033[0m" >&2; }

readonly TARGET_MEMORY="${TARGET_MEMORY:-2g}"
readonly TARGET_CPUS="${TARGET_CPUS:-2}"

declare -ag CREATED_CONTAINERS=()
declare -ag CREATED_IMAGES=()
CREATED_VOLUME=""

register_container() { CREATED_CONTAINERS+=("$1"); }
register_image() { CREATED_IMAGES+=("$1"); }

cleanup_all() {
  local c i
  for c in "${CREATED_CONTAINERS[@]:-}"; do
    [[ -z "${c}" ]] && continue
    docker rm -f "${c}" > /dev/null 2>&1 || true
  done
  CREATED_CONTAINERS=()
  for i in "${CREATED_IMAGES[@]:-}"; do
    [[ -z "${i}" ]] && continue
    docker rmi -f "${i}" > /dev/null 2>&1 || true
  done
  CREATED_IMAGES=()
}

full_teardown() {
  cleanup_all
  if [[ -n "${CREATED_VOLUME}" ]]; then
    docker volume rm -f "${CREATED_VOLUME}" > /dev/null 2>&1 || true
  fi
  if [[ "${FULL_CLEAN:-1}" == "1" ]]; then
    docker rmi -f jrei/systemd-ubuntu:latest > /dev/null 2>&1 || true
    docker builder prune -f > /dev/null 2>&1 || true
    docker image prune -f > /dev/null 2>&1 || true
  fi
}

trap 'cleanup_all' ERR
trap 'cleanup_all; exit 130' INT TERM

build_target_image() {
  local recipe="$1" tag="$2"
  case "${recipe}" in
    ubuntu:*)
      local jrei_tag="${recipe#ubuntu:}" attempt
      for attempt in 1 2; do
        # shellcheck disable=SC2154 # set as readonly by run.sh before this file is sourced
        docker build --quiet \
          --build-arg "JREI_TAG=${jrei_tag}" \
          -t "${tag}" \
          -f "${TESTING_DIR}/images/target.Dockerfile" \
          "${TESTING_DIR}/images" > /dev/null && break
        ((attempt == 2)) && {
          err_ "Build from jrei/systemd-ubuntu:${jrei_tag} failed twice — https://hub.docker.com/r/jrei/systemd-ubuntu/tags"
          return 1
        }
        warn "Build attempt 1 failed (likely a transient pull hiccup), retrying..."
      done
      ;;
    *)
      err_ "build_target_image: unknown recipe '${recipe}' (only ubuntu:<tag> is supported)"
      return 1
      ;;
  esac
  register_image "${tag}"
}

start_target_container() {
  local tag="$1" name="$2"
  # shellcheck disable=SC2154 # set as readonly by run.sh before this file is sourced
  docker run -d --name "${name}" \
    --privileged --cgroupns=host \
    --memory "${TARGET_MEMORY}" --cpus "${TARGET_CPUS}" \
    --tmpfs /run --tmpfs /run/lock \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "${REPO_MOUNT_SRC}:/opt/repo:ro" \
    -v "${CREATED_VOLUME}:/var/cache/apt/archives" \
    "${tag}" > /dev/null
  register_container "${name}"
}

wait_for_boot() {
  local name="$1" timeout="${2:-60}" waited=0 state=""
  while ((waited < timeout)); do
    state="$(docker exec "${name}" systemctl is-system-running 2> /dev/null || true)"
    [[ "${state}" =~ ^(running|degraded)$ ]] && return 0
    sleep 1
    ((waited++)) || true
  done
  err_ "systemd in '${name}' did not come up within ${timeout}s (last state: ${state:-unknown})"
  docker exec "${name}" systemctl list-jobs 2>&1 | head -20 >&2 || true
  return 1
}

# run_svcctl <container> <log_file> <action...service...> — runs the REPO COPY of
# service-manager.sh (not the installed svcctl binary; install_svcctl.sh scenarios test
# the installed binary separately via plain docker exec svcctl).
run_svcctl() {
  local name="$1" log_file="$2"
  shift 2
  local rc=0
  {
    printf -- '--- svcctl %s ---\n' "$*"
    docker exec "${name}" bash /opt/repo/server-scripts/service-manager.sh "$@"
  } >> "${log_file}" 2>&1 || rc=$?
  return "${rc}"
}

# run_install_svcctl <container> <log_file> [-u user]
run_install_svcctl() {
  local name="$1" log_file="$2"
  shift 2
  local rc=0
  docker exec "$@" "${name}" bash /opt/repo/server-scripts/install_svcctl.sh >> "${log_file}" 2>&1 || rc=$?
  return "${rc}"
}

assert_match() {
  local desc="$1" haystack="$2" pattern="$3"
  if grep -qE "${pattern}" <<< "${haystack}"; then
    ok "  OK ${desc}"
    return 0
  else
    err_ "  FAIL ${desc} (pattern not found: ${pattern})"
    return 1
  fi
}

assert_shell() {
  local desc="$1" cmd="$2"
  if bash -c "${cmd}" > /dev/null 2>&1; then
    ok "  OK ${desc}"
    return 0
  else
    err_ "  FAIL ${desc} (command: ${cmd})"
    return 1
  fi
}

declare -ag RESULTS_ROWS=()

record_result() {
  local id="$1" status="$2" note="${3:-}"
  RESULTS_ROWS+=("${id}|${status}|${note}")
  if [[ "${status}" == "PASS" ]]; then ok "[${id}] PASS"; else err_ "[${id}] FAIL: ${note}"; fi
}

print_summary() {
  local row id status note overall_rc=0
  echo ""
  echo "| Scenario | Result | Note |"
  echo "|---|---|---|"
  for row in "${RESULTS_ROWS[@]}"; do
    IFS='|' read -r id status note <<< "${row}"
    echo "| ${id} | ${status} | ${note:-—} |"
    [[ "${status}" == "PASS" ]] || overall_rc=1
  done
  return "${overall_rc}"
}

cleanup_scenario() {
  local cname="$1" tag="$2" i
  docker rm -f "${cname}" > /dev/null 2>&1 || true
  docker rmi -f "${tag}" > /dev/null 2>&1 || true
  for i in "${!CREATED_CONTAINERS[@]}"; do
    [[ "${CREATED_CONTAINERS[${i}]}" == "${cname}" ]] && unset 'CREATED_CONTAINERS[i]'
  done
  for i in "${!CREATED_IMAGES[@]}"; do
    [[ "${CREATED_IMAGES[${i}]}" == "${tag}" ]] && unset 'CREATED_IMAGES[i]'
  done
}

# start_scenario_container <id> -> prints "<tag> <cname>" on success, records FAIL and
# returns 1 on boot failure (caller must still cleanup_scenario on the FAIL path itself
# since we don't know the tag/cname the caller wants to log without returning them).
start_scenario_container() {
  local scen_id="$1"
  local tag="svcctl-test:${scen_id,,}"
  local cname="svcctl-test-${scen_id,,}"

  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if ! build_target_image "ubuntu:latest" "${tag}"; then
    record_result "${scen_id}" FAIL "docker build failed"
    return 1
  fi
  start_target_container "${tag}" "${cname}"
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if ! wait_for_boot "${cname}" 60; then
    record_result "${scen_id}" FAIL "systemd did not come up in 60s"
    cleanup_scenario "${cname}" "${tag}"
    return 1
  fi
  printf '%s %s' "${tag}" "${cname}"
}

# run_simple_scenario <id> <expected_exit> <verify_fn|-> <presetup_fn|-> <svcctl_args...>
run_simple_scenario() {
  local scen_id="$1" expected_exit="$2" verify_fn="$3" presetup_fn="$4"
  shift 4
  # shellcheck disable=SC2154 # set as readonly by run.sh before this file is sourced
  local log_file="${RESULTS_DIR}/${scen_id}.log"
  local out tag cname
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  out="$(start_scenario_container "${scen_id}")" || return 1
  IFS=' ' read -r tag cname <<< "${out}"

  [[ "${presetup_fn}" != "-" ]] && "${presetup_fn}" "${cname}"

  local rc=0
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  run_svcctl "${cname}" "${log_file}" "$@" || rc=$?

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
