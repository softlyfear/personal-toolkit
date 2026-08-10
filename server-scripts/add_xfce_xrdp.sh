#!/usr/bin/env bash
#
# add_xfce_xrdp.sh — install XFCE desktop and xrdp remote desktop
#
# Usage:  bash add_xfce_xrdp.sh
# Requires: Ubuntu/Debian; root or sudo; interactive TTY for username/password
#
set -euo pipefail


# =============================================================================
# Constants
# =============================================================================

readonly RDP_PORT=3389
readonly PAM_XRDP_SESMAN="/etc/pam.d/xrdp-sesman"
readonly PAM_ROOT_DENY='auth required pam_succeed_if.so user != root'


# =============================================================================
# UI helpers
# =============================================================================

info()  { echo -e "\033[35m[INFO]  $1\033[0m" >&2; }
ok()    { echo -e "\033[32m[OK]    $1\033[0m" >&2; }
warn()  { echo -e "\033[33m[WARN]  $1\033[0m" >&2; }
err()   { echo -e "\033[31m[ERROR] $1\033[0m" >&2; exit 1; }


# =============================================================================
# Helpers
# =============================================================================

setup_sudo() {
  SUDO=""
  if [[ "$(id -u)" -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      err "sudo is required when running as non-root user"
    fi
    SUDO="sudo"
  fi
}

wait_for_dpkg_lock() {
  command -v fuser >/dev/null 2>&1 || return 0
  local waited=0
  while $SUDO fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; do
    (( waited == 0 )) && info "Waiting for apt/dpkg lock (unattended-upgrades?)..."
    (( waited >= 300 )) && { warn "dpkg lock still held after 300s — proceeding anyway"; return 0; }
    sleep 5
    (( waited += 5 ))
  done
}

require_apt_based_distro() {
  local os_id=""

  command -v apt-get >/dev/null 2>&1 || err "This script supports only Ubuntu/Debian (apt-get required)"

  if [[ -r /etc/os-release ]]; then
    os_id="$(awk -F= '$1 == "ID" {gsub(/^"|"$/, "", $2); print tolower($2); exit}' /etc/os-release)"
    case "$os_id" in
      ubuntu | debian) ;;
      *) warn "Unrecognized distro ID '$os_id' — proceeding since apt-get is present, but this script is tested only on Ubuntu/Debian" ;;
    esac
  fi
}

prompt_new_user() {
  local max_attempts=5
  local attempt=1
  local raw=""

  while (( attempt <= max_attempts )); do
    echo ""
    if (( attempt == 1 )); then
      info "Enter new sudo username:"
    else
      warn "Invalid username. Use a-z, 0-9, _, - (try again $attempt/$max_attempts):"
    fi
    read -r raw < /dev/tty
    raw="$(printf '%s' "$raw" | LC_ALL=C tr -cd '[:alnum:]_-' | tr '[:upper:]' '[:lower:]')"
    NEW_USER="${raw:-admin}"

    if [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      return 0
    fi
    (( attempt++ )) || true
  done

  err "Invalid username after $max_attempts attempts"
}

ensure_ssh_ufw_rule() {
  local ssh_port="${SSH_PORT:-}"
  local sshd_bin=""
  local -a connection=()

  if [[ -z "$ssh_port" && -n "${SSH_CONNECTION:-}" ]]; then
    read -r -a connection <<< "$SSH_CONNECTION"
    ssh_port="${connection[3]:-}"
  fi

  if [[ -z "$ssh_port" ]]; then
    if command -v sshd >/dev/null 2>&1; then
      sshd_bin="$(command -v sshd)"
    elif [[ -x /usr/sbin/sshd ]]; then
      sshd_bin="/usr/sbin/sshd"
    fi
    if [[ -n "$sshd_bin" ]]; then
      ssh_port="$( { $SUDO "$sshd_bin" -T 2>/dev/null || true; } | awk '/^port /{print $2; exit}')"
    fi
  fi

  [[ "$ssh_port" =~ ^[0-9]+$ ]] && (( ssh_port >= 1 && ssh_port <= 65535 )) \
    || err "Could not safely determine the SSH port; set it via SSH_PORT"

  if ! $SUDO ufw status numbered 2>/dev/null | grep -qE "^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]+${ssh_port}/tcp"; then
    $SUDO ufw allow "${ssh_port}/tcp"
    ok "UFW rule added for SSH port ${ssh_port}/tcp"
  else
    info "UFW rule for SSH port ${ssh_port}/tcp already exists"
  fi
}

ensure_sudo_user() {
  local user_home=""

  if id "$NEW_USER" &>/dev/null; then
    warn "User $NEW_USER already exists — skipping creation"
  else
    $SUDO adduser --gecos "" --disabled-password "$NEW_USER"
    $SUDO passwd "$NEW_USER"
    ok "User $NEW_USER created"
  fi

  $SUDO usermod -aG sudo "$NEW_USER"
  user_home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  [[ -n "$user_home" ]] || err "Home directory not found for $NEW_USER"
  NEW_USER_HOME="$user_home"
}

prompt_rdp_source_ip() {
  echo ""
  info "Optional: restrict RDP access to a single source IP (recommended)."
  info "Enter trusted IPv4 (example: 203.0.113.10) or leave empty for open access:"
  read -r RDP_SOURCE_IP < /dev/tty
}

configure_xfce_session() {
  local user_home="${NEW_USER_HOME:-$(getent passwd "$NEW_USER" | cut -d: -f6)}"

  printf '%s\n' 'startxfce4' | $SUDO tee "${user_home}/.xsession" > /dev/null
  $SUDO tee "${user_home}/.xsessionrc" > /dev/null <<'EOF'
export XAUTHORITY=${HOME}/.Xauthority
export XDG_CURRENT_DESKTOP=XFCE
EOF
  $SUDO chown "${NEW_USER}:${NEW_USER}" "${user_home}/.xsession" "${user_home}/.xsessionrc"
}

disable_root_xrdp_login() {
  if [[ -f "$PAM_XRDP_SESMAN" ]] && grep -qF "$PAM_ROOT_DENY" "$PAM_XRDP_SESMAN"; then
    warn "Root xrdp login already disabled in $PAM_XRDP_SESMAN"
    return 0
  fi
  echo "$PAM_ROOT_DENY" | $SUDO tee -a "$PAM_XRDP_SESMAN" >/dev/null
}


# =============================================================================
# MAIN
# =============================================================================

setup_sudo
require_apt_based_distro

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a

# --- Step 1: system update ---
info "Updating system packages..."
wait_for_dpkg_lock
$SUDO apt-get update
wait_for_dpkg_lock
$SUDO apt-get upgrade -y
ok "System updated"

# --- Step 2: firewall before xrdp can start ---
info "Configuring UFW (RDP port ${RDP_PORT}/tcp)..."
wait_for_dpkg_lock
$SUDO apt-get install -y ufw
ensure_ssh_ufw_rule
prompt_rdp_source_ip
if [[ -n "${RDP_SOURCE_IP:-}" ]]; then
  if [[ ! "$RDP_SOURCE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    err "Invalid IPv4 address for RDP restriction: $RDP_SOURCE_IP"
  fi
  $SUDO ufw allow from "$RDP_SOURCE_IP" to any port "${RDP_PORT}" proto tcp
  ok "UFW rule added: ${RDP_SOURCE_IP} -> ${RDP_PORT}/tcp"
else
  $SUDO ufw allow "${RDP_PORT}/tcp"
  warn "RDP is open to all sources on ${RDP_PORT}/tcp"
fi
printf '%s\n' "⚠️ RISK: a wrong SSH rule can lock out remote access. Rollback: use an active SSH session or the provider's console and run sudo ufw disable." >&2
$SUDO ufw --force enable
ok "UFW enabled before xrdp installation"

# --- Step 3: desktop and xrdp ---
info "Installing XFCE and xrdp..."
wait_for_dpkg_lock
$SUDO apt-get install -y xfce4 xfce4-goodies xrdp
$SUDO adduser xrdp ssl-cert
ok "XFCE and xrdp installed"

# --- Step 4: sudo user ---
prompt_new_user
info "Configuring user $NEW_USER..."
ensure_sudo_user
configure_xfce_session
ok "User $NEW_USER configured with XFCE session"

# --- Step 5: security ---
disable_root_xrdp_login
ok "Root xrdp login disabled"

# --- Step 6: start xrdp only after firewall and security configuration ---
$SUDO systemctl enable xrdp
printf '%s\n' "⚠️ RISK: restarting xrdp drops active RDP sessions. Rollback: connect via SSH and run sudo systemctl start xrdp." >&2
$SUDO systemctl restart xrdp
$SUDO systemctl is-active --quiet xrdp || err "xrdp failed to start"
ok "xrdp enabled and active — connect via RDP port ${RDP_PORT}"
