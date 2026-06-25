#!/usr/bin/env bash
#
# install-dev-tools.sh — install common development tools on Ubuntu/Debian
#
# Usage:  bash install-dev-tools.sh [--all|--interactive|tool...]
# Tools:  git | uv | make | postgresql | docker
# Requires: apt-get; root or sudo (except uv installs to user home)
#
set -euo pipefail


# =============================================================================
# Constants
# =============================================================================

readonly TOOLS=("git" "uv" "make" "postgresql" "docker")

APT_UPDATED=0
SUDO=""


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
  ${cmd}
  ${cmd} --all
  ${cmd} --interactive
  ${cmd} <git|uv|make|postgresql|docker> [...]

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


# =============================================================================
# Tool installers
# =============================================================================

install_git() {
  info "Installing git..."
  apt_install git
  ok "git installed"
}

install_uv() {
  info "Installing uv..."
  apt_install pipx python3-venv
  if command -v pipx >/dev/null 2>&1; then
    pipx install --force uv || pipx upgrade uv
  else
    err "pipx was not installed correctly"
  fi
  ok "uv installed"
}

install_make() {
  info "Installing make..."
  apt_install make
  ok "make installed"
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


# =============================================================================
# MAIN
# =============================================================================

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
  "" | --all | all)
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
    make) install_make ;;
    postgresql | postgres | pg) install_postgresql ;;
    docker) install_docker ;;
    *) err "Unknown tool: $tool. Allowed: ${TOOLS[*]}" ;;
  esac
done

if [[ " ${selected[*]} " == *" uv "* ]]; then
  printf '\n'
  warn "Ensure ~/.local/bin is in PATH"
  printf '\n'
fi

ok "All selected tools installed"
