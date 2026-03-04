#!/usr/bin/env bash
set -euo pipefail

ALLOWED_SERVICES=("postgresql" "docker")

info() { echo -e "\033[35m[INFO]\033[0m $1"; }
ok() { echo -e "\033[32m[OK]\033[0m   $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
err() { echo -e "\033[31m[ERR]\033[0m  $1"; exit 1; }

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
