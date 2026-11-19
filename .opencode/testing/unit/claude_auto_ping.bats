#!/usr/bin/env bats

load helper

setup() {
  source_script cli/claude-auto-ping/install.sh
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

@test "Claude unit rendering quotes paths and escapes systemd specifiers" {
  local app_dir="${BATS_TEST_TMPDIR}/app with % signs"
  mkdir -p "${app_dir}"
  cp "${REPO_ROOT}/cli/claude-auto-ping/claude-auto-ping.service.in" "${app_dir}/"
  printf '%s\n' '#!/bin/sh' > "${BATS_TEST_TMPDIR}/bin/uv"
  printf '%s\n' '#!/bin/sh' > "${BATS_TEST_TMPDIR}/bin/claude"
  chmod +x "${BATS_TEST_TMPDIR}/bin/uv" "${BATS_TEST_TMPDIR}/bin/claude"
  run render_unit "${app_dir}" "${BATS_TEST_TMPDIR}/claude-auto-ping.service"
  assert_success
  run cat "${BATS_TEST_TMPDIR}/claude-auto-ping.service"
  assert_output --partial 'app with %% signs'
  assert_output --partial 'WorkingDirectory=/'
  assert_output --partial 'ExecStart="'
  refute_output --partial '__DIR__'
  refute_output --partial '__UV__'
  refute_output --partial '__PATH_ENV__'
}

@test "Claude token file reader strips CR and surrounding whitespace" {
  printf '  token-value\r\n' > "${BATS_TEST_TMPDIR}/oauth-token"
  run read_token_file "${BATS_TEST_TMPDIR}/oauth-token"
  assert_success
  assert_output "token-value"
}

@test "Claude login failure classifier accepts only auth refusals" {
  run login_failure_is_auth "Not logged in. Run /login"
  assert_success
  run login_failure_is_auth "usage limit reached"
  assert_failure
}

@test "sourcing the Claude installer does not execute main" {
  run bash -c 'source "$1"' -- "${REPO_ROOT}/cli/claude-auto-ping/install.sh"
  assert_success
  assert_output ''
}
