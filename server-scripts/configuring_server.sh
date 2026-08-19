#!/usr/bin/env bash
#
# configuring_server.sh — initial VPS hardening (Ubuntu, latest LTS)
#
# Usage:  bash configuring_server.sh [port] [--user NAME] [--password PASS | --password-file PATH]
# Requires: root, interactive TTY (/dev/tty)
#
# Execution order (main):
#   steps 1–3 — system update, packages, unattended-upgrades, NTP
#   step 4    — SSH: sudo user + hardening (key or password)
#   steps 5–8 — UFW, Fail2Ban, sysctl, journald, cron/at
#
# Functions grouped by: UI · prompts · SSH keys · network · rollback · users · sshd · services
#
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Constants and config paths
# =============================================================================

readonly DEFAULT_SSH_PORT=2244
readonly PROVIDER_DEFAULT_USER="user"
readonly SCRIPT_RAW_URL="https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/configuring_server.sh"

readonly SSHD_MAIN="/etc/ssh/sshd_config"
readonly SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
# The 00- prefix is required: sshd applies the FIRST value it encounters,
# and drop-ins are read in lexicographic order — 00- wins over 50-cloud-init.conf
readonly SSHD_DROPIN_FILE="${SSHD_DROPIN_DIR}/00-hardening.conf"

readonly SSH_KEY_TYPE='ssh-ed25519|ecdsa-sha2-nistp(256|384|521)'
readonly SSH_KEY_PATTERN_FILE="(^|[[:space:],\"])(${SSH_KEY_TYPE}) "

# UFW keeps its rules and default policies in plain files; backing those up is the
# only way to undo `ufw delete`, which has no inverse of its own.
readonly UFW_STATE_FILES=(/etc/ufw/user.rules /etc/ufw/user6.rules /etc/ufw/ufw.conf /etc/default/ufw)

readonly AUTOREVERT_SNAPSHOT="/root/.pre-hardening-ssh.tar"
readonly AUTOREVERT_SCRIPT="/usr/local/sbin/hardening-autorevert"
readonly AUTOREVERT_CONFIRM="/usr/local/sbin/hardening-confirm"
readonly AUTOREVERT_SERVICE="/etc/systemd/system/hardening-autorevert.service"
readonly AUTOREVERT_TIMER="/etc/systemd/system/hardening-autorevert.timer"
# Below 5 minutes the timer could fire while the script is still finishing.
readonly MIN_CONFIRM_WINDOW_MIN=5
readonly MAX_CONFIRM_WINDOW_MIN=1440

# =============================================================================
# Rollback state (revert on failure until SCRIPT_SUCCEEDED=true)
# =============================================================================

# Assigned in main so that sourcing this file runs nothing.
ROLLBACK_ID=""
ROLLBACK_SSHD_BACKUP=""
ROLLBACK_SSHD_DROPIN_BACKUP=""
ROLLBACK_SSHD_DROPIN_HAD_FILE=false
ROLLBACK_FAIL2BAN_TOUCHED=false
ROLLBACK_FAIL2BAN_BACKUP=""
ROLLBACK_FAIL2BAN_HAD_FILE=false
ROLLBACK_SUDOERS_BACKUP=""
ROLLBACK_SUDOERS_CREATED=false
SSH_SOCKET_MASKED=false
SSH_SOCKET_DISABLED=false
ROLLBACK_UFW_WAS_ACTIVE=false
ROLLBACK_UFW_MODIFIED=false
ROLLBACK_UFW_BACKUP_DIR=""
ROLLBACK_AUTOREVERT_INSTALLED=false
SCRIPT_SUCCEEDED=false
SYSCTL_LOG=""
SSH_USER_PASSWORD=""
CREDENTIALS_FILE=""
CLI_PRESET_PASSWORD=""
CONFIRM_WINDOW_MIN=0
PROVIDER_USER_CLEANUP_FAILED=false
ROLLBACK_SYSCTL_UNIT_CREATED=false

# =============================================================================
# UI: logging and final summary
# =============================================================================

info() { echo -e "\033[35m[INFO]  $1\033[0m" >&2; }
ok() { echo -e "\033[32m[OK]    $1\033[0m" >&2; }
warn() { echo -e "\033[33m[WARN]  $1\033[0m" >&2; }
err() {
  echo -e "\033[31m[ERROR] $1\033[0m" >&2
  exit 1
}
sep() { echo -e "\033[35m-----------------------------------------------------------------\033[0m" >&2; }

readonly C_R='\033[0m' C_B='\033[1m' C_D='\033[2m'
readonly C_G='\033[32m' C_C='\033[36m' C_M='\033[35m' C_Y='\033[33m' C_BL='\033[34m'

sum_line() { echo -e "  ${C_G}✔${C_R}  $1"; }
sum_item() { echo -e "  ${C_G}✔${C_R}  ${C_B}$1${C_R}${2:+ ${C_D}— $2${C_R}}"; }
sum_cmd() { echo -e "      ${C_Y}$1${C_R}"; }
sum_note() { echo -e "  ${C_Y}⚠${C_R}  $1"; }

detect_server_ip() {
  local ip=""

  # Address the admin SSH'd into (best when script runs over SSH)
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    ip="$(awk '{print $3}' <<< "${SSH_CONNECTION}")"
    if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s' "${ip}"
      return 0
    fi
  fi

  # Default route source (typical VPS address)
  if command -v ip > /dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2> /dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
    if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s' "${ip}"
      return 0
    fi
  fi

  # First global IPv4 on the host
  if command -v hostname > /dev/null 2>&1; then
    ip="$(hostname -I 2> /dev/null | awk '{print $1}')"
    if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s' "${ip}"
      return 0
    fi
  fi

  printf '%s' '<your-server-ip>'
}

print_final_summary() {
  echo ""
  echo -e "${C_M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_R}"
  echo -e "${C_B}${C_G}  ✔  SERVER HARDENING COMPLETE${C_R}"
  echo -e "${C_M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_R}"
  echo ""
  echo -e "${C_B}${C_C}  Summary${C_R}"
  echo ""

  sum_line "System updated/upgraded"

  if [[ "${USE_SSH_KEY_AUTH}" == "true" ]]; then
    sum_item "SSH" "publickey only · ed25519/ecdsa · rsa disabled"
    if [[ "${USE_NOPASSWD_SUDO:-false}" == "true" ]]; then
      sum_item "Sudo access" "passwordless (NOPASSWD)"
    else
      sum_item "Sudo access" "password required"
    fi
  else
    sum_item "SSH" "password only · root login disabled"
    sum_item "Sudo access" "password required (NOPASSWD removed if existed)"
  fi

  sum_item "Sudo user" "${SSH_USER} · AllowUsers · root login disabled"
  sum_item "SSH port" "${SSH_PORT}/tcp · IPv4 only"
  [[ "${SSH_PORT}" != "22" ]] && sum_item "ssh.socket" "disabled and masked"
  sum_item "UFW" "enabled · only ${SSH_PORT}/tcp (limit) · logging on"
  sum_item "Fail2Ban" "sshd jail enabled"
  sum_line "Unattended upgrades enabled"
  sum_line "NTP time synchronization enabled"
  sum_line "Sysctl hardening (/etc/sysctl.d/98-hardening.conf)"
  sum_line "Journald log limits (SystemMaxUse=200M, MaxRetentionSec=14day)"

  echo ""
  echo -e "${C_B}${C_BL}  Next steps${C_R}"
  echo ""

  if [[ -n "${SSH_USER_PASSWORD:-}" ]]; then
    echo -e "  ${C_B}Credentials${C_R} ${C_D}(save now — shown once)${C_R}"
    echo ""
    sum_cmd "User:     ${SSH_USER}"
    sum_cmd "Password: ${SSH_USER_PASSWORD}"
    echo ""
    if [[ -n "${CREDENTIALS_FILE}" ]]; then
      sum_note "Also saved to ${CREDENTIALS_FILE} (root, mode 600) — delete it once stored:"
      sum_cmd "shred -u ${CREDENTIALS_FILE}"
      echo ""
    fi
  fi

  local server_ip=""
  server_ip="$(detect_server_ip)"

  sum_note "DO NOT CLOSE THIS SESSION YET — test in a new terminal:"
  sum_cmd "ssh -p ${SSH_PORT} ${SSH_USER}@${server_ip}"
  sum_cmd "sudo -i"
  echo ""

  if [[ "${ROLLBACK_AUTOREVERT_INSTALLED}" == "true" ]]; then
    sum_note "Auto-revert is armed: SSH goes back to its pre-hardening state in ${CONFIRM_WINDOW_MIN} min."
    sum_note "Once the new session above works, cancel it:"
    sum_cmd "sudo ${AUTOREVERT_CONFIRM}"
    echo ""
  fi
  echo -e "${C_M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_R}"
}

# =============================================================================
# Interactive input (TTY)
# =============================================================================

read_tty() {
  if [[ ! -r /dev/tty ]]; then
    err "Interactive input requires a TTY. Download first: wget -qO /tmp/setup.sh ${SCRIPT_RAW_URL} && bash /tmp/setup.sh"
  fi
  IFS= read -r "$1" < /dev/tty
}

sanitize_username_input() {
  local raw="$1"
  raw="${raw//$'\r'/}"
  raw="${raw//$'\n'/}"
  raw="${raw//$'\ufeff'/}"
  printf '%s' "${raw}" | LC_ALL=C tr -cd '[:alnum:]_-' | tr '[:upper:]' '[:lower:]'
}

# root is rejected: PermitRootLogin no would block login under that name anyway,
# and the operator would silently end up with no working access and no way to roll back.
is_reserved_username() {
  case "$1" in
    root) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_yes_no() {
  local -n _result=$1
  local prompt=$2
  local default_yes=${3:-true}
  local max_attempts=5
  local attempt=1
  local input=""

  while ((attempt <= max_attempts)); do
    echo ""
    info "${prompt}"
    if [[ "${default_yes}" == "true" ]]; then
      info "[Y/n] (default: yes — Enter or Space)"
    else
      info "[y/N] (default: no — Enter or Space)"
    fi
    read_tty input
    input="${input//[[:space:]]/}"

    if [[ -z "${input}" ]]; then
      if [[ "${default_yes}" == "true" ]]; then
        _result=true
      else
        _result=false
      fi
      return 0
    fi

    case "${input,,}" in
      y | yes)
        _result=true
        return 0
        ;;
      n | no)
        _result=false
        return 0
        ;;
      *)
        # Anything else falls through to the retry warning below.
        ;;
    esac

    warn "Enter y/yes or n/no (try again ${attempt}/${max_attempts})"
    ((attempt++)) || true
  done

  err "Too many invalid answers"
}

prompt_sudo_username() {
  if [[ -n "${SSH_USER:-}" ]]; then
    info "Using username: ${SSH_USER}"
    return 0
  fi

  local max_attempts=5
  local attempt=1
  local raw=""

  while ((attempt <= max_attempts)); do
    echo ""
    if ((attempt == 1)); then
      info "Enter sudo username [admin]:"
    else
      warn "Invalid username. Use a-z, 0-9, _, - (try again ${attempt}/${max_attempts}):"
    fi
    read_tty raw
    raw="$(sanitize_username_input "${raw}")"
    SSH_USER="${raw:-admin}"

    # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
    if is_reserved_username "${SSH_USER}"; then
      warn "Username '${SSH_USER}' is reserved (root login stays disabled by this script) — choose another (try again ${attempt}/${max_attempts}):"
      ((attempt++)) || true
      continue
    fi

    if [[ "${SSH_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      return 0
    fi
    ((attempt++)) || true
  done

  err "Invalid username after ${max_attempts} attempts"
}

validate_password_strength() {
  local pass="$1"

  [[ ${#pass} -ge 12 ]] || return 1
  [[ "${pass}" =~ [[:upper:]] ]] || return 1
  [[ "${pass}" =~ [[:lower:]] ]] || return 1
  [[ "${pass}" =~ [[:digit:]] ]] || return 1
  [[ "${pass}" =~ [^[:alnum:]] ]] || return 1
  return 0
}

generate_secure_password() {
  local pass="" random_part=""

  # hex yields lowercase + digits; the Aa1! suffix guarantees upper/lower/digit/special
  if command -v openssl > /dev/null 2>&1; then
    random_part="$(openssl rand -hex 12)"
  else
    random_part="$({ LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom || true; } | head -c 24)"
  fi
  [[ -n "${random_part}" ]] || return 1

  pass="${random_part}Aa1!"
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  validate_password_strength "${pass}" || return 1
  printf '%s' "${pass}"
  return 0
}

# An auto-generated password would otherwise exist only in the terminal that ran
# the script: losing that scrollback leaves a reachable server with unusable sudo.
save_user_credentials() {
  local user="$1"
  local pass="$2"
  local file="/root/.${user}-credentials"
  local created=""

  created="$(date -Is)"
  (
    umask 077
    printf 'user=%s\npassword=%s\nssh_port=%s\ncreated=%s\n' \
      "${user}" "${pass}" "${SSH_PORT}" "${created}" > "${file}"
  ) || {
    warn "Could not save credentials to ${file} — copy the password from the summary"
    return 0
  }
  chmod 600 "${file}"
  CREDENTIALS_FILE="${file}"
}

set_user_password() {
  local user="$1"
  local pass="$2"

  printf '%s:%s' "${user}" "${pass}" | chpasswd || err "Failed to set password for ${user}"
  SSH_USER_PASSWORD="${pass}"
  save_user_credentials "${user}" "${pass}"
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if ! validate_password_strength "${pass}"; then
    warn "Weak password for ${user} (allowed). Recommendation: 12+ chars with upper/lower/digit/special"
  fi
}

prompt_set_password() {
  local user="$1"
  local pass="" pass2=""
  local max_attempts=5
  local attempt=1

  if [[ ! -r /dev/tty ]]; then
    err "Password input requires a TTY. Download first: wget -qO /tmp/setup.sh ${SCRIPT_RAW_URL} && bash /tmp/setup.sh"
  fi

  while ((attempt <= max_attempts)); do
    echo ""
    if ((attempt == 1)); then
      info "Set password for ${user}:"
    else
      warn "Passwords did not match or empty. Try again (${attempt}/${max_attempts}):"
    fi
    IFS= read -rs pass < /dev/tty
    echo >&2
    info "Confirm password:"
    IFS= read -rs pass2 < /dev/tty
    echo >&2

    if [[ -n "${pass}" && "${pass}" == "${pass2}" ]]; then
      set_user_password "${user}" "${pass}"
      ok "Password set for ${user}"
      return 0
    fi
    ((attempt++)) || true
  done

  err "Failed to set password for ${user} after ${max_attempts} attempts"
}

setup_user_password() {
  local user="$1"

  if [[ -n "${CLI_PRESET_PASSWORD}" ]]; then
    set_user_password "${user}" "${CLI_PRESET_PASSWORD}"
    ok "Password set for ${user} (from --password)"
    return 0
  fi

  # Assigned via nameref in prompt_yes_no; declared so static analysis can see it.
  local GENERATE_PASSWORD=""
  prompt_yes_no GENERATE_PASSWORD "Generate secure password automatically?" true

  if [[ "${GENERATE_PASSWORD}" == "true" ]]; then
    local pass=""
    # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
    pass="$(generate_secure_password)" || err "Failed to generate strong password for ${user}"
    set_user_password "${user}" "${pass}"
    ok "Password set for ${user} (auto-generated strong password — shown once in summary)"
    return 0
  fi

  prompt_set_password "${user}"
}

# =============================================================================
# CLI argument parsing
# =============================================================================

usage() {
  cat << EOF
Usage:
  $(basename "$0") [port] [--user NAME] [--password PASS | --password-file PATH]
                          [--confirm-window MINUTES]

Options:
  port                   SSH port (default: ${DEFAULT_SSH_PORT})
  --user, -u NAME        sudo username (default: prompt, fallback admin)
  --password-file PATH   read password from a file — recommended for
                          automation, does not expose the value via ps/argv
  --password, -p PASS    user password — skips the password prompt.
                          WARNING: visible via ps/proc while the script runs;
                          prefer --password-file
  --confirm-window MIN   arm an auto-revert timer: SSH config and firewall go
                          back to their pre-hardening state after MIN minutes
                          (${MIN_CONFIRM_WINDOW_MIN}-${MAX_CONFIRM_WINDOW_MIN}) unless you run
                          ${AUTOREVERT_CONFIRM}
  --help, -h             show this help

Examples:
  $(basename "$0")
  $(basename "$0") 2255
  $(basename "$0") --user softly --password-file /root/.new-user-pass
  $(basename "$0") 2255 -u admin -p 'StrongP@ssw0rd!'
  $(basename "$0") 2255 --confirm-window 10
EOF
}

parse_cli_args() {
  SSH_PORT="${DEFAULT_SSH_PORT}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user | -u)
        [[ $# -ge 2 ]] || err "--user requires a value"
        SSH_USER="$(sanitize_username_input "$2")"
        [[ "${SSH_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]] || err "Invalid --user: $2"
        # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
        is_reserved_username "${SSH_USER}" && err "--user root is not allowed — root login stays disabled by this script"
        shift 2
        ;;
      --password | -p)
        [[ $# -ge 2 ]] || err "--password requires a value"
        CLI_PRESET_PASSWORD="$2"
        warn "--password exposes the value via 'ps'/'/proc/<pid>/cmdline' while this script runs — prefer --password-file for automation"
        shift 2
        ;;
      --password-file)
        [[ $# -ge 2 ]] || err "--password-file requires a path"
        [[ -f "$2" ]] || err "--password-file not found: $2"
        # shellcheck disable=SC2312 # exit status of this substitution is intentionally unused here
        [[ -z "$(find "$2" -perm -044 2> /dev/null)" ]] \
          || warn "--password-file $2 is group/world-readable — recommended: chmod 600 $2"
        CLI_PRESET_PASSWORD="$(head -n1 -- "$2")"
        CLI_PRESET_PASSWORD="${CLI_PRESET_PASSWORD%$'\r'}"
        [[ -n "${CLI_PRESET_PASSWORD}" ]] || err "--password-file is empty: $2"
        shift 2
        ;;
      --confirm-window)
        [[ $# -ge 2 ]] || err "--confirm-window requires a value in minutes"
        [[ "$2" =~ ^[0-9]+$ ]] || err "Invalid --confirm-window: $2 (expected minutes)"
        ((10#$2 >= MIN_CONFIRM_WINDOW_MIN && 10#$2 <= MAX_CONFIRM_WINDOW_MIN)) \
          || err "--confirm-window must be between ${MIN_CONFIRM_WINDOW_MIN} and ${MAX_CONFIRM_WINDOW_MIN} minutes"
        CONFIRM_WINDOW_MIN="$((10#$2))"
        shift 2
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      -*)
        err "Unknown option: $1 (try --help)"
        ;;
      *)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
          SSH_PORT="$1"
        else
          err "Invalid argument: $1 (try --help)"
        fi
        shift
        ;;
    esac
  done

  if ! [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || ((SSH_PORT < 1 || SSH_PORT > 65535)); then
    err "Invalid SSH port: ${SSH_PORT}"
  fi
}

# =============================================================================
# SSH public key: validation and loading
# =============================================================================

sanitize_ssh_pubkey_line() {
  local raw="$1"
  raw="${raw//$'\r'/}"
  raw="${raw//$'\n'/}"
  raw="${raw//$'\ufeff'/}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [[ "${raw}" =~ ^(ssh-[^[:space:]]+|ecdsa-sha2-nistp[0-9]+)[[:space:]]+([^[:space:]]+)(.*)$ ]]; then
    raw="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
  fi
  printf '%s' "${raw}"
}

looks_like_file_path() {
  local s="$1"
  # shellcheck disable=SC2088 # literal tilde matched against user input; must not expand
  [[ "${s}" == "~" || "${s}" == "~/"* || "${s}" == "/"* || "${s}" == "."* ]]
}

sshkey_file_valid() {
  ssh-keygen -l -f "$1" > /dev/null 2>&1
}

validate_ssh_pubkey() {
  local key="$1"
  local key_type="" tmp=""

  key="$(sanitize_ssh_pubkey_line "${key}")"
  [[ -n "${key}" ]] || err "Empty SSH public key"

  if [[ "${key}" == -----BEGIN* ]]; then
    err "This is a PRIVATE key. Use the PUBLIC key (ssh-ed25519 AAAA...) or a .pub file path"
  fi
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if looks_like_file_path "${key}"; then
    err "File not found: ${key} — paste the full key line from: cat ~/.ssh/id_ed25519.pub"
  fi

  key_type="${key%% *}"
  case "${key_type}" in
    ssh-ed25519 | ecdsa-sha2-nistp256 | ecdsa-sha2-nistp384 | ecdsa-sha2-nistp521) ;;
    ssh-rsa) err "ssh-rsa is not supported. Generate a new key: ssh-keygen -t ed25519" ;;
    *) err "Unsupported key type '${key_type}'. Use ed25519 or ecdsa (paste: cat ~/.ssh/id_ed25519.pub)" ;;
  esac

  tmp="$(mktemp)"
  printf '%s\n' "${key}" > "${tmp}"
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if ! sshkey_file_valid "${tmp}"; then
    rm -f "${tmp}"
    err "Invalid SSH public key. Paste the FULL line from: cat ~/.ssh/id_ed25519.pub"
  fi
  rm -f "${tmp}"
  ok "SSH public key valid (${key_type})"
}

expand_sshkey_path() {
  # shellcheck disable=SC2088 # literal tilde patterns match raw user input; expansion here would defeat the check
  case "$1" in
    "~") printf '%s' "${HOME}" ;;
    # Pattern quoted: an unquoted ~/ would itself expand and never match.
    "~/"*) printf '%s' "${HOME}/${1#"~/"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

load_ssh_pubkey() {
  local input="$1"
  local path="" key="" tmp=""

  input="$(sanitize_ssh_pubkey_line "${input}")"
  [[ -n "${input}" ]] || err "Empty input — paste the public key or a .pub file path"

  if [[ "${input}" =~ ^cat[[:space:]] ]]; then
    err "You pasted the shell command, not the key. On your LAPTOP run that command, then paste the line that starts with ssh-ed25519"
  fi

  if [[ "${input}" == -----BEGIN* ]]; then
    err "This is a PRIVATE key. Use the PUBLIC key (ssh-ed25519 AAAA...) or a .pub file path"
  fi

  tmp="$(mktemp)"
  printf '%s\n' "${input}" > "${tmp}"
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if sshkey_file_valid "${tmp}"; then
    rm -f "${tmp}"
    info "Public key entered manually"
    printf '%s' "${input}"
    return 0
  fi
  rm -f "${tmp}"

  path="$(expand_sshkey_path "${input}")"

  if [[ ! -f "${path}" && "${path}" != *.pub && -f "${path}.pub" ]]; then
    warn "Private key path given — using ${path}.pub instead"
    path="${path}.pub"
  fi

  if [[ -f "${path}" ]]; then
    if grep -qE '^-----BEGIN (OPENSSH |EC )?PRIVATE KEY-----' "${path}" 2> /dev/null; then
      err "File is a PRIVATE key: ${path} — use the .pub file or paste the public key line"
    fi
    local raw_key=""
    raw_key="$(tr -d '\r\n' < "${path}")"
    key="$(sanitize_ssh_pubkey_line "${raw_key}")"
    tmp="$(mktemp)"
    printf '%s\n' "${key}" > "${tmp}"
    # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
    if ! sshkey_file_valid "${tmp}"; then
      rm -f "${tmp}"
      err "File is not a valid public key: ${path}"
    fi
    rm -f "${tmp}"
    info "Public key loaded from file: ${path}"
    printf '%s' "${key}"
    return 0
  fi

  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if looks_like_file_path "${input}"; then
    err "Public key file not found on this server: ${input} — paste the key line (ssh-ed25519 AAAA...), not a laptop path"
  fi

  err "Invalid SSH public key. Paste the line starting with ssh-ed25519 (run on laptop: cat ~/.ssh/id_ed25519.pub, copy the output)"
}

# =============================================================================
# Network and systemd: ports, sshd, units
# =============================================================================

unit_exists() { systemctl cat "$1" > /dev/null 2>&1; }

ss_listening_on_port() {
  local port="$1"
  ss -tln 2> /dev/null | awk -v port="${port}" '
    $1 == "LISTEN" {
      split($4, a, ":")
      if (a[length(a)] == port) found = 1
    }
    END { exit !found }
  '
}

ss_listening_on_ipv6_port() {
  local port="$1"
  ss -tln 2> /dev/null | awk -v port="${port}" '
    $1 == "LISTEN" && $4 ~ ("^\\[::\\]:" port "$") { found = 1 }
    END { exit !found }
  '
}

port_in_use() {
  ss_listening_on_port "$1"
}

get_sshd_runtime_config() {
  sshd -T 2> /dev/null || true
}

verify_ssh_port_available() {
  local port="$1"

  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if ! port_in_use "${port}"; then
    ok "Port ${port}/tcp is available"
    return 0
  fi

  if ss -tlnp 2> /dev/null | grep -E ":${port}\\b" | grep -qiE 'sshd|ssh'; then
    warn "Port ${port}/tcp already used by SSH — assuming re-run"
    return 0
  fi

  err "Port ${port}/tcp is already in use. Specify a free port: bash $0 <port>"
}

restart_sshd_service() {
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if unit_exists ssh.service; then
    systemctl enable ssh.service || true
    systemctl restart ssh.service || err "Failed to restart ssh.service"
  elif unit_exists sshd.service; then
    systemctl enable sshd.service || true
    systemctl restart sshd.service || err "Failed to restart sshd.service"
  else
    err "No ssh service unit found (ssh.service/sshd.service)"
  fi
}

handle_ssh_socket() {
  # Ubuntu 22.04+: ssh.socket listens on :22 alongside sshd_config — mask when using a custom port
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if ! unit_exists ssh.socket; then
    return 0
  fi

  if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
    warn "ssh.socket is active/enabled; disabling it to honor Port from sshd_config"
    systemctl disable --now ssh.socket || err "Failed to disable ssh.socket"
    SSH_SOCKET_DISABLED=true
  fi

  if systemctl is-enabled ssh.socket 2> /dev/null | grep -q '^masked$'; then
    return 0
  fi

  if systemctl mask ssh.socket > /dev/null 2>&1; then
    SSH_SOCKET_MASKED=true
  fi
}

# =============================================================================
# Lockout auto-revert (--confirm-window)
# =============================================================================

remove_lockout_autorevert() {
  systemctl disable --now hardening-autorevert.timer > /dev/null 2>&1 || true
  rm -f "${AUTOREVERT_TIMER}" "${AUTOREVERT_SERVICE}" "${AUTOREVERT_SCRIPT}" \
    "${AUTOREVERT_CONFIRM}" "${AUTOREVERT_SNAPSHOT}"
  systemctl daemon-reload > /dev/null 2>&1 || true
  ROLLBACK_AUTOREVERT_INSTALLED=false
}

# Arms a one-shot timer that puts SSH back the way it was unless the operator runs
# hardening-confirm. The printed "test in a new terminal" warning is advice; this
# is the only mechanism that actually recovers a server nobody can log into.
install_lockout_autorevert() {
  local minutes="$1"

  tar -C /etc -cf "${AUTOREVERT_SNAPSHOT}" ssh || err "Failed to snapshot /etc/ssh for auto-revert"
  chmod 600 "${AUTOREVERT_SNAPSHOT}"

  cat > "${AUTOREVERT_SCRIPT}" << EOF
#!/usr/bin/env bash
# Installed by configuring_server.sh --confirm-window ${minutes}.
set -uo pipefail
logger -t hardening-autorevert "no confirmation within ${minutes}m — restoring pre-hardening SSH access"
ufw --force disable > /dev/null 2>&1 || true
rm -rf /etc/ssh
tar -C /etc -xf "${AUTOREVERT_SNAPSHOT}"
systemctl unmask ssh.socket > /dev/null 2>&1 || true
systemctl enable --now ssh.socket > /dev/null 2>&1 || true
systemctl restart ssh.service > /dev/null 2>&1 || true
systemctl stop fail2ban > /dev/null 2>&1 || true
systemctl disable --now hardening-autorevert.timer > /dev/null 2>&1 || true
# The snapshot holds this host's private SSH keys; drop it as soon as the restore
# that needed it has visibly produced a usable /etc/ssh.
if [[ -s /etc/ssh/sshd_config ]]; then
  rm -f "${AUTOREVERT_SNAPSHOT}"
fi
EOF
  chmod 700 "${AUTOREVERT_SCRIPT}"

  cat > "${AUTOREVERT_CONFIRM}" << EOF
#!/usr/bin/env bash
# Cancels the pending hardening auto-revert. Run this once a new SSH session works.
set -uo pipefail
systemctl disable --now hardening-autorevert.timer > /dev/null 2>&1 || true
rm -f "${AUTOREVERT_TIMER}" "${AUTOREVERT_SERVICE}" "${AUTOREVERT_SCRIPT}" "${AUTOREVERT_SNAPSHOT}"
systemctl daemon-reload > /dev/null 2>&1 || true
printf 'Hardening confirmed — automatic revert cancelled.\n'
printf 'This helper is no longer needed: rm -f %s\n' "${AUTOREVERT_CONFIRM}"
EOF
  chmod 700 "${AUTOREVERT_CONFIRM}"

  cat > "${AUTOREVERT_SERVICE}" << EOF
[Unit]
Description=Revert SSH hardening because no working login was confirmed

[Service]
Type=oneshot
ExecStart=${AUTOREVERT_SCRIPT}
# Runs once ExecStart has exited, so the helper can delete itself without a
# half-read script; leaving these behind would strand dead units on the host.
ExecStopPost=/bin/bash -c 'rm -f ${AUTOREVERT_SCRIPT} ${AUTOREVERT_CONFIRM} ${AUTOREVERT_TIMER} ${AUTOREVERT_SERVICE}; systemctl daemon-reload'
EOF

  cat > "${AUTOREVERT_TIMER}" << EOF
[Unit]
Description=Deadline for confirming a working SSH login after hardening

[Timer]
OnActiveSec=${minutes}min
AccuracySec=1s
RemainAfterElapse=no

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now hardening-autorevert.timer > /dev/null 2>&1 \
    || err "Failed to arm the auto-revert timer"
  ROLLBACK_AUTOREVERT_INSTALLED=true
  ok "Auto-revert armed: SSH is restored in ${minutes} min unless you run ${AUTOREVERT_CONFIRM}"
}

# =============================================================================
# Rollback: revert critical changes on failure
# =============================================================================

rollback_on_failure() {
  local exit_code=$?
  [[ "${exit_code}" -eq 0 || "${SCRIPT_SUCCEEDED}" == "true" ]] && return 0

  sep
  warn "Script failed (exit ${exit_code}). Rolling back critical changes..."

  if [[ -n "${ROLLBACK_SSHD_BACKUP}" ]]; then
    if [[ "${ROLLBACK_SSHD_DROPIN_HAD_FILE}" == "true" && -f "${ROLLBACK_SSHD_DROPIN_BACKUP}" ]]; then
      cp "${ROLLBACK_SSHD_DROPIN_BACKUP}" "${SSHD_DROPIN_FILE}"
      warn "Restored ${SSHD_DROPIN_FILE} from backup"
    elif [[ "${ROLLBACK_SSHD_DROPIN_HAD_FILE}" == "false" && -f "${SSHD_DROPIN_FILE}" ]]; then
      rm -f "${SSHD_DROPIN_FILE}"
      warn "Removed ${SSHD_DROPIN_FILE}"
    fi
  fi

  if [[ -n "${ROLLBACK_SSHD_BACKUP}" && -f "${ROLLBACK_SSHD_BACKUP}" ]]; then
    cp "${ROLLBACK_SSHD_BACKUP}" "${SSHD_MAIN}"
    warn "Restored ${SSHD_MAIN} from backup"
    if sshd -t > /dev/null 2>&1; then
      # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
      if unit_exists ssh.service; then
        systemctl restart ssh.service > /dev/null 2>&1 || true
      elif unit_exists sshd.service; then
        systemctl restart sshd.service > /dev/null 2>&1 || true
      fi
    fi
  fi

  if [[ "${SSH_SOCKET_MASKED}" == "true" || "${SSH_SOCKET_DISABLED}" == "true" ]]; then
    systemctl unmask ssh.socket > /dev/null 2>&1 || true
    if [[ "${SSH_SOCKET_DISABLED}" == "true" ]]; then
      systemctl enable ssh.socket > /dev/null 2>&1 || true
      warn "Re-enabled ssh.socket"
    else
      warn "Unmasked ssh.socket"
    fi
  fi

  if [[ "${ROLLBACK_FAIL2BAN_TOUCHED}" == "true" ]]; then
    if [[ -n "${ROLLBACK_FAIL2BAN_BACKUP}" && -f "${ROLLBACK_FAIL2BAN_BACKUP}" ]]; then
      cp "${ROLLBACK_FAIL2BAN_BACKUP}" /etc/fail2ban/jail.local
      systemctl restart fail2ban > /dev/null 2>&1 || true
      warn "Restored /etc/fail2ban/jail.local from backup"
    elif [[ "${ROLLBACK_FAIL2BAN_HAD_FILE}" == "false" && -f /etc/fail2ban/jail.local ]]; then
      rm -f /etc/fail2ban/jail.local
      systemctl restart fail2ban > /dev/null 2>&1 || true
      warn "Removed newly created /etc/fail2ban/jail.local"
    fi
  fi

  local sudoers_file="/etc/sudoers.d/${SSH_USER:-}"
  if [[ -n "${ROLLBACK_SUDOERS_BACKUP}" && -f "${ROLLBACK_SUDOERS_BACKUP}" ]]; then
    cp "${ROLLBACK_SUDOERS_BACKUP}" "${sudoers_file}"
    warn "Restored ${sudoers_file} from backup"
  elif [[ "${ROLLBACK_SUDOERS_CREATED}" == "true" && -f "${sudoers_file}" ]]; then
    rm -f "${sudoers_file}"
    warn "Removed ${sudoers_file}"
  fi

  if [[ "${ROLLBACK_SYSCTL_UNIT_CREATED}" == "true" ]]; then
    systemctl disable sysctl-hardening.service > /dev/null 2>&1 || true
    rm -f /etc/systemd/system/sysctl-hardening.service
    systemctl daemon-reload > /dev/null 2>&1 || true
    warn "Removed sysctl-hardening.service"
  fi

  if [[ "${ROLLBACK_UFW_MODIFIED}" == "true" ]]; then
    restore_ufw_config
    if [[ "${ROLLBACK_UFW_WAS_ACTIVE}" == "true" ]]; then
      # Re-enable rather than reload: it reloads an active firewall and restores an
      # enabled-but-stopped one, so it is correct either way.
      ufw --force enable > /dev/null 2>&1 || true
      warn "Restored previous UFW rules and default policies"
    else
      ufw --force disable > /dev/null 2>&1 || true
      warn "UFW disabled and rules restored (was inactive before script)"
    fi
    discard_ufw_backup
  fi

  if [[ "${ROLLBACK_AUTOREVERT_INSTALLED}" == "true" ]]; then
    remove_lockout_autorevert
    warn "Disarmed the auto-revert timer (the script already rolled itself back)"
  fi

  exit "${exit_code}"
}

# =============================================================================
# Sudo user: creation, password, authorized_keys
# =============================================================================

remove_provider_default_user() {
  local stale_user="${PROVIDER_DEFAULT_USER}"
  local max_attempts=3
  local attempt=1

  if [[ "${SSH_USER}" == "${stale_user}" ]]; then
    info "Target user is '${stale_user}' — skipping provider default cleanup"
    return 0
  fi

  if ! id "${stale_user}" &> /dev/null; then
    return 0
  fi

  # shellcheck disable=SC2312 # exit status of this substitution is intentionally unused here
  if [[ "$(whoami)" == "${stale_user}" ]]; then
    warn "Cannot remove '${stale_user}' while logged in as that user — run as root"
    return 1
  fi

  # shellcheck disable=SC2312 # exit status of this substitution is intentionally unused here
  if [[ "$(id -u "${stale_user}")" -eq 0 ]]; then
    warn "Refusing to remove uid 0 account '${stale_user}'"
    return 1
  fi

  warn "Removing provider default user '${stale_user}' (target user: ${SSH_USER})..."
  rm -f "/etc/sudoers.d/${stale_user}"

  # ⚠️ RISK: userdel -rf irreversibly removes the account and its home directory.
  # No rollback possible — only runs after verify_ssh_authorized_key has confirmed
  # working access under the new sudo user.
  while ((attempt <= max_attempts)); do
    pkill -u "${stale_user}" 2> /dev/null || true
    sleep 1
    pkill -9 -u "${stale_user}" 2> /dev/null || true
    sleep 1

    if userdel -rf "${stale_user}" && ! id "${stale_user}" &> /dev/null; then
      ok "Removed provider default user '${stale_user}'"
      return 0
    fi

    warn "userdel attempt ${attempt}/${max_attempts} failed for '${stale_user}' — retrying"
    ((attempt++)) || true
  done

  warn "Failed to remove user '${stale_user}' after ${max_attempts} attempts"
  return 1
}

clear_history_file_for_user() {
  local user="$1"
  local hist_file=""
  local user_home=""

  user_home="$(getent passwd "${user}" | cut -d: -f6)"
  [[ -n "${user_home}" ]] || return 0
  hist_file="${user_home}/.bash_history"

  if [[ -f "${hist_file}" ]]; then
    : > "${hist_file}"
    chown "${user}:${user}" "${hist_file}" 2> /dev/null || true
    chmod 600 "${hist_file}" 2> /dev/null || true
  fi
}

clear_password_cli_history() {
  # Best-effort: while the script runs, --password is visible via `ps aux` and
  # /proc/<pid>/cmdline to all local users — that's a Linux kernel-level exposure,
  # it can't be erased after the fact. The only way to avoid it is --password-file.
  [[ -n "${CLI_PRESET_PASSWORD}" ]] || return 0

  warn "Clearing shell history files because --password/--password-file was used (best-effort)..."
  clear_history_file_for_user root

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    clear_history_file_for_user "${SUDO_USER}"
  fi

  unset CLI_PRESET_PASSWORD
}

ensure_sudo_user() {
  if id "${SSH_USER}" &> /dev/null; then
    local existing_uid=""
    existing_uid="$(id -u "${SSH_USER}")"
    if ((existing_uid < 1000)); then
      warn "'${SSH_USER}' already exists as a SYSTEM account (uid=${existing_uid}) — granting sudo/SSH access to it is unusual"
      local confirm_system_user=true
      prompt_yes_no confirm_system_user "Grant sudo and SSH key access to existing system account '${SSH_USER}' anyway?" false
      [[ "${confirm_system_user}" == "true" ]] \
        || err "Aborted: refusing to grant access to system account '${SSH_USER}' (uid=${existing_uid}) — pick a different --user"
    fi
    warn "User ${SSH_USER} already exists"
  else
    useradd -m -s /bin/bash "${SSH_USER}"
    ok "User ${SSH_USER} created"
  fi

  if getent group sudo > /dev/null; then
    usermod -aG sudo "${SSH_USER}"
    ok "User ${SSH_USER} added to sudo group"
  elif getent group wheel > /dev/null; then
    usermod -aG wheel "${SSH_USER}"
    ok "User ${SSH_USER} added to wheel group"
  else
    err "Neither sudo nor wheel group found"
  fi

  SSH_USER_HOME="$(getent passwd "${SSH_USER}" | cut -d: -f6)"
  [[ -n "${SSH_USER_HOME}" && -d "${SSH_USER_HOME}" ]] || err "Home directory not found for ${SSH_USER}"
}

configure_sudo_access() {
  local sudoers_file="/etc/sudoers.d/${SSH_USER}"

  if [[ "${1:-}" == "password" ]]; then
    # Password-only SSH: remove NOPASSWD from previous runs
    if [[ -f "${sudoers_file}" ]]; then
      ROLLBACK_SUDOERS_BACKUP="${sudoers_file}.bak_${ROLLBACK_ID}"
      cp "${sudoers_file}" "${ROLLBACK_SUDOERS_BACKUP}"
      rm -f "${sudoers_file}"
      ok "Removed NOPASSWD for ${SSH_USER} (password-only SSH mode)"
    fi
    setup_user_password "${SSH_USER}"
    ok "SSH login configured for ${SSH_USER} (password only)"
    return
  fi

  prompt_yes_no USE_NOPASSWD_SUDO "Enable passwordless sudo (NOPASSWD)? (less secure; default: no — sudo requires password)" false

  if [[ -f "${sudoers_file}" ]]; then
    ROLLBACK_SUDOERS_BACKUP="${sudoers_file}.bak_${ROLLBACK_ID}"
    cp "${sudoers_file}" "${ROLLBACK_SUDOERS_BACKUP}"
  fi

  if [[ "${USE_NOPASSWD_SUDO}" == "true" ]]; then
    echo "${SSH_USER} ALL=(ALL) NOPASSWD:ALL" > "${sudoers_file}"
    chmod 440 "${sudoers_file}"
    ROLLBACK_SUDOERS_CREATED=true
    visudo -cf "${sudoers_file}" || err "Invalid sudoers entry for ${SSH_USER}"
    ok "Passwordless sudo configured for ${SSH_USER} (NOPASSWD)"
  else
    rm -f "${sudoers_file}"
    ROLLBACK_SUDOERS_CREATED=false
    info "NOPASSWD disabled — ${SSH_USER} will need password for sudo"
    setup_user_password "${SSH_USER}"
    ok "Sudo configured for ${SSH_USER} (password required — NOPASSWD disabled)"
  fi
}

remove_legacy_rsa_keys() {
  local ak="${SSH_USER_HOME}/.ssh/authorized_keys"
  local tmp_file=""

  if [[ ! -f "${ak}" ]] || ! grep -qE '(^|[[:space:]]*)ssh-rsa ' "${ak}"; then
    return 0
  fi

  warn "Removing legacy ssh-rsa keys from ${ak} (rsa is disabled)"
  tmp_file="$(mktemp)"
  chmod 600 "${tmp_file}"
  grep -vE '(^|[[:space:]]*)ssh-rsa ' "${ak}" > "${tmp_file}" || true
  if [[ ! -s "${tmp_file}" ]]; then
    rm -f "${tmp_file}"
    err "No non-RSA keys remain in ${ak} after removing ssh-rsa"
  fi
  mv "${tmp_file}" "${ak}"
  chmod 600 "${ak}"
  chown "${SSH_USER}:${SSH_USER}" "${ak}"
}

setup_ssh_authorized_key() {
  local ak="${SSH_USER_HOME}/.ssh/authorized_keys"
  local sshkey="" sshkey_input=""

  mkdir -p "${SSH_USER_HOME}/.ssh"
  chmod 700 "${SSH_USER_HOME}/.ssh"
  chown "${SSH_USER}:${SSH_USER}" "${SSH_USER_HOME}/.ssh"

  echo ""
  info "Paste your SSH PUBLIC KEY (one line starting with ssh-ed25519 AAAA...):"
  warn "Run on your LAPTOP first: cat ~/.ssh/id_ed25519.pub"
  warn "Then paste the OUTPUT here — do NOT paste the cat command itself"
  read_tty sshkey_input

  sshkey="$(load_ssh_pubkey "${sshkey_input}")"
  validate_ssh_pubkey "${sshkey}"

  touch "${ak}"
  if grep -qF "${sshkey}" "${ak}"; then
    warn "Key already exists in ${ak}"
  else
    echo "${sshkey}" >> "${ak}"
    ok "SSH key added for ${SSH_USER}"
  fi

  chmod 600 "${ak}"
  chown "${SSH_USER}:${SSH_USER}" "${ak}"
  remove_legacy_rsa_keys
}

verify_ssh_authorized_key() {
  local ak="${SSH_USER_HOME}/.ssh/authorized_keys"

  info "Verifying SSH key for ${SSH_USER} before disabling root login..."
  [[ -f "${ak}" ]] || err "authorized_keys missing for ${SSH_USER}"
  [[ -s "${ak}" ]] || err "authorized_keys is empty for ${SSH_USER}"
  grep -qE "${SSH_KEY_PATTERN_FILE}" "${ak}" || err "No valid public key in ${ak} (ed25519/ecdsa required)"
  # shellcheck disable=SC2312 # exit status of this substitution is intentionally unused here
  [[ "$(stat -c '%a' "${SSH_USER_HOME}/.ssh")" == "700" ]] \
    || err ".ssh permissions incorrect for ${SSH_USER}"
  # shellcheck disable=SC2312 # exit status of this substitution is intentionally unused here
  [[ "$(stat -c '%a' "${ak}")" == "600" ]] \
    || err "authorized_keys permissions incorrect for ${SSH_USER}"
  # shellcheck disable=SC2312 # exit status of this substitution is intentionally unused here
  [[ "$(stat -c '%U:%G' "${SSH_USER_HOME}/.ssh")" == "${SSH_USER}:${SSH_USER}" ]] \
    || err ".ssh ownership incorrect for ${SSH_USER}"
  # shellcheck disable=SC2312 # exit status of this substitution is intentionally unused here
  [[ "$(stat -c '%U:%G' "${ak}")" == "${SSH_USER}:${SSH_USER}" ]] \
    || err "authorized_keys ownership incorrect for ${SSH_USER}"
  ok "SSH key verified for ${SSH_USER} (safe to disable root login)"
}

# =============================================================================
# SSH hardening: drop-in config, verification, orchestrator
# =============================================================================

backup_sshd_config() {
  ROLLBACK_SSHD_BACKUP="${SSHD_MAIN}.bak_${ROLLBACK_ID}"
  cp "${SSHD_MAIN}" "${ROLLBACK_SSHD_BACKUP}"
  mkdir -p "${SSHD_DROPIN_DIR}"

  if [[ -f "${SSHD_DROPIN_FILE}" ]]; then
    ROLLBACK_SSHD_DROPIN_HAD_FILE=true
    ROLLBACK_SSHD_DROPIN_BACKUP="${SSHD_DROPIN_FILE}.bak_${ROLLBACK_ID}"
    cp "${SSHD_DROPIN_FILE}" "${ROLLBACK_SSHD_DROPIN_BACKUP}"
  fi
}

apply_sshd_hardening() {
  local -a auth_lines=()
  backup_sshd_config
  # Leftover from older versions of this script — hardening now lives in 00-hardening.conf
  rm -f "${SSHD_DROPIN_DIR}/99-hardening.conf"

  if [[ "${USE_SSH_KEY_AUTH}" == "true" ]]; then
    auth_lines=(
      "AuthenticationMethods publickey"
      "PubkeyAuthentication yes"
      "PubkeyAcceptedAlgorithms -ssh-rsa,rsa-sha2-256,rsa-sha2-512"
      "PasswordAuthentication no"
    )
  else
    auth_lines=(
      "AuthenticationMethods password"
      "PubkeyAuthentication no"
      "PasswordAuthentication yes"
    )
  fi

  {
    cat << EOF
Port ${SSH_PORT}
AddressFamily inet
ListenAddress 0.0.0.0
PermitRootLogin no
AllowUsers ${SSH_USER}
EOF
    printf '%s\n' "${auth_lines[@]}"
    cat << 'EOF'
KbdInteractiveAuthentication no
HostbasedAuthentication no
GSSAPIAuthentication no
PermitEmptyPasswords no
UsePAM yes
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
PermitUserEnvironment no
Compression no
MaxAuthTries 3
MaxSessions 3
MaxStartups 10:30:60
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
EOF
  } > "${SSHD_DROPIN_FILE}"

  [[ "${SSH_PORT}" != "22" ]] && handle_ssh_socket

  info "Validating sshd config..."
  sshd -t || err "sshd config validation failed"
  restart_sshd_service
  sleep 1

  local sshd_runtime_cfg=""
  sshd_runtime_cfg="$(get_sshd_runtime_config)"

  grep -qE '^permitrootlogin[[:space:]]+no$' <<< "${sshd_runtime_cfg}" \
    || err "sshd effective PermitRootLogin is not 'no' (overridden by another config?)"

  if [[ "${USE_SSH_KEY_AUTH}" == "true" ]]; then
    grep -qE '^authenticationmethods[[:space:]]+publickey$' <<< "${sshd_runtime_cfg}" \
      || err "sshd effective auth is not key-only (expected: publickey)"
    ok "SSH auth locked to publickey only"
  else
    grep -qE '^authenticationmethods[[:space:]]+password$' <<< "${sshd_runtime_cfg}" \
      || err "sshd effective auth is not password-only (expected: password)"
    ok "SSH auth locked to password only"
  fi
  ok "PermitRootLogin=no verified via sshd -T"
}

verify_sshd_port() {
  local port="$1"
  local sshd_runtime_cfg=""

  sshd_runtime_cfg="$(get_sshd_runtime_config)"
  grep -qE "^port[[:space:]]+${port}$" <<< "${sshd_runtime_cfg}" \
    || err "Effective sshd port does not include ${port}"
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  ss_listening_on_port "${port}" || err "sshd is not listening on port ${port}"
}

verify_ssh_ipv4_only() {
  local port="$1"
  local family=""

  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  ss_listening_on_ipv6_port "${port}" \
    && err "sshd is listening on IPv6 [::]:${port} — firewall bypass risk"

  family="$(get_sshd_runtime_config | awk '/^addressfamily /{print $2; exit}')"
  if [[ -n "${family}" && "${family}" != "inet" ]]; then
    warn "sshd -T reports addressfamily '${family}' — no IPv6 listener on port ${port} (OK)"
  fi

  ok "SSH IPv4 only (port ${port}/tcp, no IPv6 listener)"
}

harden_ssh_stack() {
  if [[ "${USE_SSH_KEY_AUTH}" == "true" ]]; then
    info "Setting up sudo user with SSH key authentication..."
    prompt_sudo_username
    ensure_sudo_user
    configure_sudo_access key
    setup_ssh_authorized_key
    verify_ssh_authorized_key
  else
    info "Setting up sudo user with password-only SSH..."
    prompt_sudo_username
    ensure_sudo_user
    configure_sudo_access password
  fi

  info "Hardening SSH configuration..."
  apply_sshd_hardening
  verify_sshd_port "${SSH_PORT}"
  verify_ssh_ipv4_only "${SSH_PORT}"
  ok "SSH ready on port ${SSH_PORT}/tcp"
}

# =============================================================================
# Other services: NTP, UFW, Fail2Ban, sysctl, journald, cron
# =============================================================================

require_ubuntu() {
  local os_id=""

  command -v apt-get > /dev/null 2>&1 \
    || err "This script requires Ubuntu (apt-get not found)"

  if [[ -r /etc/os-release ]]; then
    os_id="$(awk -F= '$1 == "ID" {gsub(/^"|"$/, "", $2); print tolower($2); exit}' /etc/os-release)"
    [[ "${os_id}" == "ubuntu" ]] \
      || warn "Unrecognized distro ID '${os_id}' — proceeding since apt-get is present, but this script is tested only on Ubuntu (latest LTS)"
  fi
}

enable_time_sync() {
  timedatectl set-ntp true || err "Failed to enable NTP"
  sleep 1

  local ntp_service="" svc
  for svc in chrony chronyd systemd-timesyncd; do
    if systemctl is-active --quiet "${svc}" 2> /dev/null; then
      ntp_service=${svc}
      break
    fi
  done

  if [[ -z "${ntp_service}" ]]; then
    # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
    if unit_exists chrony.service && systemctl is-enabled chrony > /dev/null 2>&1; then
      ntp_service=chrony
    elif unit_exists chronyd.service && systemctl is-enabled chronyd > /dev/null 2>&1; then
      ntp_service=chronyd
    elif unit_exists systemd-timesyncd.service; then
      ntp_service=systemd-timesyncd
    fi
  fi

  if [[ -n "${ntp_service}" ]]; then
    systemctl enable "${ntp_service}" > /dev/null 2>&1 || true
    systemctl restart "${ntp_service}" > /dev/null 2>&1 || true
    ok "NTP daemon: ${ntp_service}"
  else
    warn "No known NTP service found; timedatectl set-ntp remains enabled"
  fi

  local ntp_synced=false _
  for _ in {1..15}; do
    # shellcheck disable=SC2312 # exit status of this substitution is intentionally unused here
    if [[ "$(timedatectl show -p NTPSynchronized --value 2> /dev/null)" == "yes" ]]; then
      ntp_synced=true
      break
    fi
    sleep 2
  done

  if [[ "${ntp_synced}" != "true" ]]; then
    warn "NTP not synchronized yet (NTPSynchronized != yes); may sync shortly"
  else
    ok "Time synchronization enabled (NTPSynchronized=yes)"
  fi
}

backup_fail2ban_config() {
  ROLLBACK_FAIL2BAN_TOUCHED=true
  if [[ -f /etc/fail2ban/jail.local ]]; then
    ROLLBACK_FAIL2BAN_HAD_FILE=true
    ROLLBACK_FAIL2BAN_BACKUP="/etc/fail2ban/jail.local.bak_${ROLLBACK_ID}"
    cp /etc/fail2ban/jail.local "${ROLLBACK_FAIL2BAN_BACKUP}"
  fi
}

readonly UFW_NUMBERED_RULE_RE='^[[:space:]]*\[[[:space:]]*([0-9]+)\][[:space:]]+([0-9]+)/tcp([[:space:]]+\(v6\))?[[:space:]]+(LIMIT|ALLOW)[[:space:]]+IN[[:space:]]+Anywhere'

# Rules this script may remove unattended: a LIMIT rule it wrote itself on an
# earlier run under a different port, and the blanket ALLOW on 22 that
# add_*_xrdp.sh leaves behind. Anything else belongs to the operator.
ufw_rule_is_ours() {
  local port="$1" action="$2" current_port="$3"

  [[ "${port}" != "${current_port}" ]] || return 1
  [[ "${action}" == "LIMIT" ]] && return 0
  [[ "${action}" == "ALLOW" && "${port}" == "22" ]] && return 0
  return 1
}

ufw_foreign_allow_ports() {
  local current_port="$1"
  local rule_line="" port="" action=""

  # shellcheck disable=SC2312 # `ufw status` failing yields no matching lines, which is the correct no-op outcome here
  while IFS= read -r rule_line; do
    [[ "${rule_line}" =~ ${UFW_NUMBERED_RULE_RE} ]] || continue
    port="${BASH_REMATCH[2]}"
    action="${BASH_REMATCH[4]}"
    [[ "${port}" != "${current_port}" ]] || continue
    # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
    ufw_rule_is_ours "${port}" "${action}" "${current_port}" && continue
    printf '%s\n' "${port}"
  done < <(ufw status numbered 2> /dev/null) | sort -un | tr '\n' ' '
}

# Enforces "only ${current_port}/tcp reachable". Rules the script did not write are
# removed only after an explicit yes — silently closing a live 80/443 is an outage.
ufw_enforce_single_open_port() {
  local current_port="$1"
  local rule_line="" rule_num="" port="" action=""
  local foreign_ports=""
  local remove_foreign=false
  local found=true

  foreign_ports="$(ufw_foreign_allow_ports "${current_port}")"
  foreign_ports="${foreign_ports% }"

  if [[ -n "${foreign_ports}" ]]; then
    warn "UFW already allows other ports from anywhere: ${foreign_ports// //tcp, }/tcp"
    warn "Keeping them leaves more than ${current_port}/tcp reachable; removing them stops that traffic now"
    prompt_yes_no remove_foreign "Remove these existing ALLOW rules too?" false
    [[ "${remove_foreign}" == "true" ]] \
      || warn "Keeping operator rules for: ${foreign_ports// //tcp, }/tcp"
  fi

  while [[ "${found}" == "true" ]]; do
    found=false
    # shellcheck disable=SC2312 # `ufw status` failing yields no matching lines, which is the correct no-op outcome here
    while IFS= read -r rule_line; do
      [[ "${rule_line}" =~ ${UFW_NUMBERED_RULE_RE} ]] || continue
      rule_num="${BASH_REMATCH[1]}"
      port="${BASH_REMATCH[2]}"
      action="${BASH_REMATCH[4]}"
      [[ "${port}" != "${current_port}" ]] || continue
      # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
      if ! ufw_rule_is_ours "${port}" "${action}" "${current_port}" && [[ "${remove_foreign}" != "true" ]]; then
        continue
      fi
      ufw --force delete "${rule_num}" > /dev/null 2>&1 || true
      warn "Removed UFW rule ${action} ${port}/tcp"
      found=true
      break
    done < <(ufw status numbered 2> /dev/null)
  done
}

backup_ufw_config() {
  local file=""

  ROLLBACK_UFW_BACKUP_DIR="/root/.ufw-backup_${ROLLBACK_ID}"
  mkdir -p "${ROLLBACK_UFW_BACKUP_DIR}"
  chmod 700 "${ROLLBACK_UFW_BACKUP_DIR}"
  for file in "${UFW_STATE_FILES[@]}"; do
    [[ -f "${file}" ]] || continue
    cp -p "${file}" "${ROLLBACK_UFW_BACKUP_DIR}/${file//\//_}"
  done
}

# Only the rollback path consumes this, so it is dead weight once the run succeeded —
# and without this every re-run would leave another copy behind in /root.
discard_ufw_backup() {
  [[ -n "${ROLLBACK_UFW_BACKUP_DIR}" && -d "${ROLLBACK_UFW_BACKUP_DIR}" ]] || return 0
  rm -rf "${ROLLBACK_UFW_BACKUP_DIR}"
  ROLLBACK_UFW_BACKUP_DIR=""
}

restore_ufw_config() {
  local file="" saved=""

  [[ -n "${ROLLBACK_UFW_BACKUP_DIR}" && -d "${ROLLBACK_UFW_BACKUP_DIR}" ]] || return 0
  for file in "${UFW_STATE_FILES[@]}"; do
    saved="${ROLLBACK_UFW_BACKUP_DIR}/${file//\//_}"
    [[ -f "${saved}" ]] && cp -p "${saved}" "${file}"
  done
  return 0
}

ufw_limit_port_once() {
  local port_rule="$1"

  if ufw status numbered 2> /dev/null | grep -qE "^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]+${port_rule}[[:space:]]+LIMIT"; then
    warn "UFW rule for ${port_rule} already exists — skipping"
    return 1
  fi

  ufw limit "${port_rule}"
}

ensure_root_only_allow() {
  local file="$1"
  if [[ -f "${file}" && "$(< "${file}")" == "root" ]]; then
    chmod 600 "${file}"
    return 0
  fi
  printf 'root\n' > "${file}"
  chmod 600 "${file}"
}

# At boot systemd-sysctl leaves conf.{all,default}.log_martians at 0; the rest of
# 98-hardening.conf sticks. Re-apply after the network is up.
install_sysctl_reapply_unit() {
  local unit="/etc/systemd/system/sysctl-hardening.service"

  cat > "${unit}" << 'EOF'
[Unit]
Description=Re-apply sysctl hardening after the network is up
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/sysctl -p /etc/sysctl.d/98-hardening.conf

[Install]
WantedBy=multi-user.target
EOF

  ROLLBACK_SYSCTL_UNIT_CREATED=true
  systemctl daemon-reload
  systemctl enable sysctl-hardening.service > /dev/null 2>&1 \
    || warn "Could not enable sysctl-hardening.service; sysctl values may not survive reboot"
  ok "sysctl re-apply unit installed (survives reboot)"
}

configure_journald_limits() {
  local dropin_dir="/etc/systemd/journald.conf.d"
  local dropin_file="${dropin_dir}/99-vps-limits.conf"

  mkdir -p "${dropin_dir}"

  if [[ -f "${dropin_file}" ]] \
    && grep -qF 'SystemMaxUse=200M' "${dropin_file}" \
    && grep -qF 'RuntimeMaxUse=100M' "${dropin_file}" \
    && grep -qF 'MaxRetentionSec=14day' "${dropin_file}"; then
    info "journald limits already configured — skipping restart"
    return 0
  fi

  cat > "${dropin_file}" << 'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=100M
MaxRetentionSec=14day
SystemMaxFileSize=20M
RuntimeMaxFileSize=10M
Compress=yes
EOF

  chmod 644 "${dropin_file}"
  systemctl restart systemd-journald
  ok "journald limits applied (SystemMaxUse=200M, RuntimeMaxUse=100M, MaxRetentionSec=14day)"
}

wait_for_dpkg_lock() {
  command -v fuser > /dev/null 2>&1 || return 0
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock > /dev/null 2>&1; do
    ((waited == 0)) && info "Waiting for apt/dpkg lock (unattended-upgrades?)..."
    ((waited >= 300)) && {
      warn "dpkg lock still held after 300s — proceeding anyway"
      return 0
    }
    sleep 5
    ((waited += 5))
  done
}

# =============================================================================
# MAIN — entry point (runs top to bottom)
# =============================================================================

main() {
  # Inside main so sourcing the file installs nothing.
  trap rollback_on_failure EXIT
  ROLLBACK_ID="$(date +%Y%m%d_%H%M%S)"

  if [[ ${EUID} -ne 0 ]]; then
    err "This script must be run as root. On a fresh VPS: bash $0"
  fi

  require_ubuntu

  parse_cli_args "$@"
  verify_ssh_port_available "${SSH_PORT}"

  export DEBIAN_FRONTEND=noninteractive
  export APT_LISTCHANGES_FRONTEND=none
  export NEEDRESTART_MODE=a

  sep
  info "Server hardening script started"
  info "SSH port target: ${SSH_PORT}/tcp (both modes; UFW opens this port only)"
  [[ -n "${SSH_USER:-}" ]] && info "Preset username: ${SSH_USER}"
  [[ -n "${CLI_PRESET_PASSWORD}" ]] && info "Preset password: provided via --password"
  sep

  # --- Step 1: system update ---
  info "Updating package lists and upgrading packages..."
  wait_for_dpkg_lock
  apt-get update || err "apt-get update failed"
  wait_for_dpkg_lock
  apt-get upgrade -y || err "apt-get upgrade failed"
  ok "System updated"

  # --- Step 2: security packages ---
  sep
  info "Installing essential security packages..."
  wait_for_dpkg_lock
  apt-get install -y --no-install-recommends \
    sudo openssh-server fail2ban ufw unattended-upgrades \
    || err "Package installation failed"
  ok "Packages installed"

  # --- Step 3: unattended-upgrades and NTP ---
  sep
  info "Configuring unattended-upgrades..."
  cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  cat > /etc/apt/apt.conf.d/51custom-unattended-upgrades << 'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  dpkg-reconfigure -f noninteractive unattended-upgrades || err "unattended-upgrades reconfigure failed"
  ok "Automatic security updates configured"

  sep
  info "Enabling time synchronization..."
  enable_time_sync

  # --- Step 4: SSH (key or password) + sudo user ---
  sep
  # Assigned via nameref in prompt_yes_no; declared so static analysis can see it.
  USE_SSH_KEY_AUTH=""
  prompt_yes_no USE_SSH_KEY_AUTH "Use SSH key-only access on port ${SSH_PORT}/tcp? (no = login+password on same port; root disabled in both modes)"
  sep

  # Armed before the first change that can cost remote access, so the window covers
  # sshd, ssh.socket and UFW alike.
  if ((CONFIRM_WINDOW_MIN > 0)); then
    install_lockout_autorevert "${CONFIRM_WINDOW_MIN}"
    sep
  fi

  harden_ssh_stack

  # --- Step 5: UFW ---
  sep
  info "Configuring UFW firewall..."
  if ufw status 2> /dev/null | grep -q "Status: active"; then
    ROLLBACK_UFW_WAS_ACTIVE=true
  fi

  # Flag and backup both precede the first mutation: `ufw delete` has no inverse,
  # and a failure anywhere below must still hit the UFW branch of the rollback.
  backup_ufw_config
  ROLLBACK_UFW_MODIFIED=true

  ufw default deny incoming
  ufw default allow outgoing

  ufw_enforce_single_open_port "${SSH_PORT}"

  # shellcheck disable=SC2310 # returns 1 when the rule already exists — a normal re-run, not a failure
  ufw_limit_port_once "${SSH_PORT}/tcp" || true

  ufw logging on
  ufw --force enable
  ok "UFW enabled (logging on)"

  # --- Step 6: Fail2Ban ---
  sep
  info "Configuring Fail2Ban..."
  backup_fail2ban_config

  cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
banaction = ufw

[sshd]
enabled  = true
port     = ${SSH_PORT}
backend  = systemd
maxretry = 3
EOF

  systemctl enable fail2ban
  systemctl restart fail2ban
  ok "Fail2Ban configured (sshd jail enabled on port ${SSH_PORT}/tcp)"

  # --- Step 7: sysctl hardening ---
  sep
  info "Applying kernel/network hardening..."
  rm -f /etc/sysctl.d/99-hardening.conf
  cat > /etc/sysctl.d/98-hardening.conf << 'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_fin_timeout = 15
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
EOF

  SYSCTL_LOG="/var/log/sysctl-hardening-${ROLLBACK_ID}.log"
  if sysctl --system > "${SYSCTL_LOG}" 2>&1; then
    ok "Kernel/network hardening applied"
  else
    warn "Some sysctl settings may not have applied; see ${SYSCTL_LOG}"
  fi

  install_sysctl_reapply_unit

  # --- Step 8: journald and cron/at ---
  sep
  info "Configuring journald log limits..."
  configure_journald_limits

  sep
  info "Restricting cron and at to root only..."
  ensure_root_only_allow /etc/cron.allow
  ensure_root_only_allow /etc/at.allow
  ok "cron/at restricted"

  # --- Final cleanup: default-user removal and secret hygiene ---
  # Critical hardening (SSH/UFW/Fail2Ban/sysctl/journald) has already succeeded —
  # a failure in the steps below must not roll it back via rollback_on_failure.
  SCRIPT_SUCCEEDED=true
  discard_ufw_backup

  sep
  info "Removing provider default user..."
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if ! remove_provider_default_user; then
    PROVIDER_USER_CLEANUP_FAILED=true
  fi

  clear_password_cli_history

  print_final_summary
  unset SSH_USER_PASSWORD

  if [[ "${PROVIDER_USER_CLEANUP_FAILED}" == "true" ]]; then
    err "Provider default user '${PROVIDER_DEFAULT_USER}' still exists after cleanup retries — remove manually: userdel -rf ${PROVIDER_DEFAULT_USER}"
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
