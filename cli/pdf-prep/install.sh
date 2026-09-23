#!/usr/bin/env bash
#
# install.sh — set up pdf-prep in place: uv, the virtualenv, task/ and result/, a launcher
#
# Runs from the project directory it ships in (a clone or a downloaded copy of cli/pdf-prep).
# It fetches nothing from this repository: everything it needs is already next to it.
#
# Usage:  bash cli/pdf-prep/install.sh
#         PDFPREP_BIN_DIR=~/bin bash cli/pdf-prep/install.sh   # launcher somewhere else
#         PDFPREP_TORCH=cpu bash cli/pdf-prep/install.sh       # skip the GPU probe
# Requires: bash 4+, a network connection for the Python package index; never root
# OCR runs on the GPU when this machine has one torch supports: the script probes the GPU,
# installs the matching torch build into .venv, checks it on the device, and falls back to
# the CPU build when any step fails. Builds: cuda | rocm-linux | rocm-windows | cpu.
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
readonly TORCH_BUILDS=("cpu" "cuda" "rocm-linux" "rocm-windows")
# The cuda group ships CUDA 13.2 wheels: they need a CUDA 13 driver (R580+) and sm_75+
readonly MIN_CUDA_MAJOR=13
readonly MIN_COMPUTE_CAP=75
# gfx_target_version of the Radeon GPUs ROCm 7.2 supports: RX 6800/6900, RX 7600-7900,
# Strix Halo, RX 9060/9070. A Ryzen iGPU (gfx1036, gfx1103) is an AMD GPU too and is excluded.
readonly ROCM_LINUX_TARGETS=" 100300 110000 110001 110002 115001 120000 120001 "
# AMD's Windows wheels cover RDNA3 and RDNA4 cards
readonly ROCM_WINDOWS_NAME_RE='Radeon.*(RX[[:space:]]*(7[6-9][0-9]{2}|9[0-9]{3})|PRO[[:space:]]*W[79][0-9]{3}|8060S)'

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

# =============================================================================
# GPU probe
# =============================================================================

detect_platform() {
  local kernel=""

  kernel="$(uname -s)"
  case "${kernel}" in
    Linux) printf 'linux\n' ;;
    MINGW* | MSYS* | CYGWIN*) printf 'windows\n' ;;
    *) printf 'other\n' ;;
  esac
}

nvidia_supported() {
  local listing="" smi="" name="" cap="" cuda_major=""

  command -v nvidia-smi > /dev/null 2>&1 || return 1
  listing="$(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader 2> /dev/null)" \
    || return 1
  [[ -n "${listing}" ]] || return 1
  smi="$(nvidia-smi 2> /dev/null)" || return 1
  if [[ "${smi}" =~ CUDA\ Version:\ *([0-9]+)\. ]]; then
    cuda_major="${BASH_REMATCH[1]}"
  fi
  if [[ -z "${cuda_major}" ]] || ((cuda_major < MIN_CUDA_MAJOR)); then
    warn "NVIDIA GPU found, but its driver supports CUDA ${cuda_major:-unknown}; the GPU build needs CUDA ${MIN_CUDA_MAJOR}+ — update the driver to use it"
    return 1
  fi
  while IFS=',' read -r name cap; do
    cap="${cap//[[:space:]]/}"
    [[ "${cap}" =~ ^([0-9]+)\.([0-9])$ ]] || continue
    if ((BASH_REMATCH[1] * 10 + BASH_REMATCH[2] >= MIN_COMPUTE_CAP)); then
      info "GPU: ${name} (compute ${cap}, CUDA ${cuda_major})"
      return 0
    fi
  done <<< "${listing//$'\r'/}"
  warn "NVIDIA GPU found, but it is older than the CUDA ${MIN_CUDA_MAJOR} build supports"
  return 1
}

amd_linux_supported() {
  local properties="" target=""

  for properties in /sys/class/kfd/kfd/topology/nodes/*/properties; do
    [[ -r "${properties}" ]] || continue
    target="$(awk '$1 == "gfx_target_version" { print $2 }' "${properties}")"
    [[ -n "${target}" && "${ROCM_LINUX_TARGETS}" == *" ${target} "* ]] || continue
    if [[ ! -r /dev/kfd || ! -w /dev/kfd ]]; then
      warn "AMD GPU found (gfx target ${target}), but /dev/kfd is not accessible — add yourself to the render and video groups, log in again and re-run"
      return 1
    fi
    info "GPU: AMD, gfx target ${target}"
    return 0
  done
  return 1
}

amd_windows_supported() {
  local names="" name=""

  command -v powershell.exe > /dev/null 2>&1 || return 1
  # shellcheck disable=SC2016 # $_ is PowerShell's, it must reach powershell.exe unexpanded
  names="$(powershell.exe -NoProfile -NonInteractive -Command \
    'Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }' 2> /dev/null)" \
    || return 1
  while read -r name; do
    if [[ "${name}" =~ ${ROCM_WINDOWS_NAME_RE} ]]; then
      info "GPU: ${name}"
      return 0
    fi
  done <<< "${names//$'\r'/}"
  return 1
}

# Prints the torch build to try on this machine. A match is only a candidate:
# probe_gpu_build confirms it on the device after the install.
detect_torch_build() {
  local platform="$1" build="" allowed=""

  if [[ -n "${PDFPREP_TORCH:-}" ]]; then
    printf -v allowed '%s ' "${TORCH_BUILDS[@]}"
    for build in "${TORCH_BUILDS[@]}"; do
      if [[ "${PDFPREP_TORCH}" == "${build}" ]]; then
        printf '%s\n' "${build}"
        return 0
      fi
    done
    err "PDFPREP_TORCH must be one of: ${allowed}"
  fi

  # shellcheck disable=SC2310 # probes report a missing GPU through their exit status
  if nvidia_supported; then
    printf 'cuda\n'
  elif [[ "${platform}" == "linux" ]] && amd_linux_supported; then
    printf 'rocm-linux\n'
  elif [[ "${platform}" == "windows" ]] && amd_windows_supported; then
    printf 'rocm-windows\n'
  else
    printf 'cpu\n'
  fi
}

# uv flags that select one torch build; the launcher and doctor must pass the same ones,
# or `uv run` re-syncs the default cpu group over the GPU build.
build_flags() {
  local -n flags_out="$1"
  local build="$2"

  flags_out=("--no-default-groups" "--group" "${build}")
  # AMD publishes its Windows wheels for Python 3.12 only
  if [[ "${build}" == "rocm-windows" ]]; then
    flags_out+=("--python" "3.12")
  fi
}

sync_build() {
  local project_dir="$1" build="$2" flags=()

  build_flags flags "${build}"
  (cd "${project_dir}" && uv sync "${flags[@]}")
}

# Proves the build on the device: a convolution and an LSTM, the two layer types EasyOCR's
# detector and recogniser are made of.
probe_gpu_build() {
  local project_dir="$1"

  (cd "${project_dir}" && uv run --no-sync python -) << 'EOF'
import sys

import torch

if not torch.cuda.is_available():
    sys.exit(f"torch {torch.__version__} sees no GPU")
device = torch.device("cuda")
image = torch.rand(1, 3, 256, 256, device=device)
conv = torch.nn.Conv2d(3, 16, 3, padding=1).to(device)
lstm = torch.nn.LSTM(16, 32, bidirectional=True, batch_first=True).to(device)
features = conv(image).mean(dim=2).transpose(1, 2)
lstm(features)
torch.cuda.synchronize()
print(f"{torch.cuda.get_device_name(0)} · torch {torch.__version__}")
EOF
}

sync_dependencies() {
  local project_dir="$1" build="$2" device=""

  if [[ "${build}" != "cpu" ]]; then
    info "Installing the ${build} build of torch — several GB on the first install"
    # shellcheck disable=SC2310 # a failed GPU build falls back to the CPU below
    if sync_build "${project_dir}" "${build}" \
      && device="$(probe_gpu_build "${project_dir}")"; then
      ok "OCR will run on the GPU: ${device}"
      printf '%s\n' "${build}"
      return 0
    fi
    warn "The ${build} build did not pass the GPU check — installing the CPU build instead"
  fi

  info "Installing dependencies with the CPU build of torch — a few hundred MB"
  # shellcheck disable=SC2310 # the error message is the handling
  sync_build "${project_dir}" cpu || err "uv sync failed in ${project_dir}"
  ok "Virtualenv ready: ${project_dir}/.venv (OCR on the CPU)"
  printf 'cpu\n'
}

# The launcher pins PDFPREP_HOME so task/ and result/ resolve from any working directory.
install_launcher() {
  local project_dir="$1" build="$2" uv_bin="" tmp_launcher="" flags=() flag_text=""

  uv_bin="$(command -v uv)"
  build_flags flags "${build}"
  printf -v flag_text '%s ' "${flags[@]}"
  mkdir -p "${BIN_DIR}" || err "Cannot create ${BIN_DIR}"
  tmp_launcher="$(mktemp)"
  # Self-clearing: a RETURN trap otherwise fires again when the caller returns.
  trap 'rm -f "${tmp_launcher:-}"; trap - RETURN' RETURN

  cat > "${tmp_launcher}" << EOF
#!/usr/bin/env bash
set -euo pipefail
export PDFPREP_HOME="${project_dir}"
exec "${uv_bin}" run --project "${project_dir}" ${flag_text}pdf-prep "\$@"
EOF

  bash -n "${tmp_launcher}" || err "Generated launcher failed bash -n"
  install -m 755 "${tmp_launcher}" "${BIN_DIR}/${LAUNCHER_NAME}" \
    || err "Cannot install ${BIN_DIR}/${LAUNCHER_NAME}"
  ok "Launcher installed: ${BIN_DIR}/${LAUNCHER_NAME}"
}

run_doctor() {
  local project_dir="$1" build="$2" flags=()

  build_flags flags "${build}"
  (cd "${project_dir}" && uv run "${flags[@]}" pdf-prep doctor) \
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
  local project_dir="" platform="" build=""

  require_preconditions
  ensure_local_bin_on_path
  project_dir="$(resolve_project_dir)"
  info "Project directory: ${project_dir}"

  ensure_uv
  create_directories "${project_dir}"
  seed_config "${project_dir}"
  platform="$(detect_platform)"
  build="$(detect_torch_build "${platform}")"
  build="$(sync_dependencies "${project_dir}" "${build}")"
  install_launcher "${project_dir}" "${build}"
  run_doctor "${project_dir}" "${build}"
  print_summary "${project_dir}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
