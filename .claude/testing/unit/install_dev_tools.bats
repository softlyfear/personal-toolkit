#!/usr/bin/env bats
# Unit tests for dev-tools/install-dev-tools.sh.
#
# The install_* functions run apt/docker/uv against a real system, so they are exercised by
# the Docker suite (.claude/testing/devsetup) rather than here — see test/README.md.

bats_require_minimum_version 1.5.0

setup() {
  load 'helper'
  source_script dev-tools/install-dev-tools.sh
}

@test "info/ok/warn write to stderr, never stdout" {
  for fn in info ok warn; do
    run --separate-stderr bash -c "source '${REPO_ROOT}/dev-tools/install-dev-tools.sh'; ${fn} marker"
    assert_success
    assert_output ""
    [[ "${stderr}" == *marker* ]]
  done
}

@test "err writes to stderr and exits 1" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/dev-tools/install-dev-tools.sh'; err fatal; echo NOT_REACHED"
  assert_failure 1
  refute_output --partial "NOT_REACHED"
  [[ "${stderr}" == *fatal* ]]
}

@test "usage lists the supported tools and modes" {
  run usage
  assert_success
  assert_output --partial "--all"
  assert_output --partial "--interactive"
}

@test "need_cmd distinguishes present from absent commands" {
  run need_cmd bash
  assert_success
  run need_cmd definitely-not-a-real-command-xyz
  assert_failure
}

@test "TOOLS lists exactly the five supported tools" {
  run bash -c "source '${REPO_ROOT}/dev-tools/install-dev-tools.sh'; printf '%s\n' \"\${TOOLS[@]}\" | sort | tr '\n' ' '"
  assert_success
  assert_output "docker git make postgresql uv "
}

@test "every tool in TOOLS has a matching install_ function" {
  run bash -c "
    source '${REPO_ROOT}/dev-tools/install-dev-tools.sh'
    for t in \"\${TOOLS[@]}\"; do
      declare -F \"install_\${t}\" > /dev/null || { echo \"missing install_\${t}\"; exit 1; }
    done
    echo ALL_PRESENT
  "
  assert_success
  assert_output "ALL_PRESENT"
}

@test "join_spaces joins with single spaces regardless of the script's IFS" {
  run join_spaces git uv make
  assert_success
  assert_output "git uv make"
}

@test "join_spaces handles the empty and single-item cases" {
  run join_spaces
  assert_success
  assert_output ""

  run join_spaces git
  assert_success
  assert_output "git"
}

# Regression guard: the previous idiom was [[ " ${selected[*]} " == *" uv "* ]], which
# joins on the first character of IFS. Under IFS=$'\n\t' it silently stopped matching for
# any multi-item selection, so the PATH warning vanished from `--all` runs.
@test "list_contains finds an item in a multi-item list" {
  run list_contains uv git uv make
  assert_success
}

@test "list_contains finds a single item and rejects a missing one" {
  run list_contains uv uv
  assert_success

  run list_contains uv git make docker
  assert_failure
}

@test "list_contains matches exactly, not as a substring" {
  run list_contains uv uvx
  assert_failure
}

@test "sourcing the script does not execute main" {
  run bash -c "source '${REPO_ROOT}/dev-tools/install-dev-tools.sh' && echo SOURCED"
  assert_success
  assert_output "SOURCED"
}
