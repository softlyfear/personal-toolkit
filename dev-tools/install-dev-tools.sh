#!/usr/bin/env bash
#
# install-dev-tools.sh — install common development tools on Ubuntu (latest LTS)
#
# Usage:  bash install-dev-tools.sh [--all|--interactive|tool...]
# Tools:  git | uv | make | postgresql | docker
# Requires: apt-get; root or sudo (except uv installs to user home)
#
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Constants
# =============================================================================

readonly TOOLS=("git" "uv" "make" "postgresql" "docker")

APT_UPDATED=0
SUDO=""

# =============================================================================
# UI helpers
# =============================================================================

info() { echo -e "\033[35m[INFO]  $1\033[0m" >&2; }
ok() { echo -e "\033[32m[OK]    $1\033[0m" >&2; }
warn() { echo -e "\033[33m[WARN]  $1\033[0m" >&2; }
err() {
  echo -e "\033[31m[ERROR] $1\033[0m" >&2
  exit 1
}

# =============================================================================
# Helpers
# =============================================================================

usage() {
  local cmd
  cmd="$(basename "$0")"
  cat << EOF
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
  command -v "$1" > /dev/null 2>&1
}

# "${arr[*]}" would join on IFS, which starts with a newline here.
join_spaces() {
  local IFS=' '
  printf '%s' "$*"
}

# Membership test that does not depend on IFS.
list_contains() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

apt_update_once() {
  if [[ "${APT_UPDATED}" -eq 0 ]]; then
    info "Updating apt package index..."
    ${SUDO} apt-get update -y
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  ${SUDO} apt-get install -y "$@"
}

pick_interactive() {
  local selected=()
  local tool=""
  local ans=""

  if [[ ! -r /dev/tty ]]; then
    err "Interactive input requires a TTY. Download first: wget -qO /tmp/install-dev-tools.sh <raw-url> && bash /tmp/install-dev-tools.sh --interactive"
  fi

  for tool in "${TOOLS[@]}"; do
    printf 'Install %s? [y/N]: ' "${tool}" >&2
    IFS= read -r ans < /dev/tty
    if [[ "${ans}" =~ ^[Yy]$ ]]; then
      selected+=("${tool}")
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
  local tmp_installer=""

  info "Installing uv..."
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if ! need_cmd wget; then
    err "wget is required"
  fi

  warn "uv installer comes from a third party (astral.sh) and is not checksum-pinned in this repo"
  tmp_installer="$(mktemp)"
  # Self-clearing: a RETURN trap otherwise fires again when main returns, with tmp_installer gone.
  trap 'rm -f "${tmp_installer:-}"; trap - RETURN' RETURN
  wget -qO "${tmp_installer}" https://astral.sh/uv/install.sh
  bash -n "${tmp_installer}" || err "Downloaded uv installer failed bash -n (possibly corrupted/tampered)"
  sh "${tmp_installer}"
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
  ${SUDO} systemctl enable postgresql
  ${SUDO} systemctl start postgresql
  ok "postgresql installed and started"
}

install_docker() {
  info "Installing docker..."
  apt_install docker.io
  ${SUDO} systemctl enable docker
  ${SUDO} systemctl start docker

  local target_user="${SUDO_USER:-${USER:-}}"
  if [[ -n "${target_user}" && "${target_user}" != "root" ]]; then
    if ${SUDO} usermod -aG docker "${target_user}"; then
      warn "User '${target_user}' added to docker group (re-login required)"
    else
      warn "Failed to add '${target_user}' to docker group"
    fi
  else
    warn "Run as regular user to auto-add docker group"
  fi

  ok "docker installed and started"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  local os_id="" tool=""
  local -a selected=()

  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if ! need_cmd apt-get; then
    err "Supported only on Ubuntu (apt-get not found)"
  fi

  if [[ -r /etc/os-release ]]; then
    os_id="$(awk -F= '$1 == "ID" {gsub(/^"|"$/, "", $2); print tolower($2); exit}' /etc/os-release)"
    [[ "${os_id}" == "ubuntu" ]] \
      || warn "Unrecognized distro ID '${os_id}' — proceeding since apt-get is present, but this script is tested only on Ubuntu (latest LTS)"
  fi

  # shellcheck disable=SC2312 # exit status of this substitution is intentionally unused here
  if [[ "$(id -u)" -ne 0 ]]; then
    # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
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
      # shellcheck disable=SC2312 # pick_interactive writes the selection to stdout; a read failure is caught by the empty-selection check below
      while IFS= read -r line; do
        [[ -n "${line}" ]] && selected+=("${line}")
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
    # shellcheck disable=SC2312 # join_spaces cannot fail; it only formats the error message
    case "${tool}" in
      git) install_git ;;
      uv) install_uv ;;
      make) install_make ;;
      postgresql | postgres | pg) install_postgresql ;;
      docker) install_docker ;;
      *) err "Unknown tool: ${tool}. Allowed: $(join_spaces "${TOOLS[@]}")" ;;
    esac
  done

  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if list_contains uv "${selected[@]}"; then
    printf '\n'
    warn "Ensure ~/.local/bin is in PATH"
    printf '\n'
  fi

  ok "All selected tools installed"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
