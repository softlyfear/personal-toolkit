#!/usr/bin/env bats
# Unit tests for server-scripts/update_system_all.sh.

bats_require_minimum_version 1.5.0

setup() {
  load 'helper'
  source_script server-scripts/update_system_all.sh
}

@test "info/ok/warn write to stderr, never stdout" {
  for fn in info ok warn; do
    run --separate-stderr bash -c "source '${REPO_ROOT}/server-scripts/update_system_all.sh'; ${fn} marker"
    assert_success
    assert_output ""
    [[ "${stderr}" == *marker* ]]
  done
}

@test "err writes to stderr and exits 1" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/server-scripts/update_system_all.sh'; err fatal; echo NOT_REACHED"
  assert_failure 1
  refute_output --partial "NOT_REACHED"
  [[ "${stderr}" == *fatal* ]]
}

@test "need_cmd succeeds for a command that exists" {
  run need_cmd bash
  assert_success
}

@test "need_cmd fails for a command that does not exist" {
  run need_cmd definitely-not-a-real-command-xyz
  assert_failure
}

@test "sourcing the script does not execute main" {
  run bash -c "source '${REPO_ROOT}/server-scripts/update_system_all.sh' && echo SOURCED"
  assert_success
  assert_output "SOURCED"
}
