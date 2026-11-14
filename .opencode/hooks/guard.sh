#!/usr/bin/env bash
#
# guard.sh — repository tripwire for destructive Git, protected config, and the commit gate.
#
# Usage:    called by .opencode/plugins/guard/ and by unit tests; reads one JSON event on stdin
# Requires: jq, bash .opencode/lint.sh's own tools for the commit gate
#
# Event: {"tool":"shell","command":"...","cwd":"..."}
#        {"tool":"edit","paths":["..."],"cwd":"..."}
# Allow: empty stdout. Deny: {"effect":"deny","message":"..."}
#
#   - `git commit` runs .opencode/lint.sh first and is denied while the gate fails;
#   - git commands with no undo (force push, reset --hard, clean -f, history rewrites)
#     are denied until the user approves them in chat and the command is re-run with
#     the ALLOW_DESTRUCTIVE_GIT=1 prefix;
#   - lint and hook configuration is denied the same way, with ALLOW_CONFIG_EDIT=1.
#
# The prefixes prevent accidental changes; explicit authorization must come from the user.
# OpenCode's permission hook turns a deny object into effect "deny". An empty result allows.
#
set -euo pipefail
IFS=$'\n\t'

readonly GIT_OVERRIDE="ALLOW_DESTRUCTIVE_GIT=1"
readonly CONFIG_OVERRIDE="ALLOW_CONFIG_EDIT=1"
# the files that decide whether the gate passes, and the hook wiring itself
readonly PROTECTED_CONFIGS=(
  .shellcheckrc
  .editorconfig
  .gitattributes
  .opencode/lint.sh
  .opencode/testing/pdf-prep/ruff.toml
  .opencode/hooks/guard.sh
  .opencode/plugins/guard/index.ts
  opencode.jsonc
  .github/workflows/gate.yml
)
readonly GATE_TAIL_LINES=40

# `git` at a command boundary, optionally with -C <dir>; a regex held in variables, because
# `;&|` written straight into [[ =~ ]] is a syntax error
readonly GIT_RE='(^|[;&|(`[:space:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+'
readonly SAME_CMD='[^;&|]*'
readonly DESTRUCTIVE_GIT=(
  "${GIT_RE}push${SAME_CMD}([[:space:]](--force|--force-with-lease|-f)([=[:space:]]|\$)|[[:space:]]\+)"
  "${GIT_RE}reset${SAME_CMD}--hard"
  "${GIT_RE}clean${SAME_CMD}[[:space:]]-[a-zA-Z]*f"
  "${GIT_RE}branch${SAME_CMD}[[:space:]]-D([[:space:]]|\$)"
  "${GIT_RE}(checkout|restore)[[:space:]]+(--[[:space:]]+)?\.([[:space:]]|\$)"
  "${GIT_RE}(filter-branch|filter-repo)"
  "${GIT_RE}stash[[:space:]]+(drop|clear)"
)
readonly DESTRUCTIVE_GIT_REASONS=(
  "force push rewrites the published branch"
  "reset --hard discards uncommitted work"
  "clean -f deletes untracked files"
  "branch -D drops unmerged commits"
  "discards every uncommitted change in the tree"
  "rewrites history"
  "drops stashed work"
)
readonly GIT_COMMIT_RE="${GIT_RE}commit([[:space:]]|\$)"
readonly SHELL_WRITE_RE='(sed[[:space:]]+-i|tee[[:space:]]|write_text|>[[:space:]]*)'

# destructive_git_reason <command> — prints why the command cannot be undone, or nothing.
destructive_git_reason() {
  local cmd="$1" index
  for index in "${!DESTRUCTIVE_GIT[@]}"; do
    if [[ ${cmd} =~ ${DESTRUCTIVE_GIT[index]} ]]; then
      printf '%s' "${DESTRUCTIVE_GIT_REASONS[index]}"
      return 0
    fi
  done
}

# is_git_commit <command> — true when the command creates a commit.
is_git_commit() {
  [[ $1 =~ ${GIT_COMMIT_RE} ]]
}

# protected_config <path relative to the repository> — true for a gate or hook config file.
protected_config() {
  local path="$1" protected
  for protected in "${PROTECTED_CONFIGS[@]}"; do
    [[ ${path} == "${protected}" ]] && return 0
  done
  return 1
}

# writes_protected_config <command> — prints the protected file a shell command rewrites.
# Covers the usual in-place writers; it is a tripwire, not a parser. The writer and the file
# must share one simple command: "…write_text(…) && bash .opencode/lint.sh" only runs the gate.
writes_protected_config() {
  local cmd="$1" protected segment split
  local -a segments=()
  split="${cmd//&&/$'\n'}"
  split="${split//;/$'\n'}"
  split="${split//|/$'\n'}"
  mapfile -t segments <<< "${split}"
  for segment in "${segments[@]}"; do
    for protected in "${PROTECTED_CONFIGS[@]}"; do
      [[ ${segment} == *"${protected}"* ]] || continue
      if [[ ${segment} =~ ${SHELL_WRITE_RE}.*${protected//./\\.} ]]; then
        printf '%s' "${protected}"
        return 0
      fi
    done
  done
  return 1
}

deny() {
  jq -n --arg message "$1" '{effect: "deny", message: $message}'
}

check_bash() {
  local cmd="$1" repo="$2" reason file
  if [[ ${cmd} != *"${GIT_OVERRIDE}"* ]]; then
    reason="$(destructive_git_reason "${cmd}")"
    if [[ -n ${reason} ]]; then
      deny "Blocked: ${reason}. Ask the user in chat; after an explicit yes, re-run with the ${GIT_OVERRIDE} prefix."
      return 0
    fi
  fi
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if [[ ${cmd} != *"${CONFIG_OVERRIDE}"* ]] && file="$(writes_protected_config "${cmd}")"; then
    deny "Blocked: ${file} decides whether the quality gate passes. Fix the code instead; if the user asked for this config change, re-run with the ${CONFIG_OVERRIDE} prefix."
    return 0
  fi
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if is_git_commit "${cmd}"; then
    local output
    if ! output="$(cd "${repo}" && bash .opencode/lint.sh 2>&1)"; then
      local tail_lines
      tail_lines="$(tail -n "${GATE_TAIL_LINES}" <<< "${output}")"
      deny "Blocked: bash .opencode/lint.sh fails, fix it before committing. Last lines:
${tail_lines}"
    fi
  fi
}

# Normalize lexically: deleted and newly added patch targets need not exist yet.
normalize_path() {
  local path="$1" base="$2" part
  local -a components=() parts=()
  [[ ${path} == /* ]] || path="${base}/${path}"
  IFS='/' read -r -a components <<< "${path}"
  for part in "${components[@]}"; do
    case "${part}" in
      '' | .) ;;
      ..)
        ((${#parts[@]} == 0)) || unset 'parts[-1]'
        ;;
      *) parts+=("${part}") ;;
    esac
  done
  printf '/%s' "${parts[@]}"
}

check_edit() {
  local path="$1" repo="$2" cwd="${3:-$2}"
  path="$(normalize_path "${path}" "${cwd}")"
  path="${path#"${repo}/"}"
  # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
  if protected_config "${path}"; then
    deny "Blocked: ${path} decides whether the quality gate passes. Fix the code instead; if the user asked for this config change, make it through Bash with the ${CONFIG_OVERRIDE} prefix."
  fi
}

# check_paths <repo> <cwd> <path>... — deny when any edit target is protected config.
check_paths() {
  local repo="$1" cwd="$2" path
  shift 2
  for path in "$@"; do
    [[ -n ${path} ]] || continue
    path="$(normalize_path "${path}" "${cwd}")"
    path="${path#"${repo}/"}"
    # shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
    if protected_config "${path}"; then
      deny "Blocked: ${path} decides whether the quality gate passes. If the user authorized this config change, make it through Bash with the ${CONFIG_OVERRIDE} prefix."
      return 0
    fi
  done
}

main() {
  local input tool repo field cwd
  local -a paths=()
  input="$(cat)"
  tool="$(jq -r '.tool // ""' <<< "${input}")"
  cwd="$(jq -r '.cwd // empty' <<< "${input}")"
  cwd="${cwd:-${PWD}}"
  repo="$(git -C "${cwd}" rev-parse --show-toplevel)"
  case "${tool}" in
    shell)
      field="$(jq -r '.command // ""' <<< "${input}")"
      check_bash "${field}" "${repo}"
      ;;
    edit)
      # jq lists each edit target; a failure leaves the list empty and the edit is not denied here.
      field="$(jq -r '(.paths // [])[], (.path // empty)' <<< "${input}")" || field=""
      mapfile -t paths <<< "${field}"
      check_paths "${repo}" "${cwd}" "${paths[@]}"
      ;;
    *) ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
