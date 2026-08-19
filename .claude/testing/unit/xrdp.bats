#!/usr/bin/env bats
# Unit tests shared by server-scripts/add_xfce_xrdp.sh and add_gnome_xrdp.sh.
#
# Everything that installs a desktop environment, edits PAM or touches UFW is covered by
# the Docker suite (.claude/testing/xrdp) — see test/README.md.

bats_require_minimum_version 1.5.0

setup() {
  load 'helper'
}

xrdp_scripts() {
  printf '%s\n' server-scripts/add_xfce_xrdp.sh server-scripts/add_gnome_xrdp.sh
}

@test "both scripts: info/ok/warn write to stderr, never stdout" {
  while read -r script; do
    for fn in info ok warn; do
      run --separate-stderr bash -c "source '${REPO_ROOT}/${script}'; ${fn} marker"
      assert_success
      assert_output ""
      [[ "${stderr}" == *marker* ]]
    done
  done < <(xrdp_scripts)
}

@test "both scripts: err writes to stderr and exits 1" {
  while read -r script; do
    run --separate-stderr bash -c "source '${REPO_ROOT}/${script}'; err fatal; echo NOT_REACHED"
    assert_failure 1
    refute_output --partial "NOT_REACHED"
    [[ "${stderr}" == *fatal* ]]
  done < <(xrdp_scripts)
}

@test "setup_sudo leaves SUDO empty when running as root" {
  while read -r script; do
    run bash -c "
      source '${REPO_ROOT}/${script}'
      id() { [[ \"\$1\" == -u ]] && { echo 0; return 0; }; builtin command id \"\$@\"; }
      setup_sudo
      printf '[%s]' \"\${SUDO}\"
    "
    assert_success
    assert_output "[]"
  done < <(xrdp_scripts)
}

@test "setup_sudo selects sudo when running as non-root with sudo present" {
  while read -r script; do
    run bash -c "
      source '${REPO_ROOT}/${script}'
      id() { [[ \"\$1\" == -u ]] && { echo 1000; return 0; }; builtin command id \"\$@\"; }
      setup_sudo
      printf '[%s]' \"\${SUDO}\"
    "
    assert_success
    assert_output "[sudo]"
  done < <(xrdp_scripts)
}

@test "setup_sudo fails when non-root and sudo is missing" {
  while read -r script; do
    run bash -c "
      source '${REPO_ROOT}/${script}'
      id() { [[ \"\$1\" == -u ]] && { echo 1000; return 0; }; builtin command id \"\$@\"; }
      command() { [[ \"\$2\" == sudo ]] && return 1; builtin command \"\$@\"; }
      setup_sudo
    "
    assert_failure 1
  done < <(xrdp_scripts)
}

@test "wait_for_dpkg_lock returns immediately when fuser is unavailable" {
  while read -r script; do
    run bash -c "
      source '${REPO_ROOT}/${script}'
      command() { [[ \"\$2\" == fuser ]] && return 1; builtin command \"\$@\"; }
      wait_for_dpkg_lock
    "
    assert_success
  done < <(xrdp_scripts)
}

@test "RDP_PORT is pinned to 3389 in both scripts" {
  while read -r script; do
    run bash -c "source '${REPO_ROOT}/${script}'; printf '%s' \"\${RDP_PORT}\""
    assert_success
    assert_output "3389"
  done < <(xrdp_scripts)
}

@test "PAM root-deny rule is the same in both scripts" {
  while read -r script; do
    run bash -c "source '${REPO_ROOT}/${script}'; printf '%s' \"\${PAM_ROOT_DENY}\""
    assert_success
    assert_output --partial "user != root"
  done < <(xrdp_scripts)
}

@test "sourcing either script does not execute main" {
  while read -r script; do
    run bash -c "source '${REPO_ROOT}/${script}' && echo SOURCED"
    assert_success
    assert_output "SOURCED"
  done < <(xrdp_scripts)
}
