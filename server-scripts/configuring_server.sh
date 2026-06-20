#!/usr/bin/env bash
#
# configuring_server.sh — initial VPS hardening (Ubuntu/Debian)
#
# Usage:  bash configuring_server.sh [ssh_port]   # default port: 2244
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


# =============================================================================
# Constants and config paths
# =============================================================================

readonly DEFAULT_SSH_PORT=2244

readonly SSHD_MAIN="/etc/ssh/sshd_config"
readonly SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
readonly SSHD_DROPIN_FILE="${SSHD_DROPIN_DIR}/99-hardening.conf"

# Allowed SSH key types (ed25519/ecdsa; rsa disabled)
readonly SSH_KEY_TYPE='ssh-(ecdsa|ed25519)|ecdsa-[a-zA-Z0-9]+'
readonly SSH_KEY_PATTERN="^(${SSH_KEY_TYPE}) "
readonly SSH_KEY_PATTERN_FILE="(^|[[:space:],\"])(${SSH_KEY_TYPE}) "


# =============================================================================
# Rollback state (revert on failure until SCRIPT_SUCCEEDED=true)
# =============================================================================

ROLLBACK_ID="$(date +%Y%m%d_%H%M%S)"
ROLLBACK_SSHD_BACKUP=""
ROLLBACK_FAIL2BAN_BACKUP=""
ROLLBACK_FAIL2BAN_HAD_FILE=false
ROLLBACK_SUDOERS_BACKUP=""
ROLLBACK_SUDOERS_CREATED=false
SSH_SOCKET_MASKED=false
SSH_SOCKET_DISABLED=false
ROLLBACK_UFW_WAS_ACTIVE=false
ROLLBACK_UFW_MODIFIED=false
ROLLBACK_UFW_SSH_RULE_ADDED=false
ROLLBACK_UFW_SSH_PORT=""
SCRIPT_SUCCEEDED=false
SYSCTL_LOG=""


# =============================================================================
# UI: logging and final summary
# =============================================================================

info()  { echo -e "\033[35m[INFO]  $1\033[0m" >&2; }
ok()    { echo -e "\033[32m[OK]    $1\033[0m" >&2; }
warn()  { echo -e "\033[33m[WARN]  $1\033[0m" >&2; }
err()   { echo -e "\033[31m[ERROR] $1\033[0m" >&2; exit 1; }
sep()   { echo -e "\033[35m-----------------------------------------------------------------\033[0m" >&2; }

C_R='\033[0m'; C_B='\033[1m'; C_D='\033[2m'
C_G='\033[32m'; C_C='\033[36m'; C_M='\033[35m'; C_Y='\033[33m'; C_BL='\033[34m'

sum_line()  { echo -e "  ${C_G}✔${C_R}  $1"; }
sum_item()  { echo -e "  ${C_G}✔${C_R}  ${C_B}$1${C_R}${2:+ ${C_D}— $2${C_R}}"; }
sum_cmd()   { echo -e "      ${C_Y}$1${C_R}"; }
sum_note()  { echo -e "  ${C_Y}⚠${C_R}  $1"; }

print_final_summary() {
  echo ""
  echo -e "${C_M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_R}"
  echo -e "${C_B}${C_G}  ✔  SERVER HARDENING COMPLETE${C_R}"
  echo -e "${C_M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_R}"
  echo ""
  echo -e "${C_B}${C_C}  Summary${C_R}"
  echo ""

  sum_line "System updated/upgraded"

  if [[ "$USE_SSH_KEY_AUTH" == "true" ]]; then
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
  [[ "$SSH_PORT" != "22" ]] && sum_item "ssh.socket" "disabled and masked"
  sum_item "UFW" "enabled · only ${SSH_PORT}/tcp (limit) · logging on"
  sum_item "Fail2Ban" "sshd jail enabled"
  sum_line "Unattended upgrades enabled"
  sum_line "NTP time synchronization enabled"
  sum_line "Sysctl hardening (/etc/sysctl.d/98-hardening.conf)"
  sum_line "Journald log limits (SystemMaxUse=200M, MaxRetentionSec=14day)"

  echo ""
  echo -e "${C_B}${C_BL}  Next steps${C_R}"
  echo ""
  sum_note "DO NOT CLOSE THIS SESSION YET — test in a new terminal:"
  sum_cmd "ssh -p ${SSH_PORT} ${SSH_USER}@<your-server-ip>"
  sum_cmd "sudo -i"
  echo ""
  echo -e "${C_M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_R}"
}


# =============================================================================
# Interactive input (TTY)
# =============================================================================

read_tty() {
  if [[ ! -r /dev/tty ]]; then
    err "Interactive input requires a TTY. Download first: curl -fsSL URL -o /tmp/setup.sh && bash /tmp/setup.sh"
  fi
  IFS= read -r "$1" < /dev/tty
}

sanitize_username_input() {
  local raw="$1"
  raw="${raw//$'\r'/}"
  raw="${raw//$'\n'/}"
  raw="${raw//$'\ufeff'/}"
  printf '%s' "$raw" | LC_ALL=C tr -cd '[:alnum:]_-' | tr '[:upper:]' '[:lower:]'
}

prompt_yes_no() {
  local -n _result=$1
  local prompt=$2
  local default_yes=${3:-true}
  local max_attempts=5
  local attempt=1
  local input=""

  while (( attempt <= max_attempts )); do
    echo ""
    info "$prompt"
    if [[ "$default_yes" == "true" ]]; then
      info "[Y/n] (default: yes — Enter or Space)"
    else
      info "[y/N] (default: no — Enter or Space)"
    fi
    read_tty input
    input="$(echo "$input" | tr -d '[:space:]')"

    if [[ -z "$input" ]]; then
      _result=$([[ "$default_yes" == "true" ]] && echo true || echo false)
      return 0
    fi

    case "${input,,}" in
      y|yes|д|да) _result=true; return 0 ;;
      n|no|нет)   _result=false; return 0 ;;
    esac

    warn "Enter y/yes or n/no (try again $attempt/$max_attempts)"
    (( attempt++ )) || true
  done

  err "Too many invalid answers"
}

prompt_sudo_username() {
  local max_attempts=5
  local attempt=1
  local raw=""

  while (( attempt <= max_attempts )); do
    echo ""
    if (( attempt == 1 )); then
      info "Enter sudo username [admin]:"
    else
      warn "Invalid username. Use a-z, 0-9, _, - (try again $attempt/$max_attempts):"
    fi
    read_tty raw
    raw="$(sanitize_username_input "$raw")"
    SSH_USER="${raw:-admin}"

    if [[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      return 0
    fi
    (( attempt++ )) || true
  done

  err "Invalid username after $max_attempts attempts"
}

passwd_tty() {
  if [[ ! -r /dev/tty ]]; then
    err "Password input requires a TTY. Download first: curl -fsSL URL -o /tmp/setup.sh && bash /tmp/setup.sh"
  fi
  passwd "$1" < /dev/tty > /dev/tty 2>&1
}

prompt_set_password() {
  local user="$1"
  local max_attempts=5
  local attempt=1

  while (( attempt <= max_attempts )); do
    echo ""
    if (( attempt == 1 )); then
      info "Set password for $user:"
    else
      warn "Passwords did not match or could not be set. Try again ($attempt/$max_attempts):"
    fi
    if passwd_tty "$user"; then
      ok "Password set for $user"
      return 0
    fi
    (( attempt++ )) || true
  done
  err "Failed to set password for $user after $max_attempts attempts"
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
  if [[ "$raw" =~ ^(ssh-[^[:space:]]+|ecdsa-sha2-nistp[0-9]+)[[:space:]]+([^[:space:]]+)(.*)$ ]]; then
    raw="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
  fi
  printf '%s' "$raw"
}

looks_like_file_path() {
  local s="$1"
  [[ "$s" == "~" || "$s" == "~/"* || "$s" == "/"* || "$s" == "."* ]]
}

sshkey_file_valid() {
  ssh-keygen -l -f "$1" >/dev/null 2>&1
}

validate_ssh_pubkey() {
  local key="$1"
  local key_type="" tmp=""

  key="$(sanitize_ssh_pubkey_line "$key")"
  [[ -n "$key" ]] || err "Empty SSH public key"

  if [[ "$key" == -----BEGIN* ]]; then
    err "This is a PRIVATE key. Use the PUBLIC key (ssh-ed25519 AAAA...) or a .pub file path"
  fi
  if looks_like_file_path "$key"; then
    err "File not found: $key — paste the full key line from: cat ~/.ssh/id_ed25519.pub"
  fi

  key_type="${key%% *}"
  case "$key_type" in
    ssh-ed25519|ssh-ecdsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;;
    ssh-rsa) err "ssh-rsa is not supported. Generate a new key: ssh-keygen -t ed25519" ;;
    *) err "Unsupported key type '${key_type}'. Use ed25519 or ecdsa (paste: cat ~/.ssh/id_ed25519.pub)" ;;
  esac

  tmp="$(mktemp)"
  printf '%s\n' "$key" > "$tmp"
  if ! sshkey_file_valid "$tmp"; then
    rm -f "$tmp"
    err "Invalid SSH public key. Paste the FULL line from: cat ~/.ssh/id_ed25519.pub"
  fi
  rm -f "$tmp"
  ok "SSH public key valid (${key_type})"
}

expand_sshkey_path() {
  case "$1" in
    "~")   printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "${HOME}/${1#~/}" ;;
    *)     printf '%s' "$1" ;;
  esac
}

load_ssh_pubkey() {
  local input="$1"
  local path="" key="" tmp=""

  input="$(sanitize_ssh_pubkey_line "$input")"
  [[ -n "$input" ]] || err "Empty input — paste the public key or a .pub file path"

  if [[ "$input" =~ ^cat[[:space:]] ]]; then
    err "You pasted the shell command, not the key. On your LAPTOP run that command, then paste the line that starts with ssh-ed25519"
  fi

  tmp="$(mktemp)"
  printf '%s\n' "$input" > "$tmp"
  if sshkey_file_valid "$tmp"; then
    rm -f "$tmp"
    info "Public key entered manually"
    printf '%s' "$input"
    return 0
  fi
  rm -f "$tmp"

  path="$(expand_sshkey_path "$input")"

  if [[ ! -f "$path" && "$path" != *.pub && -f "${path}.pub" ]]; then
    warn "Private key path given — using ${path}.pub instead"
    path="${path}.pub"
  fi

  if [[ -f "$path" ]]; then
    if grep -qE '^-----BEGIN (OPENSSH |EC )?PRIVATE KEY-----' "$path" 2>/dev/null; then
      err "File is a PRIVATE key: $path — use the .pub file or paste the public key line"
    fi
    key="$(sanitize_ssh_pubkey_line "$(tr -d '\r\n' < "$path")")"
    tmp="$(mktemp)"
    printf '%s\n' "$key" > "$tmp"
    if ! sshkey_file_valid "$tmp"; then
      rm -f "$tmp"
      err "File is not a valid public key: $path"
    fi
    rm -f "$tmp"
    info "Public key loaded from file: $path"
    printf '%s' "$key"
    return 0
  fi

  if looks_like_file_path "$input"; then
    err "Public key file not found on this server: $input — paste the key line (ssh-ed25519 AAAA...), not a laptop path"
  fi

  err "Invalid SSH public key. Paste the line starting with ssh-ed25519 (run on laptop: cat ~/.ssh/id_ed25519.pub, copy the output)"
}


# =============================================================================
# Network and systemd: ports, sshd, units
# =============================================================================

unit_exists() { systemctl cat "$1" >/dev/null 2>&1; }

ss_listening_on_port() {
  local port="$1"
  ss -tln 2>/dev/null | awk -v port="$port" '
    $1 == "LISTEN" {
      split($4, a, ":")
      if (a[length(a)] == port) found = 1
    }
    END { exit !found }
  '
}

ss_listening_on_ipv6_port() {
  local port="$1"
  ss -tln 2>/dev/null | awk -v port="$port" '
    $1 == "LISTEN" && $4 ~ ("^\\[::\\]:" port "$") { found = 1 }
    END { exit !found }
  '
}

port_in_use() {
  ss_listening_on_port "$1"
}

get_sshd_runtime_config() {
  sshd -T 2>/dev/null || true
}

verify_ssh_port_available() {
  local port="$1"

  if ! port_in_use "$port"; then
    ok "Port ${port}/tcp is available"
    return 0
  fi

  if ss -tlnp 2>/dev/null | grep -E ":${port}\\b" | grep -qiE 'sshd|ssh'; then
    warn "Port ${port}/tcp already used by SSH — assuming re-run"
    return 0
  fi

  err "Port ${port}/tcp is already in use. Specify a free port: bash $0 <port>"
}

restart_sshd_service() {
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
  if ! unit_exists ssh.socket; then
    return 0
  fi

  if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
    warn "ssh.socket is active/enabled; disabling it to honor Port from sshd_config"
    systemctl disable --now ssh.socket || err "Failed to disable ssh.socket"
    SSH_SOCKET_DISABLED=true
  fi

  if systemctl mask ssh.socket >/dev/null 2>&1; then
    SSH_SOCKET_MASKED=true
  fi
}


# =============================================================================
# Rollback: revert critical changes on failure
# =============================================================================

rollback_on_failure() {
  local exit_code=$?
  [[ "$SCRIPT_SUCCEEDED" == "true" ]] && return 0

  sep
  warn "Script failed (exit $exit_code). Rolling back critical changes..."

  if [[ -f "$SSHD_DROPIN_FILE" ]]; then
    rm -f "$SSHD_DROPIN_FILE"
    warn "Removed $SSHD_DROPIN_FILE"
  fi

  if [[ -n "$ROLLBACK_SSHD_BACKUP" && -f "$ROLLBACK_SSHD_BACKUP" ]]; then
    cp "$ROLLBACK_SSHD_BACKUP" "$SSHD_MAIN"
    warn "Restored $SSHD_MAIN from backup"
    if sshd -t >/dev/null 2>&1; then
      if unit_exists ssh.service; then
        systemctl restart ssh.service >/dev/null 2>&1 || true
      elif unit_exists sshd.service; then
        systemctl restart sshd.service >/dev/null 2>&1 || true
      fi
    fi
  fi

  if [[ "$SSH_SOCKET_MASKED" == "true" || "$SSH_SOCKET_DISABLED" == "true" ]]; then
    systemctl unmask ssh.socket >/dev/null 2>&1 || true
    if [[ "$SSH_SOCKET_DISABLED" == "true" ]]; then
      systemctl enable ssh.socket >/dev/null 2>&1 || true
      warn "Re-enabled ssh.socket"
    else
      warn "Unmasked ssh.socket"
    fi
  fi

  if [[ -n "$ROLLBACK_FAIL2BAN_BACKUP" && -f "$ROLLBACK_FAIL2BAN_BACKUP" ]]; then
    cp "$ROLLBACK_FAIL2BAN_BACKUP" /etc/fail2ban/jail.local
    systemctl restart fail2ban >/dev/null 2>&1 || true
    warn "Restored /etc/fail2ban/jail.local from backup"
  elif [[ "$ROLLBACK_FAIL2BAN_HAD_FILE" == "false" && -f /etc/fail2ban/jail.local ]]; then
    rm -f /etc/fail2ban/jail.local
    systemctl restart fail2ban >/dev/null 2>&1 || true
    warn "Removed newly created /etc/fail2ban/jail.local"
  fi

  local sudoers_file="/etc/sudoers.d/${SSH_USER:-}"
  if [[ -n "$ROLLBACK_SUDOERS_BACKUP" && -f "$ROLLBACK_SUDOERS_BACKUP" ]]; then
    cp "$ROLLBACK_SUDOERS_BACKUP" "$sudoers_file"
    warn "Restored $sudoers_file from backup"
  elif [[ "$ROLLBACK_SUDOERS_CREATED" == "true" && -f "$sudoers_file" ]]; then
    rm -f "$sudoers_file"
    warn "Removed $sudoers_file"
  fi

  if [[ "$ROLLBACK_UFW_MODIFIED" == "true" ]]; then
    if [[ "$ROLLBACK_UFW_SSH_RULE_ADDED" == "true" && -n "$ROLLBACK_UFW_SSH_PORT" ]]; then
      ufw delete limit "${ROLLBACK_UFW_SSH_PORT}/tcp" >/dev/null 2>&1 || true
      warn "Removed UFW limit rule for port ${ROLLBACK_UFW_SSH_PORT}/tcp"
    fi
    if [[ "$ROLLBACK_UFW_WAS_ACTIVE" != "true" ]]; then
      ufw --force disable >/dev/null 2>&1 || true
      warn "UFW disabled (was inactive before script)"
    fi
  fi

  exit "$exit_code"
}

trap rollback_on_failure EXIT


# =============================================================================
# Sudo user: creation, password, authorized_keys
# =============================================================================

ensure_sudo_user() {
  if id "$SSH_USER" &>/dev/null; then
    warn "User $SSH_USER already exists"
  else
    useradd -m -s /bin/bash "$SSH_USER"
    ok "User $SSH_USER created"
  fi

  if getent group sudo >/dev/null; then
    usermod -aG sudo "$SSH_USER"
    ok "User $SSH_USER added to sudo group"
  elif getent group wheel >/dev/null; then
    usermod -aG wheel "$SSH_USER"
    ok "User $SSH_USER added to wheel group"
  else
    err "Neither sudo nor wheel group found"
  fi

  SSH_USER_HOME="$(getent passwd "$SSH_USER" | cut -d: -f6)"
  [[ -n "$SSH_USER_HOME" && -d "$SSH_USER_HOME" ]] || err "Home directory not found for $SSH_USER"
}

configure_sudo_access() {
  local sudoers_file="/etc/sudoers.d/$SSH_USER"

  if [[ "${1:-}" == "password" ]]; then
    # Password-only SSH: remove NOPASSWD from previous runs
    if [[ -f "$sudoers_file" ]]; then
      ROLLBACK_SUDOERS_BACKUP="${sudoers_file}.bak_${ROLLBACK_ID}"
      cp "$sudoers_file" "$ROLLBACK_SUDOERS_BACKUP"
      rm -f "$sudoers_file"
      ok "Removed NOPASSWD for $SSH_USER (password-only SSH mode)"
    fi
    prompt_set_password "$SSH_USER"
    ok "SSH login configured for $SSH_USER (password only)"
    return
  fi

  prompt_yes_no USE_NOPASSWD_SUDO "Enable passwordless sudo (NOPASSWD)? (less secure; default: no — sudo requires password)" false

  if [[ -f "$sudoers_file" ]]; then
    ROLLBACK_SUDOERS_BACKUP="${sudoers_file}.bak_${ROLLBACK_ID}"
    cp "$sudoers_file" "$ROLLBACK_SUDOERS_BACKUP"
  fi

  if [[ "$USE_NOPASSWD_SUDO" == "true" ]]; then
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
    chmod 440 "$sudoers_file"
    ROLLBACK_SUDOERS_CREATED=true
    visudo -cf "$sudoers_file" || err "Invalid sudoers entry for $SSH_USER"
    ok "Passwordless sudo configured for $SSH_USER (NOPASSWD)"
  else
    rm -f "$sudoers_file"
    ROLLBACK_SUDOERS_CREATED=false
    info "NOPASSWD disabled — $SSH_USER will need password for sudo"
    prompt_set_password "$SSH_USER"
    ok "Sudo configured for $SSH_USER (password required — NOPASSWD disabled)"
  fi
}

remove_legacy_rsa_keys() {
  local ak="${SSH_USER_HOME}/.ssh/authorized_keys"

  if [[ -f "$ak" ]] && grep -qE '(^|[[:space:]]*)ssh-rsa ' "$ak"; then
    warn "Removing legacy ssh-rsa keys from $ak (rsa is disabled)"
    grep -vE '(^|[[:space:]]*)ssh-rsa ' "$ak" > "${ak}.tmp"
    mv "${ak}.tmp" "$ak"
    chmod 600 "$ak"
    chown "$SSH_USER:$SSH_USER" "$ak"
  fi
}

setup_ssh_authorized_key() {
  local ak="${SSH_USER_HOME}/.ssh/authorized_keys"

  mkdir -p "${SSH_USER_HOME}/.ssh"
  chmod 700 "${SSH_USER_HOME}/.ssh"
  chown "$SSH_USER:$SSH_USER" "${SSH_USER_HOME}/.ssh"

  echo ""
  info "Paste your SSH PUBLIC KEY (one line starting with ssh-ed25519 AAAA...):"
  warn "Run on your LAPTOP first: cat ~/.ssh/id_ed25519.pub"
  warn "Then paste the OUTPUT here — do NOT paste the cat command itself"
  read_tty sshkey_input

  sshkey="$(load_ssh_pubkey "$sshkey_input")"
  validate_ssh_pubkey "$sshkey"

  touch "$ak"
  if grep -qF "$sshkey" "$ak"; then
    warn "Key already exists in $ak"
  else
    echo "$sshkey" >> "$ak"
    ok "SSH key added for $SSH_USER"
  fi

  chmod 600 "$ak"
  chown "$SSH_USER:$SSH_USER" "$ak"
  remove_legacy_rsa_keys
}

verify_ssh_authorized_key() {
  local ak="${SSH_USER_HOME}/.ssh/authorized_keys"

  info "Verifying SSH key for $SSH_USER before disabling root login..."
  [[ -f "$ak" ]] || err "authorized_keys missing for $SSH_USER"
  [[ -s "$ak" ]] || err "authorized_keys is empty for $SSH_USER"
  grep -qE "$SSH_KEY_PATTERN_FILE" "$ak" || err "No valid public key in $ak (ed25519/ecdsa required)"
  [[ "$(stat -c '%a' "${SSH_USER_HOME}/.ssh")" == "700" ]] \
    || err ".ssh permissions incorrect for $SSH_USER"
  [[ "$(stat -c '%a' "$ak")" == "600" ]] \
    || err "authorized_keys permissions incorrect for $SSH_USER"
  [[ "$(stat -c '%U:%G' "${SSH_USER_HOME}/.ssh")" == "${SSH_USER}:${SSH_USER}" ]] \
    || err ".ssh ownership incorrect for $SSH_USER"
  [[ "$(stat -c '%U:%G' "$ak")" == "${SSH_USER}:${SSH_USER}" ]] \
    || err "authorized_keys ownership incorrect for $SSH_USER"
  ok "SSH key verified for $SSH_USER (safe to disable root login)"
}


# =============================================================================
# SSH hardening: drop-in config, verification, orchestrator
# =============================================================================

backup_sshd_config() {
  ROLLBACK_SSHD_BACKUP="${SSHD_MAIN}.bak_${ROLLBACK_ID}"
  cp "$SSHD_MAIN" "$ROLLBACK_SSHD_BACKUP"
  mkdir -p "$SSHD_DROPIN_DIR"
}

apply_sshd_hardening() {
  local -a auth_lines=()
  backup_sshd_config

  if [[ "$USE_SSH_KEY_AUTH" == "true" ]]; then
    auth_lines=(
      "AuthenticationMethods publickey"
      "PubkeyAuthentication yes"
      "PubkeyAcceptedAlgorithms -ssh-rsa"
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
    cat <<EOF
Port $SSH_PORT
AddressFamily inet
ListenAddress 0.0.0.0
PermitRootLogin no
AllowUsers $SSH_USER
EOF
    printf '%s\n' "${auth_lines[@]}"
    cat <<'EOF'
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
  } > "$SSHD_DROPIN_FILE"

  [[ "$SSH_PORT" != "22" ]] && handle_ssh_socket

  info "Validating sshd config..."
  sshd -t || err "sshd config validation failed"
  restart_sshd_service
  sleep 1

  local sshd_runtime_cfg=""
  sshd_runtime_cfg="$(get_sshd_runtime_config)"

  if [[ "$USE_SSH_KEY_AUTH" == "true" ]]; then
    grep -qE '^authenticationmethods[[:space:]]+publickey$' <<< "$sshd_runtime_cfg" \
      || err "sshd effective auth is not key-only (expected: publickey)"
    ok "SSH auth locked to publickey only"
  else
    grep -qE '^authenticationmethods[[:space:]]+password$' <<< "$sshd_runtime_cfg" \
      || err "sshd effective auth is not password-only (expected: password)"
    ok "SSH auth locked to password only"
  fi
}

verify_sshd_port() {
  local port="$1"
  local sshd_runtime_cfg=""

  sshd_runtime_cfg="$(get_sshd_runtime_config)"
  grep -qE "^port[[:space:]]+${port}$" <<< "$sshd_runtime_cfg" \
    || err "Effective sshd port does not include $port"
  ss_listening_on_port "$port" || err "sshd is not listening on port $port"
}

verify_ssh_ipv4_only() {
  local port="$1"
  local family=""

  ss_listening_on_ipv6_port "$port" \
    && err "sshd is listening on IPv6 [::]:${port} — firewall bypass risk"

  family="$(get_sshd_runtime_config | awk '/^addressfamily /{print $2; exit}')"
  if [[ -n "$family" && "$family" != "inet" ]]; then
    warn "sshd -T reports addressfamily '${family}' — no IPv6 listener on port ${port} (OK)"
  fi

  ok "SSH IPv4 only (port ${port}/tcp, no IPv6 listener)"
}

harden_ssh_stack() {
  if [[ "$USE_SSH_KEY_AUTH" == "true" ]]; then
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
  verify_sshd_port "$SSH_PORT"
  verify_ssh_ipv4_only "$SSH_PORT"
  ok "SSH ready on port ${SSH_PORT}/tcp"
}


# =============================================================================
# Other services: NTP, UFW, Fail2Ban, sysctl, journald, cron
# =============================================================================

enable_time_sync() {
  timedatectl set-ntp true || err "Failed to enable NTP"
  sleep 1

  local ntp_service=""
  for svc in chrony chronyd systemd-timesyncd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      ntp_service=$svc
      break
    fi
  done

  if [[ -z "$ntp_service" ]]; then
    if unit_exists chrony.service && systemctl is-enabled chrony >/dev/null 2>&1; then
      ntp_service=chrony
    elif unit_exists chronyd.service && systemctl is-enabled chronyd >/dev/null 2>&1; then
      ntp_service=chronyd
    elif unit_exists systemd-timesyncd.service; then
      ntp_service=systemd-timesyncd
    fi
  fi

  if [[ -n "$ntp_service" ]]; then
    systemctl enable "$ntp_service" >/dev/null 2>&1 || true
    systemctl restart "$ntp_service" >/dev/null 2>&1 || true
    ok "NTP daemon: $ntp_service"
  else
    warn "No known NTP service found; timedatectl set-ntp remains enabled"
  fi

  local ntp_synced=false
  for _ in $(seq 1 15); do
    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
      ntp_synced=true
      break
    fi
    sleep 2
  done

  if [[ "$ntp_synced" != "true" ]]; then
    warn "NTP not synchronized yet (NTPSynchronized != yes); may sync shortly"
  else
    ok "Time synchronization enabled (NTPSynchronized=yes)"
  fi
}

backup_fail2ban_config() {
  if [[ -f /etc/fail2ban/jail.local ]]; then
    ROLLBACK_FAIL2BAN_HAD_FILE=true
    ROLLBACK_FAIL2BAN_BACKUP="/etc/fail2ban/jail.local.bak_${ROLLBACK_ID}"
    cp /etc/fail2ban/jail.local "$ROLLBACK_FAIL2BAN_BACKUP"
  fi
}

ufw_limit_port_once() {
  local port_rule="$1"

  if ufw status 2>/dev/null | grep -qF "${port_rule}"; then
    warn "UFW rule for ${port_rule} already exists — skipping"
    return 1
  fi

  ufw limit "${port_rule}"
}

ensure_root_only_allow() {
  local file="$1"
  [[ -f "$file" && "$(cat "$file")" == "root" ]] && return 0
  echo "root" > "$file"
  chmod 600 "$file"
}

configure_journald_limits() {
  local dropin_dir="/etc/systemd/journald.conf.d"
  local dropin_file="${dropin_dir}/99-vps-limits.conf"

  mkdir -p "$dropin_dir"

  if [[ -f "$dropin_file" ]] \
    && grep -qF 'SystemMaxUse=200M' "$dropin_file" \
    && grep -qF 'RuntimeMaxUse=100M' "$dropin_file" \
    && grep -qF 'MaxRetentionSec=14day' "$dropin_file"; then
    warn "journald limits already configured — skipping restart"
    return 0
  fi

  cat > "$dropin_file" << 'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=100M
MaxRetentionSec=14day
SystemMaxFileSize=20M
RuntimeMaxFileSize=10M
Compress=yes
EOF

  chmod 644 "$dropin_file"
  systemctl restart systemd-journald
  ok "journald limits applied (SystemMaxUse=200M, RuntimeMaxUse=100M, MaxRetentionSec=14day)"
}


# =============================================================================
# MAIN — entry point (runs top to bottom)
# =============================================================================

if [[ $EUID -ne 0 ]]; then
  err "This script must be run as root. On a fresh VPS: bash $0"
fi

SSH_PORT="${1:-$DEFAULT_SSH_PORT}"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  err "Invalid SSH port: $SSH_PORT"
fi

verify_ssh_port_available "$SSH_PORT"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a

sep
info "Server hardening script started"
info "SSH port target: ${SSH_PORT}/tcp (both modes; UFW opens this port only)"
sep

# --- Step 1: system update ---
info "Updating package lists and upgrading packages..."
apt-get update || err "apt-get update failed"
apt-get upgrade -y || err "apt-get upgrade failed"
ok "System updated"

# --- Step 2: security packages ---
sep
info "Installing essential security packages..."
apt-get install -y --no-install-recommends \
  sudo openssh-server fail2ban ufw unattended-upgrades \
  || err "Package installation failed"
ok "Packages installed"

# --- Step 3: unattended-upgrades and NTP ---
sep
info "Configuring unattended-upgrades..."
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
prompt_yes_no USE_SSH_KEY_AUTH "Use SSH key-only access on port ${SSH_PORT}/tcp? (no = login+password on same port; root disabled in both modes)"
sep
harden_ssh_stack

# --- Step 5: UFW ---
sep
info "Configuring UFW firewall..."
if ufw status 2>/dev/null | grep -q "Status: active"; then
  ROLLBACK_UFW_WAS_ACTIVE=true
fi

ufw default deny incoming
ufw default allow outgoing

if ufw_limit_port_once "${SSH_PORT}/tcp"; then
  ROLLBACK_UFW_SSH_RULE_ADDED=true
  ROLLBACK_UFW_SSH_PORT="$SSH_PORT"
fi

ufw logging on
ufw --force enable
ROLLBACK_UFW_MODIFIED=true
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
port     = $SSH_PORT
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
if sysctl --system > "$SYSCTL_LOG" 2>&1; then
  ok "Kernel/network hardening applied"
else
  warn "Some sysctl settings may not have applied; see $SYSCTL_LOG"
fi

# --- Step 8: journald and cron/at ---
sep
info "Configuring journald log limits..."
configure_journald_limits

sep
info "Restricting cron and at to root only..."
ensure_root_only_allow /etc/cron.allow
ensure_root_only_allow /etc/at.allow
ok "cron/at restricted"

SCRIPT_SUCCEEDED=true
print_final_summary
