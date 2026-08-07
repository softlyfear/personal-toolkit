#!/usr/bin/env bash
#
# install_sysupdate.sh — install sysupdate wrapper to /usr/local/bin
#
# Usage:  bash install_sysupdate.sh
# Requires: wget, coreutils, bash; root or sudo
#
set -euo pipefail


# =============================================================================
# Constants
# =============================================================================

readonly BASE_URL="https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts"
readonly BIN_DIR="/usr/local/bin"
readonly SOURCE_URL="${BASE_URL}/update_system_all.sh"
readonly TARGET_FILE="${BIN_DIR}/sysupdate"
# Обновляйте checksum одновременно с update_system_all.sh.
readonly EXPECTED_SHA256="490e5915d72aeaf8443b3138b40e0dd1beddf48630f17243acb1ec6d1d050726"


# =============================================================================
# UI helpers
# =============================================================================

info()  { echo -e "\033[35m[INFO]  $1\033[0m" >&2; }
ok()    { echo -e "\033[32m[OK]    $1\033[0m" >&2; }
err()   { echo -e "\033[31m[ERROR] $1\033[0m" >&2; exit 1; }


# =============================================================================
# MAIN
# =============================================================================

for required_cmd in wget sha256sum cmp install mv mktemp bash; do
  command -v "$required_cmd" >/dev/null 2>&1 \
    || err "Не найдена обязательная команда: $required_cmd"
done

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    err "sudo is required when running as non-root user"
  fi
  SUDO="sudo"
fi

tmp_file="$(mktemp)"
staged_file="${BIN_DIR}/.sysupdate.new.$$"
cleanup() {
  rm -f "$tmp_file"
  if [[ -e "$staged_file" ]]; then
    $SUDO rm -f "$staged_file" 2>/dev/null || true
  fi
}
trap cleanup EXIT

info "Installing sysupdate to ${BIN_DIR}..."
wget -qO "$tmp_file" "$SOURCE_URL"

[[ "$EXPECTED_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || err "Некорректный формат EXPECTED_SHA256 в самом install_sysupdate.sh"

actual_sha256="$(sha256sum "$tmp_file")"
actual_sha256="${actual_sha256%% *}"
[[ "$actual_sha256" == "$EXPECTED_SHA256" ]] \
  || err "SHA256 не совпадает для загруженного update_system_all.sh"

bash -n "$tmp_file" || err "Загруженный update_system_all.sh не прошёл bash -n"

if [[ -f "$TARGET_FILE" ]] && cmp -s "$tmp_file" "$TARGET_FILE"; then
  ok "sysupdate уже обновлён"
  exit 0
fi

$SUDO install -m 755 -o root -g root "$tmp_file" "$staged_file"
$SUDO mv -f "$staged_file" "$TARGET_FILE"

ok "Command installed: sysupdate"
echo "Run anytime:"
echo "  sysupdate"
