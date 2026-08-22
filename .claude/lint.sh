#!/usr/bin/env bash
#
# lint.sh — the repository's quality gate: formatting, static analysis, unit tests.
#
# Usage:  bash .claude/lint.sh
# Requires: shfmt, shellcheck, bats (see .claude/RULES.md "Tooling")
#
# Runs strictly in this order and stops at the first failure:
#   1. shfmt -d                  formatting differences
#   2. shellcheck -x -S style    static analysis
#   3. bats .claude/testing/unit/   unit tests
#
# Any non-zero exit fails the build. Nothing here rewrites files — use
# `shfmt -i 2 -ci -bn -sr -w` yourself to fix formatting.
#
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Constants
# =============================================================================

readonly SHFMT_FLAGS=(-i 2 -ci -bn -sr)
readonly SHELLCHECK_FLAGS=(-x -S style)
# All tests live under .claude/testing/ — unit tests here, Docker scenario suites alongside.
readonly UNIT_TEST_DIR=".claude/testing/unit"

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
# Helpers
# =============================================================================

need_cmd() {
  command -v "$1" > /dev/null 2>&1
}

# "${arr[*]}" would join on IFS, which starts with a newline here.
join_spaces() {
  local IFS=' '
  printf '%s' "$*"
}

require_tools() {
  local tool
  for tool in "$@"; do
    # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
    if ! need_cmd "${tool}"; then
      err "Required tool not found: ${tool} (see .claude/RULES.md \"Tooling\")"
    fi
  done
}

# shell_files — every shell script the gate applies to, NUL-separated.
#
# --cached AND --others: a plain `git ls-files` lists only TRACKED files, which would
# silently skip any newly added script until someone remembered to `git add` it — exactly
# when review matters most. --exclude-standard keeps .gitignore'd paths out.
#
# Two exclusions, both deliberate:
#   web3/             unmaintained and explicitly out of scope (see .claude/CLAUDE.md)
#   .claude/testing/unit/test_helper/  vendored bats-support/bats-assert — not our code
shell_files() {
  git ls-files -z --cached --others --exclude-standard '*.sh' '*.bash' \
    | grep -zv '^web3/' \
    | grep -zv '^\.claude/testing/unit/test_helper/' \
    | sort -zu
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  local repo_root=""
  repo_root="$(git rev-parse --show-toplevel)" || err "Not inside a git repository"
  cd "${repo_root}" || err "Cannot enter repository root: ${repo_root}"

  require_tools shfmt shellcheck bats git

  local -a files=()
  # shellcheck disable=SC2312 # an empty file list is caught by the count check on the next line
  mapfile -d '' -t files < <(shell_files)
  ((${#files[@]} > 0)) || err "No shell files found to check"

  info "Checking ${#files[@]} shell files"

  info "1/3 shfmt -d"
  # shellcheck disable=SC2312 # exit status of this substitution is intentionally unused here
  shfmt "${SHFMT_FLAGS[@]}" -d "${files[@]}" \
    || err "Formatting differs. Fix with: shfmt $(join_spaces "${SHFMT_FLAGS[@]}") -w <files>"
  # shellcheck disable=SC2312 # exit status of this substitution is intentionally unused here
  ok "formatting matches shfmt $(join_spaces "${SHFMT_FLAGS[@]}")"

  # shellcheck disable=SC2312 # exit status of this substitution is intentionally unused here
  info "2/3 shellcheck $(join_spaces "${SHELLCHECK_FLAGS[@]}")"
  shellcheck "${SHELLCHECK_FLAGS[@]}" "${files[@]}" \
    || err "ShellCheck reported findings (suppress only per-line, with a reason)"
  ok "shellcheck clean"

  info "3/3 bats ${UNIT_TEST_DIR}"
  bats "${UNIT_TEST_DIR}" || err "Unit tests failed"
  ok "unit tests passed"

  ok "All checks passed"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
