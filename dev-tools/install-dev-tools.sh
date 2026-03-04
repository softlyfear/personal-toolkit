#!/usr/bin/env bash
set -euo pipefail

TOOLS=("git" "uv" "postgresql" "docker")
APT_UPDATED=0
SUDO=""

info() { echo -e "\033[35m[INFO]\033[0m $1"; }
ok() { echo -e "\033[32m[OK]\033[0m   $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1"; }
err() { echo -e "\033[31m[ERR]\033[0m  $1"; exit 1; }

usage() {
  local cmd
  cmd="$(basename "$0")"
  cat <<EOF
Usage:
  ${cmd}
  ${cmd} --all
  ${cmd} --interactive
  ${cmd} <git|uv|postgresql|docker> [...]

Examples:
  ${cmd}
  ${cmd} --all
  ${cmd} git uv
  ${cmd} --interactive
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

apt_update_once() {
  if [[ "$APT_UPDATED" -eq 0 ]]; then
    info "Updating apt package index..."
    $SUDO apt-get update -y
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  $SUDO apt-get install -y "$@"
}

install_git() {
  info "Installing git..."
  apt_install git
  ok "git installed"
}

install_uv() {
  info "Installing uv..."
  curl -fsSL https://astral.sh/uv/install.sh | sh
  ok "uv installed"
}

install_postgresql() {
  info "Installing postgresql..."
  apt_install postgresql postgresql-contrib
  $SUDO systemctl enable postgresql
  $SUDO systemctl start postgresql
  ok "postgresql installed and started"
}

install_docker() {
  info "Installing docker..."
  apt_install docker.io
  $SUDO systemctl enable docker
  $SUDO systemctl start docker

  target_user="${SUDO_USER:-$USER}"
  if [[ -n "$target_user" && "$target_user" != "root" ]]; then
    $SUDO usermod -aG docker "$target_user" || true
    warn "User '$target_user' added to docker group (re-login required)"
  else
    warn "Run as regular user to auto-add docker group"
  fi

  ok "docker installed and started"
}

pick_interactive() {
  local selected=()
  local tool=""
  local ans=""

  for tool in "${TOOLS[@]}"; do
    read -r -p "Install $tool? [y/N]: " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      selected+=("$tool")
    fi
  done

  printf '%s\n' "${selected[@]}"
}

if ! need_cmd apt-get; then
  err "Supported only on apt-based systems (Ubuntu/Debian)"
fi

if [[ "$(id -u)" -ne 0 ]]; then
  if ! need_cmd sudo; then
    err "sudo is required when running as non-root user"
  fi
  SUDO="sudo"
fi

selected=()
case "${1:---all}" in
  "")
    selected=("${TOOLS[@]}")
    ;;
  --all)
    selected=("${TOOLS[@]}")
    ;;
  all)
    selected=("${TOOLS[@]}")
    ;;
  --interactive)
    while IFS= read -r line; do
      [[ -n "$line" ]] && selected+=("$line")
    done < <(pick_interactive)
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    selected=("$@")
    ;;
esac

if [[ ${#selected[@]} -eq 0 ]]; then
  warn "No tools selected"
  exit 0
fi

tool=""
for tool in "${selected[@]}"; do
  case "$tool" in
    git) install_git ;;
    uv) install_uv ;;
    postgresql | postgres | pg) install_postgresql ;;
    docker) install_docker ;;
    *) err "Unknown tool: $tool. Allowed: ${TOOLS[*]}" ;;
  esac
done

ok "All selected tools installed"
