#!/usr/bin/env bash
#
# update_system_all.sh — full system update (apt, snap, flatpak)
#
# Usage:  bash update_system_all.sh
#         sysupdate   (after install_sysupdate.sh)
# Requires: Ubuntu/Debian (apt-get); optional snap, flatpak
#
set -euo pipefail


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

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}


# =============================================================================
# MAIN
# =============================================================================

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  if ! need_cmd sudo; then
    err "sudo is required when running as non-root user"
  fi
  SUDO="sudo"
fi

if ! need_cmd apt-get; then
  err "This script supports Ubuntu/Debian systems (apt-get required)"
fi

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a

# --- Step 1: APT ---
info "APT: update package index"
$SUDO apt-get update

info "APT: full upgrade"
$SUDO apt-get full-upgrade -y

info "APT: remove unused packages"
$SUDO apt-get autoremove --purge -y

info "APT: clean package cache"
$SUDO apt-get autoclean
ok "APT updates completed"

# --- Step 2: Snap (optional) ---
if need_cmd snap; then
  info "Snap: refreshing installed snaps"
  $SUDO snap refresh
  ok "Snap updates completed"
else
  info "snap not found, skipping"
fi

# --- Step 3: Flatpak (optional) ---
if need_cmd flatpak; then
  info "Flatpak: updating apps and runtimes"
  flatpak update -y
  ok "Flatpak updates completed"
else
  info "flatpak not found, skipping"
fi

ok "System update complete (apt + snap + flatpak)"

# --- Reboot check ---
if [[ -f /var/run/reboot-required ]]; then
  warn "REBOOT REQUIRED — run: sudo reboot"
fi
