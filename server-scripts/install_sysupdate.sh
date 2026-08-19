#!/usr/bin/env bash
#
# install_sysupdate.sh — install sysupdate wrapper to /usr/local/bin
#
# Usage:  bash install_sysupdate.sh
# Requires: wget, coreutils, bash; root or sudo
#
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Constants
# =============================================================================

readonly BASE_URL="https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts"
readonly BIN_DIR="/usr/local/bin"
readonly SOURCE_URL="${BASE_URL}/update_system_all.sh"
readonly TARGET_FILE="${BIN_DIR}/sysupdate"
# Update the checksum together with update_system_all.sh.
readonly EXPECTED_SHA256="0faf5a062cc3400579dc41996ca7b329b82dfb94d7a1f47bfe3e8b6b5a4792da"

# =============================================================================
# Script state
# =============================================================================

# File scope: the EXIT trap reads these after main() has returned.
tmp_file=""
staged_file=""

# =============================================================================
# UI helpers
# =============================================================================

info() { echo -e "\033[35m[INFO]  $1\033[0m" >&2; }
ok() { echo -e "\033[32m[OK]    $1\033[0m" >&2; }
err() {
  echo -e "\033[31m[ERROR] $1\033[0m" >&2
  exit 1
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  local required_cmd="" actual_sha256=""

  for required_cmd in wget sha256sum cmp install mv mktemp bash; do
    command -v "${required_cmd}" > /dev/null 2>&1 \
      || err "Required command not found: ${required_cmd}"
  done

  SUDO=""
  # shellcheck disable=SC2312 # exit status of this substitution is intentionally unused here
  if [[ "$(id -u)" -ne 0 ]]; then
    if ! command -v sudo > /dev/null 2>&1; then
      err "sudo is required when running as non-root user"
    fi
    SUDO="sudo"
  fi

  tmp_file="$(mktemp)"
  staged_file="${BIN_DIR}/.sysupdate.new.$$"
  cleanup() {
    rm -f "${tmp_file}"
    if [[ -e "${staged_file}" ]]; then
      ${SUDO} rm -f "${staged_file}" 2> /dev/null || true
    fi
  }
  trap cleanup EXIT

  info "Installing sysupdate to ${BIN_DIR}..."
  wget -qO "${tmp_file}" "${SOURCE_URL}"

  [[ "${EXPECTED_SHA256}" =~ ^[[:xdigit:]]{64}$ ]] || err "Invalid EXPECTED_SHA256 format in install_sysupdate.sh itself"

  actual_sha256="$(sha256sum "${tmp_file}")"
  actual_sha256="${actual_sha256%% *}"
  [[ "${actual_sha256}" == "${EXPECTED_SHA256}" ]] \
    || err "SHA256 mismatch for the downloaded update_system_all.sh"

  bash -n "${tmp_file}" || err "Downloaded update_system_all.sh failed bash -n"

  if [[ -f "${TARGET_FILE}" ]] && cmp -s "${tmp_file}" "${TARGET_FILE}"; then
    ok "sysupdate is already up to date"
    exit 0
  fi

  ${SUDO} install -m 755 -o root -g root "${tmp_file}" "${staged_file}"
  ${SUDO} mv -f "${staged_file}" "${TARGET_FILE}"

  ok "Command installed: sysupdate"
  echo "Run anytime:"
  echo "  sysupdate"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
