# .claude/testing/xrdp/lib.sh — shared functions for the add_xfce_xrdp.sh /
# add_gnome_xrdp.sh test harness. Source-only, via run.sh.
set -euo pipefail

info()  { echo -e "\033[35m[INFO]  $1\033[0m" >&2; }
ok()    { echo -e "\033[32m[OK]    $1\033[0m" >&2; }
warn()  { echo -e "\033[33m[WARN]  $1\033[0m" >&2; }
err_()  { echo -e "\033[31m[ERROR] $1\033[0m" >&2; }
sep()   { echo -e "\033[35m-----------------------------------------------------------------\033[0m" >&2; }

readonly TARGET_MEMORY="${TARGET_MEMORY:-3g}"
readonly TARGET_CPUS="${TARGET_CPUS:-2}"

declare -ag CREATED_CONTAINERS=()
declare -ag CREATED_IMAGES=()
CREATED_VOLUME=""

register_container() { CREATED_CONTAINERS+=("$1"); }
register_image()     { CREATED_IMAGES+=("$1"); }

cleanup_all() {
  local c i
  for c in "${CREATED_CONTAINERS[@]:-}"; do
    [[ -z "$c" ]] && continue
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  CREATED_CONTAINERS=()
  for i in "${CREATED_IMAGES[@]:-}"; do
    [[ -z "$i" ]] && continue
    docker rmi -f "$i" >/dev/null 2>&1 || true
  done
  CREATED_IMAGES=()
}

full_teardown() {
  cleanup_all
  if [[ -n "$CREATED_VOLUME" ]]; then
    docker volume rm -f "$CREATED_VOLUME" >/dev/null 2>&1 || true
  fi
  if [[ "${FULL_CLEAN:-1}" == "1" ]]; then
    docker rmi -f jrei/systemd-ubuntu:26.04 >/dev/null 2>&1 || true
    docker builder prune -f >/dev/null 2>&1 || true
    docker image prune -f >/dev/null 2>&1 || true
  fi
}

trap 'cleanup_all' ERR
trap 'cleanup_all; exit 130' INT TERM

build_target_image() {
  local recipe="$1" tag="$2"
  case "$recipe" in
    ubuntu:*)
      local jrei_tag="${recipe#ubuntu:}" attempt
      for attempt in 1 2; do
        docker build --quiet \
          --build-arg "JREI_TAG=${jrei_tag}" \
          -t "$tag" \
          -f "${TESTING_DIR}/images/target.Dockerfile" \
          "${TESTING_DIR}/images" >/dev/null && break
        (( attempt == 2 )) && {
          err_ "Build from jrei/systemd-ubuntu:${jrei_tag} failed twice — https://hub.docker.com/r/jrei/systemd-ubuntu/tags"
          return 1
        }
        warn "Build attempt 1 failed (likely a transient pull hiccup), retrying..."
      done
      ;;
    *)
      err_ "build_target_image: unknown recipe '$recipe' (only ubuntu:<tag> is supported)"
      return 1
      ;;
  esac
  register_image "$tag"
}

start_target_container() {
  local tag="$1" name="$2"
  docker run -d --name "$name" \
    --privileged --cgroupns=host \
    --memory "$TARGET_MEMORY" --cpus "$TARGET_CPUS" \
    --tmpfs /run --tmpfs /run/lock \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "${REPO_MOUNT_SRC}:/opt/repo:ro" \
    -v "${CREATED_VOLUME}:/var/cache/apt/archives" \
    "$tag" >/dev/null
  register_container "$name"
}

wait_for_boot() {
  local name="$1" timeout="${2:-60}" waited=0 state=""
  while (( waited < timeout )); do
    state="$(docker exec "$name" systemctl is-system-running 2>/dev/null || true)"
    [[ "$state" =~ ^(running|degraded)$ ]] && return 0
    sleep 1
    (( waited++ )) || true
  done
  err_ "systemd in '$name' did not come up within ${timeout}s (last state: ${state:-unknown})"
  docker exec "$name" systemctl list-jobs 2>&1 | head -20 >&2 || true
  return 1
}

# run_interactive <container_name> <script_path_in_repo> -- <prompts_file> <log_file> [timeout]
# SSH_PORT=22 is always injected: the container has no real sshd session, so
# ensure_ssh_ufw_rule() can't discover a port from SSH_CONNECTION or `sshd -T` — the
# script explicitly supports overriding via the SSH_PORT env var for exactly this case.
run_interactive() {
  local name="$1" script_path="$2"
  shift 2
  [[ "$1" == "--" ]] && shift
  local prompts_file="$1" log_file="$2" per_timeout="${3:-900}"

  local cmd
  printf -v cmd 'docker exec -it -e SSH_PORT=22 %q bash %q' "$name" "$script_path"

  set +e
  expect "${TESTING_DIR}/drive.exp" "$cmd" "$prompts_file" "$log_file" "$per_timeout"
  local rc=$?
  set -e
  return "$rc"
}

assert_match() {
  local desc="$1" haystack="$2" pattern="$3"
  if grep -qE "$pattern" <<< "$haystack"; then
    ok "  OK $desc"; return 0
  else
    err_ "  FAIL $desc (pattern not found: $pattern)"; return 1
  fi
}

assert_shell() {
  local desc="$1" cmd="$2"
  if bash -c "$cmd" >/dev/null 2>&1; then
    ok "  OK $desc"; return 0
  else
    err_ "  FAIL $desc (command: $cmd)"; return 1
  fi
}

declare -ag RESULTS_ROWS=()

record_result() {
  local id="$1" status="$2" note="${3:-}"
  RESULTS_ROWS+=("${id}|${status}|${note}")
  if [[ "$status" == "PASS" ]]; then ok "[$id] PASS"; else err_ "[$id] FAIL: $note"; fi
}

print_summary() {
  local row id status note overall_rc=0
  echo ""
  echo "| Scenario | Result | Note |"
  echo "|---|---|---|"
  for row in "${RESULTS_ROWS[@]}"; do
    IFS='|' read -r id status note <<< "$row"
    echo "| $id | $status | ${note:-—} |"
    [[ "$status" == "PASS" ]] || overall_rc=1
  done
  return "$overall_rc"
}

cleanup_scenario() {
  local cname="$1" tag="$2" prompts_file="${3:-}" i
  docker rm -f "$cname" >/dev/null 2>&1 || true
  docker rmi -f "$tag" >/dev/null 2>&1 || true
  [[ -n "$prompts_file" ]] && rm -f "$prompts_file"
  for i in "${!CREATED_CONTAINERS[@]}"; do
    [[ "${CREATED_CONTAINERS[$i]}" == "$cname" ]] && unset 'CREATED_CONTAINERS[i]'
  done
  for i in "${!CREATED_IMAGES[@]}"; do
    [[ "${CREATED_IMAGES[$i]}" == "$tag" ]] && unset 'CREATED_IMAGES[i]'
  done
}

# run_heavy_scenario <id> <script_path_in_repo> <expected_exit> <verify_fn|-> \
#                     <presetup_fn|-> <prompts_array_name>
run_heavy_scenario() {
  local scen_id="$1" script_path="$2" expected_exit="$3" verify_fn="$4" presetup_fn="$5"
  local -n prompts_ref="$6"

  local tag="xrdp-test:${scen_id,,}"
  local cname="xrdp-test-${scen_id,,}"
  local log_file="${RESULTS_DIR}/${scen_id}.log"
  local prompts_file; prompts_file="$(mktemp)"
  printf '%s\n' "${prompts_ref[@]}" > "$prompts_file"

  info "[$scen_id] Building image..."
  if ! build_target_image "ubuntu:26.04" "$tag"; then
    record_result "$scen_id" FAIL "docker build failed"
    rm -f "$prompts_file"
    return 1
  fi

  info "[$scen_id] Starting container..."
  start_target_container "$tag" "$cname"

  if ! wait_for_boot "$cname" 60; then
    record_result "$scen_id" FAIL "systemd did not come up in 60s"
    cleanup_scenario "$cname" "$tag" "$prompts_file"
    return 1
  fi

  [[ "$presetup_fn" != "-" ]] && "$presetup_fn" "$cname"

  info "[$scen_id] Running ${script_path} via expect..."
  local rc=0
  # ubuntu-gnome-desktop pulls in the full ubuntu-desktop set (LibreOffice, printing,
  # NetworkManager, hundreds of packages) — under real network variability this can run
  # well past 20 minutes between the RDP-IP prompt and the username prompt that only
  # fires after the install finishes. 2700s gives real margin without masking a genuine
  # script hang (a stuck script would still time out well before that).
  run_interactive "$cname" "$script_path" -- "$prompts_file" "$log_file" 2700 || rc=$?

  local status="PASS" note=""
  if [[ "$rc" != "$expected_exit" ]]; then
    status="FAIL"
    note="exit=$rc, expected $expected_exit (see $log_file)"
  elif [[ "$verify_fn" != "-" ]]; then
    if ! "$verify_fn" "$cname" "$log_file" >>"$log_file" 2>&1; then
      status="FAIL"
      note="verify failed, see $log_file"
    fi
  fi

  record_result "$scen_id" "$status" "$note"
  cleanup_scenario "$cname" "$tag" "$prompts_file"
}
