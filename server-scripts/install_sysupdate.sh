#!/usr/bin/env bash
#
# install_sysupdate.sh — install sysupdate wrapper to /usr/local/bin
#
# Usage:  bash install_sysupdate.sh
# Requires: curl; root or sudo
#
set -euo pipefail


# =============================================================================
# Constants
# =============================================================================

readonly BASE_URL="https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts"
readonly BIN_DIR="/usr/local/bin"


# =============================================================================
# UI helpers
# =============================================================================

info()  { echo -e "\033[35m[INFO]  $1\033[0m" >&2; }
ok()    { echo -e "\033[32m[OK]    $1\033[0m" >&2; }
err()   { echo -e "\033[31m[ERROR] $1\033[0m" >&2; exit 1; }


# =============================================================================
# MAIN
# =============================================================================

if ! command -v curl >/dev/null 2>&1; then
  err "curl is required"
fi

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    err "sudo is required when running as non-root user"
  fi
  SUDO="sudo"
fi

info "Installing sysupdate to ${BIN_DIR}..."
$SUDO curl -fsSL "${BASE_URL}/update_system_all.sh" -o "${BIN_DIR}/sysupdate"
$SUDO chmod +x "${BIN_DIR}/sysupdate"

ok "Command installed: sysupdate"
echo "Run anytime:"
echo "  sysupdate"
