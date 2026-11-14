#!/usr/bin/env bats
# Unit tests for the two checksum-pinned installers:
#   server-scripts/install_svcctl.sh     -> installs service-manager.sh as svcctl
#   server-scripts/install_sysupdate.sh  -> installs update_system_all.sh as sysupdate
#
# A failed download and a rejected checksum are tested here. The Docker suites
# cover a successful install, the sudo path, and idempotency.

bats_require_minimum_version 1.5.0

setup() {
  load 'helper'
}

@test "install_svcctl: info/ok write to stderr, err exits 1" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/server-scripts/install_svcctl.sh'; info hi; ok yes"
  assert_success
  assert_output ""
  [[ "${stderr}" == *hi* ]]
  [[ "${stderr}" == *yes* ]]

  run --separate-stderr bash -c "source '${REPO_ROOT}/server-scripts/install_svcctl.sh'; err boom; echo NOT_REACHED"
  assert_failure 1
  refute_output --partial "NOT_REACHED"
  [[ "${stderr}" == *boom* ]]
}

@test "install_sysupdate: info/ok write to stderr, err exits 1" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/server-scripts/install_sysupdate.sh'; info hi; ok yes"
  assert_success
  assert_output ""
  [[ "${stderr}" == *hi* ]]

  run --separate-stderr bash -c "source '${REPO_ROOT}/server-scripts/install_sysupdate.sh'; err boom; echo NOT_REACHED"
  assert_failure 1
  refute_output --partial "NOT_REACHED"
  [[ "${stderr}" == *boom* ]]
}

@test "both installers pin a syntactically valid sha256" {
  for script in install_svcctl install_sysupdate; do
    run bash -c "source '${REPO_ROOT}/server-scripts/${script}.sh'; printf '%s' \"\${EXPECTED_SHA256}\""
    assert_success
    [[ "${output}" =~ ^[[:xdigit:]]{64}$ ]]
  done
}

@test "both installers fetch from the project's raw.githubusercontent base" {
  for script in install_svcctl install_sysupdate; do
    run bash -c "source '${REPO_ROOT}/server-scripts/${script}.sh'; printf '%s' \"\${BASE_URL}\""
    assert_success
    assert_output --partial "raw.githubusercontent.com"
  done
}

@test "a failed download exits 1 and names the URL" {
  local script
  for script in install_svcctl.sh install_sysupdate.sh; do
    run --separate-stderr bash -c '
      wget() { return 8; }
      source "$1"
      main
    ' -- "${REPO_ROOT}/server-scripts/${script}"
    assert_failure 1
    [[ "${stderr}" == *"Failed to download"* ]]
    [[ "${stderr}" == *"raw.githubusercontent.com"* ]]
  done
}

@test "a downloaded file with the wrong checksum is rejected" {
  local script
  for script in install_svcctl.sh install_sysupdate.sh; do
    run --separate-stderr bash -c '
      wget() {
        local dest="" prev="" arg
        for arg in "$@"; do
          if [[ "${prev}" == "-qO" ]]; then
            dest="${arg}"
          fi
          prev="${arg}"
        done
        printf "not-the-pinned-script\n" > "${dest}"
      }
      source "$1"
      main
    ' -- "${REPO_ROOT}/server-scripts/${script}"
    assert_failure 1
    [[ "${stderr}" == *"SHA256 mismatch"* ]]
  done
}

@test "sourcing either installer does not execute main" {
  run bash -c "source '${REPO_ROOT}/server-scripts/install_svcctl.sh' && echo SOURCED"
  assert_success
  assert_output "SOURCED"

  run bash -c "source '${REPO_ROOT}/server-scripts/install_sysupdate.sh' && echo SOURCED"
  assert_success
  assert_output "SOURCED"
}
