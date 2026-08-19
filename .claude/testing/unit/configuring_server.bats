#!/usr/bin/env bats
# Unit tests for server-scripts/configuring_server.sh.
#
# Only the deterministic, non-mutating functions are unit-tested here. Everything that
# reconfigures sshd/UFW/Fail2Ban or removes users is covered by the Docker scenario suite
# (.claude/testing/own-script/) instead — see test/README.md.

bats_require_minimum_version 1.5.0

setup() {
  load 'helper'
  source_script server-scripts/configuring_server.sh
}

# --- UI helpers -------------------------------------------------------------

@test "info/ok/warn/sep write to stderr, never stdout" {
  for fn in info ok warn; do
    run --separate-stderr bash -c "source '${REPO_ROOT}/server-scripts/configuring_server.sh'; ${fn} marker"
    assert_success
    assert_output ""
    [[ "${stderr}" == *marker* ]]
  done
  run --separate-stderr bash -c "source '${REPO_ROOT}/server-scripts/configuring_server.sh'; sep"
  assert_success
  assert_output ""
}

@test "err writes to stderr and exits 1 without continuing" {
  run --separate-stderr bash -c "source '${REPO_ROOT}/server-scripts/configuring_server.sh'; err fatal; echo NOT_REACHED"
  assert_failure 1
  refute_output --partial "NOT_REACHED"
  [[ "${stderr}" == *fatal* ]]
}

@test "sum_line/sum_item/sum_cmd/sum_note render their argument on stdout" {
  run sum_line "updated"
  assert_success
  assert_output --partial "updated"

  run sum_item "SSH" "publickey only"
  assert_success
  assert_output --partial "SSH"
  assert_output --partial "publickey only"

  run sum_cmd "ssh -p 2244 user@host"
  assert_success
  assert_output --partial "ssh -p 2244"

  run sum_note "do not close"
  assert_success
  assert_output --partial "do not close"
}

@test "usage documents the supported flags" {
  run usage
  assert_success
  assert_output --partial "--user"
  assert_output --partial "--password-file"
}

# --- Username handling ------------------------------------------------------

@test "sanitize_username_input strips CR, LF and BOM" {
  run sanitize_username_input $'admin\r\n'
  assert_success
  assert_output "admin"
}

@test "sanitize_username_input lowercases and drops disallowed characters" {
  run sanitize_username_input 'Ad!!min$42'
  assert_success
  assert_output "admin42"
}

@test "sanitize_username_input keeps underscore and hyphen" {
  run sanitize_username_input 'my_user-1'
  assert_success
  assert_output "my_user-1"
}

@test "is_reserved_username rejects root and accepts anything else" {
  run is_reserved_username root
  assert_success
  run is_reserved_username admin
  assert_failure
}

# --- Password handling ------------------------------------------------------

@test "validate_password_strength accepts a compliant password" {
  run validate_password_strength 'Str0ngP@ssword!1'
  assert_success
}

@test "validate_password_strength rejects each missing character class" {
  run validate_password_strength 'Sh0rt!'          # under 12 chars
  assert_failure
  run validate_password_strength 'alllowercase1!'  # no uppercase
  assert_failure
  run validate_password_strength 'ALLUPPERCASE1!'  # no lowercase
  assert_failure
  run validate_password_strength 'NoDigitsHere!!'  # no digit
  assert_failure
  run validate_password_strength 'NoSpecials1234'  # no special
  assert_failure
}

@test "generate_secure_password returns a password that passes its own validator" {
  run generate_secure_password
  assert_success
  [[ ${#output} -ge 12 ]]
  validate_password_strength "${output}"
}

@test "generate_secure_password falls back to /dev/urandom without openssl" {
  run bash -c "
    source '${REPO_ROOT}/server-scripts/configuring_server.sh'
    command() { [[ \"\$2\" == openssl ]] && return 1; builtin command \"\$@\"; }
    generate_secure_password
  "
  assert_success
  [[ ${#output} -ge 12 ]]
}

# --- SSH key handling -------------------------------------------------------

@test "sanitize_ssh_pubkey_line trims surrounding whitespace" {
  run sanitize_ssh_pubkey_line '   ssh-ed25519 AAAAC3Nz key@host   '
  assert_success
  assert_output "ssh-ed25519 AAAAC3Nz key@host"
}

@test "sanitize_ssh_pubkey_line removes CR and BOM" {
  run sanitize_ssh_pubkey_line $'﻿ssh-ed25519 AAAAC3Nz\r'
  assert_success
  assert_output "ssh-ed25519 AAAAC3Nz"
}

@test "sanitize_ssh_pubkey_line normalises inner spacing between type and key" {
  run sanitize_ssh_pubkey_line 'ssh-ed25519    AAAAC3Nz comment here'
  assert_success
  assert_output "ssh-ed25519 AAAAC3Nz comment here"
}

@test "looks_like_file_path recognises path-like input" {
  for candidate in '~' '~/keys/id.pub' '/etc/ssh/key.pub' './key.pub'; do
    run looks_like_file_path "${candidate}"
    assert_success
  done
}

@test "looks_like_file_path rejects a pasted key line" {
  run looks_like_file_path 'ssh-ed25519 AAAAC3Nz key@host'
  assert_failure
}

@test "expand_sshkey_path expands a bare tilde to HOME" {
  HOME=/home/tester run expand_sshkey_path '~'
  assert_success
  assert_output "/home/tester"
}

@test "expand_sshkey_path expands a tilde prefix" {
  HOME=/home/tester run expand_sshkey_path '~/.ssh/id_ed25519.pub'
  assert_success
  assert_output "/home/tester/.ssh/id_ed25519.pub"
}

@test "expand_sshkey_path leaves an absolute path untouched" {
  run expand_sshkey_path '/etc/ssh/id.pub'
  assert_success
  assert_output "/etc/ssh/id.pub"
}

@test "sshkey_file_valid accepts a real public key and rejects garbage" {
  local tmp
  tmp="$(mktemp -d)"
  ssh-keygen -q -t ed25519 -N '' -C key@host -f "${tmp}/id" < /dev/null
  printf 'not a key at all\n' > "${tmp}/junk"

  run sshkey_file_valid "${tmp}/id.pub"
  assert_success
  run sshkey_file_valid "${tmp}/junk"
  assert_failure

  rm -rf "${tmp}"
}

# --- Network / systemd probes (external commands mocked) --------------------

@test "detect_server_ip prefers the server address from SSH_CONNECTION" {
  SSH_CONNECTION="203.0.113.5 51000 198.51.100.7 22" run detect_server_ip
  assert_success
  assert_output "198.51.100.7"
}

@test "detect_server_ip falls back to a placeholder when nothing resolves" {
  run bash -c "
    source '${REPO_ROOT}/server-scripts/configuring_server.sh'
    unset SSH_CONNECTION
    command() { [[ \"\$2\" == ip || \"\$2\" == hostname ]] && return 1; builtin command \"\$@\"; }
    detect_server_ip
  "
  assert_success
  assert_output "<your-server-ip>"
}

@test "unit_exists reports on systemctl's verdict" {
  run bash -c "
    source '${REPO_ROOT}/server-scripts/configuring_server.sh'
    systemctl() { return 0; }
    unit_exists ssh.service
  "
  assert_success

  run bash -c "
    source '${REPO_ROOT}/server-scripts/configuring_server.sh'
    systemctl() { return 1; }
    unit_exists nope.service
  "
  assert_failure
}

@test "ss_listening_on_port matches only the exact port" {
  run bash -c "
    source '${REPO_ROOT}/server-scripts/configuring_server.sh'
    ss() { printf 'LISTEN 0 128 0.0.0.0:2244 0.0.0.0:*\n'; }
    ss_listening_on_port 2244
  "
  assert_success

  run bash -c "
    source '${REPO_ROOT}/server-scripts/configuring_server.sh'
    ss() { printf 'LISTEN 0 128 0.0.0.0:2244 0.0.0.0:*\n'; }
    ss_listening_on_port 22
  "
  assert_failure
}

@test "port_in_use delegates to ss_listening_on_port" {
  run bash -c "
    source '${REPO_ROOT}/server-scripts/configuring_server.sh'
    ss_listening_on_port() { [[ \"\$1\" == 2244 ]]; }
    port_in_use 2244
  "
  assert_success
}

# --- Argument parsing -------------------------------------------------------

@test "parse_cli_args rejects an invalid port" {
  run bash -c "source '${REPO_ROOT}/server-scripts/configuring_server.sh'; parse_cli_args 99999"
  assert_failure 1
}

@test "parse_cli_args rejects --user root" {
  run bash -c "source '${REPO_ROOT}/server-scripts/configuring_server.sh'; parse_cli_args --user root"
  assert_failure 1
}

@test "parse_cli_args rejects an unknown flag" {
  run bash -c "source '${REPO_ROOT}/server-scripts/configuring_server.sh'; parse_cli_args --nope"
  assert_failure 1
}

@test "parse_cli_args rejects a missing --password-file" {
  run bash -c "source '${REPO_ROOT}/server-scripts/configuring_server.sh'; parse_cli_args --password-file /nonexistent/pw"
  assert_failure 1
}

@test "parse_cli_args accepts a --confirm-window inside the allowed range" {
  run bash -c "source '${REPO_ROOT}/server-scripts/configuring_server.sh'; parse_cli_args --confirm-window 10; echo \"\${CONFIRM_WINDOW_MIN}\""
  assert_success
  assert_output "10"
}

@test "parse_cli_args leaves the auto-revert disabled by default" {
  run bash -c "source '${REPO_ROOT}/server-scripts/configuring_server.sh'; parse_cli_args 2255; echo \"\${CONFIRM_WINDOW_MIN}\""
  assert_success
  assert_output "0"
}

@test "parse_cli_args rejects a --confirm-window below the minimum" {
  run bash -c "source '${REPO_ROOT}/server-scripts/configuring_server.sh'; parse_cli_args --confirm-window 1"
  assert_failure 1
}

@test "parse_cli_args rejects a --confirm-window above the maximum" {
  run bash -c "source '${REPO_ROOT}/server-scripts/configuring_server.sh'; parse_cli_args --confirm-window 2000"
  assert_failure 1
}

@test "parse_cli_args rejects a non-numeric --confirm-window" {
  run bash -c "source '${REPO_ROOT}/server-scripts/configuring_server.sh'; parse_cli_args --confirm-window soon"
  assert_failure 1
}

# --- UFW rule ownership -----------------------------------------------------

@test "ufw_rule_is_ours claims LIMIT rules left on another port" {
  run ufw_rule_is_ours 2244 LIMIT 2255
  assert_success
}

@test "ufw_rule_is_ours claims the blanket ALLOW on 22" {
  run ufw_rule_is_ours 22 ALLOW 2244
  assert_success
}

@test "ufw_rule_is_ours disclaims an operator ALLOW rule" {
  for port in 80 443 8080; do
    run ufw_rule_is_ours "${port}" ALLOW 2244
    assert_failure
  done
}

@test "ufw_rule_is_ours never claims the port being configured" {
  run ufw_rule_is_ours 2244 LIMIT 2244
  assert_failure
  run ufw_rule_is_ours 22 ALLOW 22
  assert_failure
}

@test "sourcing the script does not execute main" {
  run bash -c "source '${REPO_ROOT}/server-scripts/configuring_server.sh' && echo SOURCED"
  assert_success
  assert_output "SOURCED"
}
