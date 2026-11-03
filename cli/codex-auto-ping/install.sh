#!/usr/bin/env bash
#
# install.sh — install codex-auto-ping as a systemd user unit: no prompts, no root, checks at the end
#
# Two steps, same command: step 1 installs uv and the Codex CLI and checks the login; if the CLI is
# not logged in it stops there (exit 0) and tells you to run `codex login`. Re-running does step 2.
#
# Usage:  bash <(wget -qO- https://raw.githubusercontent.com/user/personal-toolkit/main/cli/codex-auto-ping/install.sh)
#         CODEX_AUTO_PING_DIR=/opt/ping bash <(wget -qO- ...)   # install somewhere else
# Requires: wget, python3, a systemd user session; never root
# Uninstall: systemctl --user disable --now codex-auto-ping
#            rm ~/.config/systemd/user/codex-auto-ping.service
#            rm -rf ~/.local/share/codex-auto-ping
#
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Constants
# =============================================================================

readonly RAW_BASE="https://raw.githubusercontent.com/user/personal-toolkit/main/cli/codex-auto-ping"
readonly UNIT_NAME="codex-auto-ping.service"
readonly LOCAL_BIN="${HOME}/.local/bin"
readonly UNIT_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
readonly INSTALL_DIR="${CODEX_AUTO_PING_DIR:-${HOME}/.local/share/codex-auto-ping}"
readonly JOURNAL_WAIT_S=10
# The whole application: no clone, nothing else from the repository is needed at run time
readonly APP_FILES=("main.py" "pyproject.toml" "uv.lock" "${UNIT_NAME}.in")

# =============================================================================
# UI helpers
# =============================================================================

info() { echo -e "\033[35m[INFO]  $1\033[0m" >&2; }
ok() { echo -e "\033[32m[OK]    $1\033[0m" >&2; }
warn() { echo -e "\033[33m[WARN]  $1\033[0m" >&2; }
err() {
  echo -e "\033[31m[ERROR] $1\033[0m" >&2
  exit 1
}

# =============================================================================
# Preconditions
# =============================================================================

require_preconditions() {
  local uid="" required_cmd=""

  uid="$(id -u)"
  [[ "${uid}" -ne 0 ]] \
    || err "Run as your normal user, not root: the unit is user-level and the login token lives in \${HOME}/.codex"

  for required_cmd in wget python3 mktemp mv cp dirname systemctl loginctl; do
    command -v "${required_cmd}" > /dev/null 2>&1 \
      || err "Required command not found: ${required_cmd}"
  done

  systemctl --user show-environment > /dev/null 2>&1 \
    || err "No systemd user session for this user — log in over SSH as this user and retry"
}

# ~/.local/bin holds uv and codex but is absent from PATH in a fresh non-login shell
ensure_local_bin_on_path() {
  case ":${PATH}:" in
    *":${LOCAL_BIN}:"*) ;;
    *) export PATH="${LOCAL_BIN}:${PATH}" ;;
  esac
}

# =============================================================================
# Tool installers
# =============================================================================

install_from_url() {
  local url="$1" label="$2" tmp_installer=""

  tmp_installer="$(mktemp)"
  # Self-clearing: a RETURN trap otherwise fires again when the caller returns.
  trap 'rm -f "${tmp_installer:-}"; trap - RETURN' RETURN
  wget -qO "${tmp_installer}" "${url}" || err "Failed to download the ${label} installer"
  bash -n "${tmp_installer}" \
    || err "Downloaded ${label} installer failed bash -n (possibly corrupted/tampered)"
  bash "${tmp_installer}"
}

ensure_uv() {
  if command -v uv > /dev/null 2>&1; then
    ok "uv already present"
    return 0
  fi
  warn "uv installer comes from a third party (astral.sh) and is not checksum-pinned in this repo"
  # shellcheck disable=SC2310 # predicate; its return code is handled by set -e in the caller chain
  install_from_url "https://astral.sh/uv/install.sh" "uv"
  command -v uv > /dev/null 2>&1 || err "uv is still not on PATH after install"
  ok "uv installed"
}

ensure_codex() {
  if command -v codex > /dev/null 2>&1; then
    ok "Codex CLI already present"
    return 0
  fi
  # shellcheck disable=SC2310 # predicate; its return code is handled by set -e in the caller chain
  install_from_url "https://chatgpt.com/codex/install.sh" "codex"
  command -v codex > /dev/null 2>&1 || err "codex is still not on PATH after install"
  ok "Codex CLI installed"
}

# =============================================================================
# Application files and dependencies
# =============================================================================

fetch_app_files() {
  local app_dir="$1" tmp_dir="" file="" source_dir=""

  tmp_dir="$(mktemp -d)"
  # Self-clearing: a RETURN trap otherwise fires again when the caller returns.
  trap 'rm -rf "${tmp_dir:-}"; trap - RETURN' RETURN

  source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  [[ -f "${source_dir}/main.py" ]] || source_dir=""
  for file in "${APP_FILES[@]}"; do
    if [[ -n "${source_dir}" ]]; then
      cp "${source_dir}/${file}" "${tmp_dir}/${file}" || err "Failed to copy ${file}"
    else
      wget -qO "${tmp_dir}/${file}" "${RAW_BASE}/${file}" || err "Failed to download ${file}"
    fi
    [[ -s "${tmp_dir}/${file}" ]] || err "Downloaded ${file} is empty"
  done
  # A truncated main.py would otherwise surface hours later, at the first slot
  python3 -m py_compile "${tmp_dir}/main.py" > /dev/null 2>&1 \
    || err "Downloaded main.py failed a syntax check (possibly corrupted/tampered)"

  mkdir -p "${app_dir}" || err "Cannot create ${app_dir}"
  for file in "${APP_FILES[@]}"; do
    mv -f "${tmp_dir}/${file}" "${app_dir}/${file}"
  done
  ok "Application files in ${app_dir} (${#APP_FILES[@]} files, no repository clone)"
}

sync_dependencies() {
  local app_dir="$1"

  [[ -f "${app_dir}/main.py" ]] || err "main.py not found in ${app_dir}"
  (cd "${app_dir}" && uv sync --locked --quiet) || err "uv sync failed in ${app_dir}"
  ok "Python dependencies synced"
}

verify_login() {
  local output="" status=0

  output="$(env -u OPENAI_API_KEY -u CODEX_API_KEY codex login status 2>&1)" || status=$?
  if [[ "${status}" -eq 0 && "${output}" == *"Logged in using ChatGPT"* ]]; then
    ok "Saved ChatGPT login found"
    return 0
  fi
  warn "A ChatGPT login is required; an API-key login is not used"
  return 1
}

print_login_instructions() {
  ok "Step 1 of 2 done — uv and the Codex CLI are in place"
  info "Sign in as this same user, then re-run this installer:"
  echo "  codex login --device-auth"
  echo "Open the printed link in your browser and enter the one-time code."
  echo "If device login is unavailable, use: codex login"
}

verify_cli() {
  local help=""

  help="$(codex exec --help)" || err "Cannot run codex exec --help"
  [[ "${help}" == *"--ignore-user-config"* && "${help}" == *"--ephemeral"* ]] \
    || err "Codex CLI is too old — update it: curl -fsSL https://chatgpt.com/codex/install.sh | sh"
}

smoke_test() {
  local app_dir="$1" codex_bin=""

  codex_bin="$(command -v codex)"
  info "Sending one real ping through the ChatGPT login..."
  (cd "${app_dir}" && uv run --locked main.py --once --codex "${codex_bin}") \
    || err "The test ping failed; no unit was installed. See the error above and re-run."
  ok "Test ping passed"
}

# =============================================================================
# systemd user unit
# =============================================================================

render_unit() {
  local app_dir="$1" output="$2" uv_bin="" codex_bin="" auth_home=""

  uv_bin="$(command -v uv)"
  codex_bin="$(command -v codex)"
  auth_home="${CODEX_HOME:-${HOME}/.codex}"
  python3 - "${app_dir}/${UNIT_NAME}.in" "${output}" "${app_dir}" "${uv_bin}" "${codex_bin}" "${auth_home}" << 'EOF'
from pathlib import Path
import sys

source, output, directory, uv, codex, auth_home = sys.argv[1:]

def quote(value):
    if "\n" in value or "\r" in value:
        raise SystemExit("A systemd path cannot contain a newline")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%") + '"'

values = {
    "__DIR__": directory,
    "__UV__": uv,
    "__CODEX__": codex,
    "__CODEX_ENV__": "CODEX_HOME=" + str(Path(auth_home).expanduser().resolve()),
    "__PATH_ENV__": "PATH=" + ":".join(dict.fromkeys([
        str(Path(codex).parent), str(Path(uv).parent),
        str(Path.home() / ".local/bin"), "/usr/local/bin", "/usr/bin", "/bin",
    ])),
}
unit = Path(source).read_text(encoding="utf-8")
for marker, value in values.items():
    escaped = quote(value)
    # WorkingDirectory takes one literal path; unlike ExecStart, it does not parse shell quotes.
    if marker == "__DIR__":
        escaped = value.replace("%", "%%")
    unit = unit.replace(marker, escaped)
Path(output).write_text(unit, encoding="utf-8")
EOF
}

install_unit() {
  local app_dir="$1"

  mkdir -p "${UNIT_DIR}"
  render_unit "${app_dir}" "${UNIT_DIR}/${UNIT_NAME}"
  systemctl --user daemon-reload
  systemctl --user enable "${UNIT_NAME}" > /dev/null 2>&1 \
    || err "systemctl --user enable ${UNIT_NAME} failed"
  systemctl --user restart "${UNIT_NAME}" || err "systemctl --user restart ${UNIT_NAME} failed"
  ok "Unit installed and started"
}

# Without linger systemd kills the user manager at logout and the pings stop silently
enable_linger() {
  loginctl enable-linger > /dev/null 2>&1 \
    || warn "loginctl enable-linger failed — pings will stop when your last session ends"
}

# =============================================================================
# Checks
# =============================================================================

wait_for_schedule_line() {
  local waited=0 line=""

  while [[ "${waited}" -lt "${JOURNAL_WAIT_S}" ]]; do
    line="$(journalctl --user -u "${UNIT_NAME}" -n 20 --no-pager 2> /dev/null | grep -F "next ping" | tail -n 1 || true)"
    if [[ -n "${line}" ]]; then
      printf '%s\n' "${line}"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

run_checks() {
  local user_name="$1" failures=0 state="" schedule=""

  state="$(systemctl --user is-enabled "${UNIT_NAME}" 2> /dev/null || true)"
  if [[ "${state}" == "enabled" ]]; then
    ok "check: unit enabled"
  else
    warn "check: unit not enabled (is-enabled: ${state:-unknown})"
    failures=$((failures + 1))
  fi

  state="$(systemctl --user is-active "${UNIT_NAME}" 2> /dev/null || true)"
  if [[ "${state}" == "active" ]]; then
    ok "check: unit active"
  else
    warn "check: unit not active (is-active: ${state:-unknown})"
    failures=$((failures + 1))
  fi

  state="$(loginctl show-user "${user_name}" --property=Linger --value 2> /dev/null || true)"
  if [[ "${state}" == "yes" ]]; then
    ok "check: linger enabled (survives logout and reboot)"
  else
    warn "check: linger is '${state:-unknown}' — pings stop at logout"
    failures=$((failures + 1))
  fi

  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if schedule="$(wait_for_schedule_line)"; then
    ok "check: schedule armed — ${schedule##*INFO }"
  else
    warn "check: no 'next ping' line in the journal after ${JOURNAL_WAIT_S}s"
    failures=$((failures + 1))
  fi

  [[ "${failures}" -eq 0 ]] || err "${failures} check(s) failed — see 'journalctl --user -u ${UNIT_NAME} -n 50'"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  local app_dir="" user_name=""

  require_preconditions
  ensure_local_bin_on_path
  user_name="$(id -un)"

  info "Step 1 of 2: tools and login"
  ensure_uv
  ensure_codex
  verify_cli
  # A logged-out or API-key CLI must not leave a unit that fails every slot.
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if ! verify_login; then
    print_login_instructions
    return 0
  fi

  info "Step 2 of 2: application, unit, checks"
  app_dir="${INSTALL_DIR}"
  fetch_app_files "${app_dir}"
  sync_dependencies "${app_dir}"
  smoke_test "${app_dir}"

  install_unit "${app_dir}"
  enable_linger
  run_checks "${user_name}"

  ok "codex-auto-ping is running"
  echo "Directory: ${app_dir}"
  echo "Logs:      journalctl --user -u ${UNIT_NAME} -f"
  echo "Missed:    journalctl --user -u ${UNIT_NAME} -p err"
  echo "Update:    re-run this installer"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
