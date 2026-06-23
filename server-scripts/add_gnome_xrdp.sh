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
  echo ""
  info "Enter new sudo username:"
  read -r NEW_USER < /dev/tty
  [[ -n "$NEW_USER" ]] || err "Username cannot be empty"
}

configure_gnome_session() {
  local user_home="/home/${NEW_USER}"

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
info "Creating user $NEW_USER..."
$SUDO adduser --gecos "" --disabled-password "$NEW_USER"
$SUDO passwd "$NEW_USER"
$SUDO usermod -aG sudo "$NEW_USER"
configure_gnome_session
ok "User $NEW_USER created with GNOME session"

# --- Step 5: security ---
disable_root_xrdp_login
$SUDO systemctl restart xrdp
ok "Root xrdp login disabled"

# --- Step 6: firewall ---
info "Configuring UFW (RDP port ${RDP_PORT}/tcp)..."
$SUDO apt-get install -y ufw
$SUDO ufw allow "${RDP_PORT}/tcp"
$SUDO ufw --force enable
ok "UFW enabled — connect via RDP port ${RDP_PORT}"
