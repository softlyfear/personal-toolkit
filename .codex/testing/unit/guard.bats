#!/usr/bin/env bats
# Unit tests for the Codex guard.
# Commit interception uses a stub gate; no git commit or destructive command is executed.

bats_require_minimum_version 1.5.0

setup() {
  load 'helper'
  source_script .codex/hooks/guard.sh
}

@test "guard: git commands with no undo are recognised" {
  local cmd
  for cmd in \
    "git push --force origin main" \
    "git push -f" \
    "git push --force-with-lease=main:abc origin main" \
    "git push origin +main" \
    "cd repo && git reset --hard HEAD~1" \
    "git clean -fdx" \
    "git branch -D old" \
    "git checkout -- ." \
    "git restore ." \
    "git -C /tmp/x filter-branch --msg-filter cat -- main" \
    "git stash drop"; do
    run destructive_git_reason "${cmd}"
    assert_success
    [[ -n ${output} ]] || fail "not recognised: ${cmd}"
  done
}

@test "guard: everyday git commands pass" {
  local cmd
  for cmd in \
    "git push -q origin main" \
    "git reset --soft HEAD~1" \
    "git checkout main" \
    "git restore --staged file.py" \
    "git branch -d merged" \
    "git stash pop" \
    "git log --format=%h -- ." \
    "grep -rn 'push --force' docs/"; do
    run destructive_git_reason "${cmd}"
    assert_success
    assert_output ""
  done
}

@test "guard: git commit is detected, other commit-like words are not" {
  is_git_commit "git commit -q -F -"
  is_git_commit "git add a && git commit -m x"
  is_git_commit "git -C repo commit --amend"
  run ! is_git_commit "git log --grep commit"
  run ! is_git_commit "echo git commit-tree"
}

@test "guard: gate and hook configs are protected, source files are not" {
  protected_config .shellcheckrc
  protected_config .codex/lint.sh
  protected_config .codex/hooks/guard.sh
  run ! protected_config server-scripts/configuring_server.sh
  run ! protected_config cli/pdf-prep/src/pdfprep/pdfdoc.py
}

@test "guard: shell writes to a protected config are caught, reads are not" {
  run writes_protected_config "sed -i 's/enable=all//' .shellcheckrc"
  assert_success
  assert_output ".shellcheckrc"
  run writes_protected_config "echo x > .codex/lint.sh"
  assert_success
  run writes_protected_config "cat .shellcheckrc"
  assert_failure
  run writes_protected_config "bash .codex/lint.sh 2>&1 | tail -5"
  assert_failure
  run writes_protected_config "python3 -c 'p.write_text(s)' && bash .codex/lint.sh 2>&1"
  assert_failure
}

# run_hook <tool> <json tool_input> — feeds one hook event to guard.sh with its repository cwd.
run_hook() {
  # shellcheck disable=SC2154 # REPO_ROOT is exported by helper.bash, loaded in setup
  local repo="${REPO_ROOT}" event
  event="$(jq -n --arg tool "$1" --argjson input "$2" --arg cwd "${repo}" '{tool_name: $tool, tool_input: $input, cwd: $cwd}')"
  bash "${repo}/.codex/hooks/guard.sh" <<< "${event}"
}

@test "guard: main denies a force push and lets the override through" {
  run run_hook Bash '{"command": "git push --force"}'
  assert_success
  assert_output --partial '"permissionDecision": "deny"'

  run run_hook Bash '{"command": "ALLOW_DESTRUCTIVE_GIT=1 git push --force"}'
  assert_success
  assert_output ""
}

@test "guard: main denies an Edit of a protected config by absolute path" {
  run run_hook Edit "{\"file_path\": \"${REPO_ROOT}/.shellcheckrc\"}"
  assert_success
  assert_output --partial '"permissionDecision": "deny"'
}

@test "guard: main lets an Edit of a source file through" {
  run run_hook Edit "{\"file_path\": \"${REPO_ROOT}/cli/pdf-prep/src/pdfprep/pdfdoc.py\"}"
  assert_success
  assert_output ""
}

run_codex_hook() {
  local event
  event="$(jq -n --arg tool "$1" --argjson input "$2" --arg cwd "${3:-${REPO_ROOT}}" \
    '{tool_name: $tool, tool_input: $input, cwd: $cwd}')"
  bash "${REPO_ROOT}/.codex/hooks/guard.sh" <<< "${event}"
}

@test "guard: Codex configuration and CI gate are protected" {
  local path
  for path in .codex/config.toml .codex/hooks.json .codex/hooks/guard.sh .github/workflows/gate.yml; do
    protected_config "${path}"
    run run_codex_hook Bash "{\"command\": \"tee ${path}\"}"
    assert_success
    assert_output --partial '"permissionDecision": "deny"'
  done
}

@test "guard: Codex patch add, update, delete and rename targets are protected" {
  local operation patch input
  for operation in 'Add File' 'Update File' 'Delete File' 'Move to'; do
    patch="$(printf '*** Begin Patch\n*** %s: .codex/hooks.json\n*** End Patch' "${operation}")"
    input="$(jq -n --arg command "${patch}" '{command: $command}')"
    run run_codex_hook apply_patch "${input}"
    assert_success
    assert_output --partial '"permissionDecision": "deny"'
  done
}

@test "guard: Codex patches resolve paths relative to the event cwd" {
  local input
  input="$(jq -n --arg command $'*** Begin Patch\n*** Delete File: ../.codex/./hooks.json\n*** End Patch' '{command: $command}')"
  run run_codex_hook apply_patch "${input}" "${REPO_ROOT}/server-scripts"
  assert_success
  assert_output --partial '"permissionDecision": "deny"'

  input="$(jq -n --arg command "*** Update File: ${REPO_ROOT}/.codex/../.shellcheckrc" '{command: $command}')"
  run run_codex_hook apply_patch "${input}"
  assert_success
  assert_output --partial '"permissionDecision": "deny"'
}

@test "guard: Codex source patches can mention protected paths without being denied" {
  local input
  input="$(jq -n --arg command $'*** Begin Patch\n*** Update File: server-scripts/example.sh\n@@\n+echo .codex/hooks.json\n*** End Patch' '{command: $command}')"
  run run_codex_hook apply_patch "${input}"
  assert_success
  assert_output ""
}

@test "guard: a patch touching multiple protected files returns one JSON decision" {
  local input decision
  input="$(jq -n --arg command $'*** Begin Patch\n*** Delete File: .codex/hooks.json\n*** Delete File: .shellcheckrc\n*** End Patch' '{command: $command}')"
  run run_codex_hook apply_patch "${input}"
  assert_success
  decision="$(jq -s 'length' <<< "${output}")"
  assert_equal "${decision}" 1
  assert_output --partial '"permissionDecision": "deny"'
}

@test "guard: commits honour the gate result from the event repository" {
  local fixture="${BATS_TEST_TMPDIR}/gate-fixture" event
  mkdir -p "${fixture}/.codex"
  git -C "${fixture}" init -q
  event="$(jq -n --arg cwd "${fixture}" '{tool_name:"Bash",tool_input:{command:"git commit -m example"},cwd:$cwd}')"
  printf 'exit 1\n' > "${fixture}/.codex/lint.sh"
  run bash "${REPO_ROOT}/.codex/hooks/guard.sh" <<< "${event}"
  assert_success
  assert_output --partial '"permissionDecision": "deny"'

  printf 'exit 0\n' > "${fixture}/.codex/lint.sh"
  run bash "${REPO_ROOT}/.codex/hooks/guard.sh" <<< "${event}"
  assert_success
  assert_output ""
}
