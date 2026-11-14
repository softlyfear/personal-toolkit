#!/usr/bin/env bats

load helper

setup() {
  source_script cli/codex-auto-ping/install.sh
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

@test "Codex installer rejects API-key login without sending a model request" {
  cat > "${BATS_TEST_TMPDIR}/bin/codex" << 'EOF'
#!/usr/bin/env bash
[[ "$*" == "login status" ]] || exit 99
echo 'Logged in using an API key'
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/codex"
  run verify_login
  assert_failure
  assert_output --partial 'ChatGPT login is required'
}

@test "Codex login check drops API-key environment variables" {
  cat > "${BATS_TEST_TMPDIR}/bin/codex" << 'EOF'
#!/usr/bin/env bash
[[ -z ${OPENAI_API_KEY:-} && -z ${CODEX_API_KEY:-} ]] || exit 99
echo 'Logged in using ChatGPT' >&2
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/codex"
  export OPENAI_API_KEY=test-api-key CODEX_API_KEY=test-codex-key
  run verify_login
  assert_success
}

@test "Codex unit rendering quotes paths and escapes systemd specifiers" {
  local app_dir="${BATS_TEST_TMPDIR}/app with % signs"
  mkdir -p "${app_dir}"
  cp "${REPO_ROOT}/cli/codex-auto-ping/codex-auto-ping.service.in" "${app_dir}/"
  touch "${BATS_TEST_TMPDIR}/bin/codex" "${BATS_TEST_TMPDIR}/bin/uv"
  chmod +x "${BATS_TEST_TMPDIR}/bin/"{codex,uv}
  run render_unit "${app_dir}" "${BATS_TEST_TMPDIR}/codex-auto-ping.service"
  assert_success
  run cat "${BATS_TEST_TMPDIR}/codex-auto-ping.service"
  assert_output --partial 'app with %% signs'
  assert_output --partial 'WorkingDirectory=/'
  assert_output --partial 'Environment="CODEX_HOME='
  refute_output --partial '__DIR__'
  assert_output --partial ' run --locked main.py --codex "'
}

@test "sourcing the Codex installer does not execute main" {
  run bash -c 'source "$1"' -- "${REPO_ROOT}/cli/codex-auto-ping/install.sh"
  assert_success
  assert_output ''
}
