# shellcheck shell=bash
# .claude/testing/own-script/lib.sh — shared functions for the test harness. Source-only, via run.sh.
set -euo pipefail

info() { echo -e "\033[35m[INFO]  $1\033[0m" >&2; }
ok() { echo -e "\033[32m[OK]    $1\033[0m" >&2; }
warn() { echo -e "\033[33m[WARN]  $1\033[0m" >&2; }
err_() { echo -e "\033[31m[ERROR] $1\033[0m" >&2; }
sep() { echo -e "\033[35m-----------------------------------------------------------------\033[0m" >&2; }

readonly TARGET_MEMORY="${TARGET_MEMORY:-2g}"
readonly TARGET_CPUS="${TARGET_CPUS:-2}"

# --- Created-resource registry: guarantees cleanup on any exit, including Ctrl-C ---

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

# --- Build and start the target container ---

# build_target_image <recipe:ubuntu:TAG> <tag>
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

# start_target_container <tag> <name>
start_target_container() {
  local tag="$1" name="$2"
  # --cgroupns=host: without it, journald fails to acquire its cgroup root path on
  # cgroup v2 hosts ("Protocol driver not attached"), breaking configure_journald_limits.
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

# wait_for_boot <name> [timeout_sec]
wait_for_boot() {
  local name="$1" timeout="${2:-60}" waited=0 state=""
  while ((waited < timeout)); do
    # systemctl is-system-running exits non-zero for "degraded" (a normal state for
    # systemd-in-docker) — check its stdout text directly, not its exit code.
    state="$(docker exec "${name}" systemctl is-system-running 2> /dev/null || true)"
    [[ "${state}" =~ ^(running|degraded)$ ]] && return 0
    sleep 1
    ((waited++)) || true
  done
  err_ "systemd in '${name}' did not come up within ${timeout}s (last state: ${state:-unknown})"
  docker exec "${name}" systemctl list-jobs 2>&1 | head -20 >&2 || true
  return 1
}

# --- Interactive run via expect ---

# run_interactive <container_name> <script_args...> -- <prompts_file> <log_file> [timeout]
run_interactive() {
  local name="$1"
  shift
  local -a script_args=()
  while [[ "$1" != "--" ]]; do
    script_args+=("$1")
    shift
  done
  shift
  local prompts_file="$1" log_file="$2" per_timeout="${3:-600}"

  local cmd
  printf -v cmd 'docker exec -it %q bash /opt/repo/server-scripts/configuring_server.sh' "${name}"
  local a
  for a in "${script_args[@]}"; do
    printf -v cmd '%s %q' "${cmd}" "${a}"
  done

  set +e
  expect "${TESTING_DIR}/drive.exp" "${cmd}" "${prompts_file}" "${log_file}" "${per_timeout}"
  local rc=$?
  set -e
  return "${rc}"
}

# --- Assertions: run via docker exec against an already-started container ---

sshd_effective() { docker exec "$1" sshd -T 2> /dev/null; }

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

# assert_shell <description> <shell command string> — for pipes/substitutions
# that don't fit "$@" as a single command. cmd is built by the harness itself
# (internal container names), never from user input.
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

# --- Test SSH keys: regenerated on every run, never committed ---

FIXTURE_DIR=""

generate_fixture_keys() {
  FIXTURE_DIR="$(mktemp -d)"
  ssh-keygen -t ed25519 -N '' -C 'test-harness' -f "${FIXTURE_DIR}/id_ed25519" > /dev/null
  ssh-keygen -t rsa -b 2048 -N '' -C 'test-harness-rsa' -f "${FIXTURE_DIR}/id_rsa" > /dev/null
  # shellcheck disable=SC2034 # assigned here, consumed by name (nameref) in the helper below
  FIXTURE_ED25519_PUB="$(cat "${FIXTURE_DIR}/id_ed25519.pub")"
  # shellcheck disable=SC2034 # assigned here, consumed by name (nameref) in the helper below
  FIXTURE_RSA_PUB="$(cat "${FIXTURE_DIR}/id_rsa.pub")"
}

cleanup_fixture_keys() {
  [[ -n "${FIXTURE_DIR}" && -d "${FIXTURE_DIR}" ]] && rm -rf "${FIXTURE_DIR}"
}

# --- Scenario results ---

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

# --- Generic scenario runner: target container + expect dialog + verify ---

# cleanup_scenario <container_name> <image_tag> <prompts_file>
cleanup_scenario() {
  local cname="$1" tag="$2" prompts_file="$3" i
  docker rm -f "${cname}" > /dev/null 2>&1 || true
  docker rmi -f "${tag}" > /dev/null 2>&1 || true
  rm -f "${prompts_file}"
  for i in "${!CREATED_CONTAINERS[@]}"; do
    [[ "${CREATED_CONTAINERS[${i}]}" == "${cname}" ]] && unset 'CREATED_CONTAINERS[i]'
  done
  for i in "${!CREATED_IMAGES[@]}"; do
    [[ "${CREATED_IMAGES[${i}]}" == "${tag}" ]] && unset 'CREATED_IMAGES[i]'
  done
}

# run_heavy_scenario <id> <base_image> <expected_exit> <verify_fn|-> <presetup_fn|-> \
#                     <args_array_name> <prompts_array_name>
# SCENARIO_FILTER=<substring> runs only the matching scenarios. A full matrix is ~25 min,
# which is too slow a loop when iterating on one scenario; unset it for the real run.
scenario_selected() {
  [[ -z "${SCENARIO_FILTER:-}" || "$1" == *"${SCENARIO_FILTER}"* ]]
}

run_heavy_scenario() {
  local scen_id="$1" base_image="$2" expected_exit="$3" verify_fn="$4" presetup_fn="$5"
  local -n args_ref="$6"
  local -n prompts_ref="$7"

  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  scenario_selected "${scen_id}" || return 0

  local tag="cfgsrv-test:${scen_id,,}"
  local cname="cfgsrv-test-${scen_id,,}"
  # shellcheck disable=SC2154 # set as readonly by run.sh before this file is sourced
  local log_file="${RESULTS_DIR}/${scen_id}.log"
  local prompts_file
  prompts_file="$(mktemp)"
  printf '%s\n' "${prompts_ref[@]}" > "${prompts_file}"

  info "[${scen_id}] Building image (${base_image})..."
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if ! build_target_image "${base_image}" "${tag}"; then
    record_result "${scen_id}" FAIL "docker build failed"
    rm -f "${prompts_file}"
    return 1
  fi

  info "[${scen_id}] Starting container..."
  start_target_container "${tag}" "${cname}"

  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if ! wait_for_boot "${cname}" 60; then
    record_result "${scen_id}" FAIL "systemd did not come up in 60s"
    cleanup_scenario "${cname}" "${tag}" "${prompts_file}"
    return 1
  fi

  [[ "${presetup_fn}" != "-" ]] && "${presetup_fn}" "${cname}"

  info "[${scen_id}] Running dialog via expect..."
  local rc=0
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  run_interactive "${cname}" "${args_ref[@]}" -- "${prompts_file}" "${log_file}" 600 || rc=$?

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
  cleanup_scenario "${cname}" "${tag}" "${prompts_file}"
}
