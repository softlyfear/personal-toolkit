#!/usr/bin/env bats
# Unit tests for server-scripts/service-manager.sh.

bats_require_minimum_version 1.5.0

setup() {
  load 'helper'
  source_script server-scripts/service-manager.sh
}

@test "info writes to stderr" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/server-scripts/service-manager.sh'; info hello"
  assert_success
  assert_output ""
  [[ "${stderr}" == *hello* ]]
}

@test "ok writes to stderr" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/server-scripts/service-manager.sh'; ok done"
  assert_success
  [[ "${stderr}" == *done* ]]
}

@test "warn writes to stderr" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/server-scripts/service-manager.sh'; warn careful"
  assert_success
  [[ "${stderr}" == *careful* ]]
}

@test "err writes to stderr and exits 1" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/server-scripts/service-manager.sh'; err boom; echo NOT_REACHED"
  assert_failure 1
  refute_output --partial "NOT_REACHED"
  [[ "${stderr}" == *boom* ]]
}

@test "usage prints the synopsis to stdout" {
  run usage
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "status all"
}

@test "normalize_service maps every postgresql alias" {
  for alias in pg postgres postgresql; do
    run normalize_service "${alias}"
    assert_success
    assert_output "postgresql"
  done
}

@test "normalize_service passes docker through" {
  run normalize_service docker
  assert_success
  assert_output "docker"
}

@test "normalize_service leaves an unknown name untouched" {
  run normalize_service nginx
  assert_success
  assert_output "nginx"
}

@test "is_allowed accepts services from ALLOWED_SERVICES" {
  run is_allowed postgresql
  assert_success
  run is_allowed docker
  assert_success
}

@test "is_allowed rejects a service outside the allow-list" {
  run is_allowed nginx
  assert_failure
}

@test "join_spaces renders the allow-list on one line" {
  run join_spaces "${ALLOWED_SERVICES[@]}"
  assert_success
  refute_output --partial $'\n'
  assert_output --partial "postgresql"
}

@test "sourcing the script does not execute main" {
  run bash -c "source '${REPO_ROOT}/server-scripts/service-manager.sh' && echo SOURCED"
  assert_success
  assert_output "SOURCED"
}
