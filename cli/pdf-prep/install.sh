#!/usr/bin/env bash
#
# install.sh — set up pdf-prep in place: uv, the virtualenv, task/ and result/, a launcher
#
# Runs from the project directory it ships in (a clone or a downloaded copy of cli/pdf-prep).
# It fetches nothing from this repository: everything it needs is already next to it.
#
# Usage:  bash cli/pdf-prep/install.sh
#         PDFPREP_BIN_DIR=~/bin bash cli/pdf-prep/install.sh   # launcher somewhere else
# Requires: bash 4+, a network connection for the Python package index; never root
# Uninstall: rm ~/.local/bin/pdf-prep && rm -rf <project>/.venv
#
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Constants
# =============================================================================

readonly LAUNCHER_NAME="pdf-prep"
readonly BIN_DIR="${PDFPREP_BIN_DIR:-${HOME}/.local/bin}"
readonly UV_INSTALLER_URL="https://astral.sh/uv/install.sh"
# Files that must sit next to this script for the install to make sense
readonly REQUIRED_FILES=("pyproject.toml" "src/pdfprep/cli.py" "config.example.toml")

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
# Preconditions
# =============================================================================

require_preconditions() {
  local uid="" required_cmd=""

  uid="$(id -u)"
  [[ "${uid}" -ne 0 ]] \
    || err "Run as your normal user, not root: the venv and the launcher belong to \${HOME}"

  for required_cmd in mktemp install; do
    command -v "${required_cmd}" > /dev/null 2>&1 \
      || err "Required command not found: ${required_cmd}"
  done

  command -v curl > /dev/null 2>&1 || command -v wget > /dev/null 2>&1 \
    || err "Either curl or wget is required to install uv"
}

# The project directory is wherever this script lives; a wget-piped copy has no such path.
resolve_project_dir() {
  local source="${BASH_SOURCE[0]}" dir="" file=""

  [[ -f "${source}" ]] \
    || err "Run this script from a copy on disk (bash cli/pdf-prep/install.sh), not piped from a URL"
  dir="$(cd -- "$(dirname -- "${source}")" && pwd -P)"

  for file in "${REQUIRED_FILES[@]}"; do
    [[ -f "${dir}/${file}" ]] || err "Missing ${file} in ${dir} — copy the whole cli/pdf-prep directory"
  done
  printf '%s\n' "${dir}"
}

ensure_local_bin_on_path() {
  case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *) export PATH="${BIN_DIR}:${PATH}" ;;
  esac
}

# =============================================================================
# uv
# =============================================================================

download_to() {
  local url="$1" dest="$2"

  if command -v curl > /dev/null 2>&1; then
    curl -fsSL "${url}" -o "${dest}"
  else
    wget -qO "${dest}" "${url}"
  fi
}

ensure_uv() {
  local tmp_installer=""

  if command -v uv > /dev/null 2>&1; then
    ok "uv already present"
    return 0
  fi

  warn "uv installer comes from a third party (astral.sh) and is not checksum-pinned here"
  tmp_installer="$(mktemp)"
  # Self-clearing: a RETURN trap otherwise fires again when the caller returns.
  trap 'rm -f "${tmp_installer:-}"; trap - RETURN' RETURN
  # shellcheck disable=SC2310 # predicate; its return code is handled by set -e in this chain
  download_to "${UV_INSTALLER_URL}" "${tmp_installer}" || err "Failed to download the uv installer"
  bash -n "${tmp_installer}" || err "Downloaded uv installer failed bash -n (possibly corrupted)"
  bash "${tmp_installer}" || err "uv installer failed"
  ensure_local_bin_on_path
  command -v uv > /dev/null 2>&1 || err "uv is still not on PATH after install"
  ok "uv installed"
}

# =============================================================================
# Project
# =============================================================================

create_directories() {
  local project_dir="$1" sub=""

  for sub in task result .work; do
    mkdir -p "${project_dir}/${sub}" || err "Cannot create ${project_dir}/${sub}"
  done
  ok "task/ and result/ ready in ${project_dir}"
}

seed_config() {
  local project_dir="$1"

  if [[ -f "${project_dir}/config.toml" ]]; then
    info "config.toml kept as is"
    return 0
  fi
  cp "${project_dir}/config.example.toml" "${project_dir}/config.toml" \
    || err "Cannot create ${project_dir}/config.toml"
  ok "config.toml created from the example"
}

sync_dependencies() {
  local project_dir="$1"

  info "Installing dependencies — easyocr pulls the CPU build of torch, expect a few hundred MB"
  (cd "${project_dir}" && uv sync) || err "uv sync failed in ${project_dir}"
  ok "Virtualenv ready: ${project_dir}/.venv"
}

# The launcher pins PDFPREP_HOME so task/ and result/ resolve from any working directory.
install_launcher() {
  local project_dir="$1" uv_bin="" tmp_launcher=""

  uv_bin="$(command -v uv)"
  mkdir -p "${BIN_DIR}" || err "Cannot create ${BIN_DIR}"
  tmp_launcher="$(mktemp)"
  # Self-clearing: a RETURN trap otherwise fires again when the caller returns.
  trap 'rm -f "${tmp_launcher:-}"; trap - RETURN' RETURN

  cat > "${tmp_launcher}" << EOF
#!/usr/bin/env bash
set -euo pipefail
export PDFPREP_HOME="${project_dir}"
exec "${uv_bin}" run --project "${project_dir}" pdf-prep "\$@"
EOF

  bash -n "${tmp_launcher}" || err "Generated launcher failed bash -n"
  install -m 755 "${tmp_launcher}" "${BIN_DIR}/${LAUNCHER_NAME}" \
    || err "Cannot install ${BIN_DIR}/${LAUNCHER_NAME}"
  ok "Launcher installed: ${BIN_DIR}/${LAUNCHER_NAME}"
}

run_doctor() {
  local project_dir="$1"

  (cd "${project_dir}" && uv run pdf-prep doctor) \
    || warn "pdf-prep doctor reported failing checks — see the table above"
}

print_summary() {
  local project_dir="$1"

  ok "pdf-prep is installed"
  echo "Project:  ${project_dir}"
  echo "Put PDFs: ${project_dir}/task"
  echo "Results:  ${project_dir}/result"
  echo ""
  echo "  pdf-prep split                      compress + cut into parts for a Claude Project"
  echo "  pdf-prep compress                   compress only"
  echo "  pdf-prep translate --lang russian   translate (Claude CLI by default)"
  echo "  pdf-prep doctor --llm               check everything, provider included"
  case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *) warn "${BIN_DIR} is not in your PATH — add it to ~/.bashrc to call pdf-prep directly" ;;
  esac
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  local project_dir=""

  require_preconditions
  ensure_local_bin_on_path
  project_dir="$(resolve_project_dir)"
  info "Project directory: ${project_dir}"

  ensure_uv
  create_directories "${project_dir}"
  seed_config "${project_dir}"
  sync_dependencies "${project_dir}"
  install_launcher "${project_dir}"
  run_doctor "${project_dir}"
  print_summary "${project_dir}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
