# test/helper.bash — shared loader for every .bats file in this directory.
#
# Scripts under test are single-file and curl/wget-piped (see .claude/CLAUDE.md), so there
# is no lib/ to source. Each script instead carries a main-guard, which lets these tests
# `source` it to get its functions WITHOUT running main.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
export REPO_ROOT

# source_script <relative-path> — load a script's functions without executing main.
#
# The scripts set IFS=$'\n\t' per the project's Bash rules. Letting that leak into bats
# breaks its failure-reporting path: passing tests still report, but the first FAILING
# test silently vanishes and the test count goes wrong. So restore the default IFS for
# the test process itself after sourcing.
source_script() {
  # shellcheck disable=SC1090 # path is supplied by the caller at runtime
  source "${REPO_ROOT}/$1"
  IFS=$' \t\n'
}
