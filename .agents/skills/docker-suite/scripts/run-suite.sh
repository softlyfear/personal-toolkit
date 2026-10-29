#!/usr/bin/env bash
# Delegate to the shared Docker suite runner so both tools use the same lifecycle.
# Usage: bash .agents/skills/docker-suite/scripts/run-suite.sh <suite> [scenario-filter]
# Requires: git, docker (daemon reachable)
set -euo pipefail
IFS=$'\n\t'

main() {
  local repo
  repo="$(git rev-parse --show-toplevel)"
  exec bash "${repo}/.claude/skills/docker-suite/scripts/run-suite.sh" "$@"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
