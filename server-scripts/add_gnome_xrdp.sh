#!/usr/bin/env bash
#
# add_gnome_xrdp.sh — install GNOME desktop and xrdp remote desktop
#
# Usage:  bash add_gnome_xrdp.sh
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
  local ssh_port=""

  if command -v sshd >/dev/null 2>&1; then
    ssh_port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
  fi
  ssh_port="${ssh_port:-22}"

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

configure_gnome_session() {
  local user_home="${NEW_USER_HOME:-$(getent passwd "$NEW_USER" | cut -d: -f6)}"

  printf '%s\n' 'gnome-session' | $SUDO tee "${user_home}/.xsession" > /dev/null
  $SUDO tee "${user_home}/.xsessionrc" > /dev/null <<'EOF'
export XAUTHORITY=${HOME}/.Xauthority
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CONFIG_DIRS=/etc/xdg/xdg-ubuntu:/etc/xdg
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
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

# --- Step 1: system update ---
info "Updating system packages..."
$SUDO apt-get update
$SUDO apt-get upgrade -y
ok "System updated"

# --- Step 2: desktop and xrdp ---
info "Installing GNOME desktop and xrdp..."
$SUDO apt-get install -y ubuntu-gnome-desktop xrdp
ok "GNOME and xrdp installed"

# --- Step 3: xrdp service ---
info "Configuring xrdp service..."
$SUDO adduser xrdp ssl-cert
$SUDO systemctl enable xrdp
$SUDO systemctl start xrdp
ok "xrdp service enabled and started"

# --- Step 4: sudo user ---
prompt_new_user
info "Configuring user $NEW_USER..."
ensure_sudo_user
configure_gnome_session
ok "User $NEW_USER configured with GNOME session"

# --- Step 5: security ---
disable_root_xrdp_login
$SUDO systemctl restart xrdp
ok "Root xrdp login disabled"

# --- Step 6: firewall ---
info "Configuring UFW (RDP port ${RDP_PORT}/tcp)..."
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
$SUDO ufw --force enable
ok "UFW enabled — connect via RDP port ${RDP_PORT}"
