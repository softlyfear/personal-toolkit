#!/usr/bin/env bash
#
# service-manager.sh — systemd wrapper for allowed services
#
# Usage:  bash service-manager.sh <action> <service...|all>
#         svcctl <action> <service...|all>   (after install_svcctl.sh)
#
# Actions: start | stop | restart | enable | disable | status
# Services: postgresql | docker (or aliases pg, postgres)
#
set -euo pipefail


# =============================================================================
# Constants
# =============================================================================

readonly ALLOWED_SERVICES=("postgresql" "docker")


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

usage() {
  local cmd
  cmd="$(basename "$0")"
  cat <<EOF
Usage:
  ${cmd} <start|stop|restart|enable|disable|status> <service...|all>

Examples:
  ${cmd} start postgresql
  ${cmd} stop docker
  ${cmd} status all
EOF
}

normalize_service() {
  case "$1" in
    pg | postgres | postgresql) echo "postgresql" ;;
    docker) echo "docker" ;;
    *) echo "$1" ;;
  esac
}

is_allowed() {
  local svc="$1"
  local allowed
  for allowed in "${ALLOWED_SERVICES[@]}"; do
    [[ "$svc" == "$allowed" ]] && return 0
  done
  return 1
}


# =============================================================================
# MAIN
# =============================================================================

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

action="$1"
shift

case "$action" in
  start | stop | restart | enable | disable | status) ;;
  *) err "Invalid action: $action" ;;
esac

if ! command -v systemctl >/dev/null 2>&1; then
  err "systemctl not found"
fi

targets=()
if [[ "${1:-}" == "all" ]]; then
  targets=("${ALLOWED_SERVICES[@]}")
else
  raw=""
  for raw in "$@"; do
    svc="$(normalize_service "$raw")"
    if ! is_allowed "$svc"; then
      err "Service '$raw' not allowed. Allowed: ${ALLOWED_SERVICES[*]}"
    fi
    targets+=("$svc")
  done
fi

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  SUDO="sudo"
fi

svc=""
for svc in "${targets[@]}"; do
  info "$action $svc"
  if [[ "$action" == "status" ]]; then
    $SUDO systemctl --no-pager status "$svc" || warn "Unable to read status for $svc"
  else
    $SUDO systemctl "$action" "$svc"
    ok "$action completed for $svc"
  fi
done
