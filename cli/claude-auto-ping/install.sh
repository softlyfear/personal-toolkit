#!/usr/bin/env bash
#
# install.sh — install claude-auto-ping as a systemd user unit: no prompts, no root, checks at the end
#
# Usage:  bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/cli/claude-auto-ping/install.sh)
#         CLAUDE_AUTO_PING_DIR=/srv/toolkit bash <(wget -qO- ...)   # clone somewhere else
# Requires: wget, git, a systemd user session; never root
# Uninstall: systemctl --user disable --now claude-auto-ping
#            rm ~/.config/systemd/user/claude-auto-ping.service
#
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Constants
# =============================================================================

readonly REPO_URL="https://github.com/softlyfear/personal-toolkit.git"
readonly APP_SUBDIR="cli/claude-auto-ping"
readonly UNIT_NAME="claude-auto-ping.service"
readonly LOCAL_BIN="${HOME}/.local/bin"
readonly UNIT_DIR="${HOME}/.config/systemd/user"
readonly INSTALL_DIR="${CLAUDE_AUTO_PING_DIR:-${HOME}/personal-toolkit}"
readonly JOURNAL_WAIT_S=10

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
    || err "Run as your normal user, not root: the unit is user-level and the login token lives in \${HOME}/.claude"

  for required_cmd in wget git mktemp sed systemctl loginctl; do
    command -v "${required_cmd}" > /dev/null 2>&1 \
      || err "Required command not found: ${required_cmd}"
  done

  systemctl --user show-environment > /dev/null 2>&1 \
    || err "No systemd user session for this user — log in over SSH as this user and retry"
}

# ~/.local/bin holds uv and claude but is absent from PATH in a fresh non-login shell
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

ensure_claude() {
  if command -v claude > /dev/null 2>&1; then
    ok "claude CLI already present"
    return 0
  fi
  # shellcheck disable=SC2310 # predicate; its return code is handled by set -e in the caller chain
  install_from_url "https://claude.ai/install.sh" "claude"
  command -v claude > /dev/null 2>&1 || err "claude is still not on PATH after install"
  ok "claude CLI installed"
}

# =============================================================================
# Repository and dependencies
# =============================================================================

sync_repo() {
  local remote=""

  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    remote="$(git -C "${INSTALL_DIR}" remote get-url origin 2> /dev/null || true)"
    [[ "${remote}" == *"personal-toolkit"* ]] \
      || err "${INSTALL_DIR} is a git repo with origin '${remote}' — set CLAUDE_AUTO_PING_DIR to another path"
    git -C "${INSTALL_DIR}" pull --ff-only --quiet \
      || warn "git pull failed; continuing with the revision already checked out"
    ok "Repository up to date: ${INSTALL_DIR}"
    return 0
  fi

  [[ ! -e "${INSTALL_DIR}" ]] \
    || err "${INSTALL_DIR} exists and is not a git clone — set CLAUDE_AUTO_PING_DIR to another path"
  git clone --quiet "${REPO_URL}" "${INSTALL_DIR}" || err "git clone failed"
  ok "Repository cloned: ${INSTALL_DIR}"
}

sync_dependencies() {
  local app_dir="$1"

  [[ -f "${app_dir}/main.py" ]] || err "main.py not found in ${app_dir}"
  (cd "${app_dir}" && uv sync --quiet) || err "uv sync failed in ${app_dir}"
  ok "Python dependencies synced"
}

# The only way to tell a logged-in CLI from a logged-out one, and it is the smoke test too
verify_ping() {
  local app_dir="$1"

  info "Sending one test ping — this already opens a session window..."
  (cd "${app_dir}" && uv run --quiet main.py --once) \
    || err "Test ping failed. Most likely the CLI is not logged in: run 'claude' once interactively, then re-run this installer"
  ok "Test ping delivered"
}

# =============================================================================
# systemd user unit
# =============================================================================

install_unit() {
  local app_dir="$1" uv_bin=""

  uv_bin="$(command -v uv)"
  mkdir -p "${UNIT_DIR}"
  sed "s|__DIR__|${app_dir}|; s|__UV__|${uv_bin}|" "${app_dir}/${UNIT_NAME}.in" \
    > "${UNIT_DIR}/${UNIT_NAME}" || err "Failed to render ${UNIT_DIR}/${UNIT_NAME}"
  systemctl --user daemon-reload
  systemctl --user enable --now "${UNIT_NAME}" > /dev/null 2>&1 \
    || err "systemctl --user enable --now ${UNIT_NAME} failed"
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

  ensure_uv
  ensure_claude
  sync_repo

  app_dir="${INSTALL_DIR}/${APP_SUBDIR}"
  sync_dependencies "${app_dir}"
  verify_ping "${app_dir}"

  install_unit "${app_dir}"
  enable_linger
  run_checks "${user_name}"

  ok "claude-auto-ping is running"
  echo "Directory: ${app_dir}"
  echo "Logs:      journalctl --user -u ${UNIT_NAME} -f"
  echo "Missed:    journalctl --user -u ${UNIT_NAME} -p err"
  echo "Update:    git -C ${INSTALL_DIR} pull && systemctl --user restart ${UNIT_NAME}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
