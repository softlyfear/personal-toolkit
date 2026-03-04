#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[35m[INFO]\033[0m $1"; }
ok() { echo -e "\033[32m[OK]\033[0m   $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
err() { echo -e "\033[31m[ERR]\033[0m  $1"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

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

info "APT: update package index"
$SUDO apt-get update -y

info "APT: full upgrade"
$SUDO apt-get full-upgrade -y

info "APT: remove unused packages"
$SUDO apt-get autoremove --purge -y

info "APT: clean package cache"
$SUDO apt-get autoclean -y

if need_cmd snap; then
  info "Snap: refreshing installed snaps"
  $SUDO snap refresh
  ok "Snap updates completed"
else
  warn "snap not found, skipping snap refresh"
fi

if need_cmd flatpak; then
  info "Flatpak: updating apps and runtimes"
  flatpak update -y
  ok "Flatpak updates completed"
else
  warn "flatpak not found, skipping flatpak update"
fi

ok "System update complete (apt + snap + flatpak)"
