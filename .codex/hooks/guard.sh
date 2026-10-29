#!/usr/bin/env bash
# Codex hook entry point; share the policy and commit gate with Claude Code.
# Usage: bash .codex/hooks/guard.sh < hook-event.json
# Requires: git, jq, the tools required by .claude/lint.sh
set -euo pipefail
IFS=$'\n\t'

codex_main() {
  local repo
  repo="$(git rev-parse --show-toplevel)"
  # shellcheck source=.claude/hooks/guard.sh
  source "${repo}/.claude/hooks/guard.sh"
  main "$@"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  codex_main "$@"
fi
