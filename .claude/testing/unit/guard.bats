#!/usr/bin/env bats
# Unit tests for .claude/hooks/guard.sh, the Claude Code PreToolUse hook.
# The commit gate itself runs .claude/lint.sh and is not exercised here.

bats_require_minimum_version 1.5.0

setup() {
  load 'helper'
  source_script .claude/hooks/guard.sh
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
  protected_config .claude/lint.sh
  protected_config .claude/hooks/guard.sh
  run ! protected_config server-scripts/configuring_server.sh
  run ! protected_config cli/pdf-prep/src/pdfprep/pdfdoc.py
}

@test "guard: shell writes to a protected config are caught, reads are not" {
  run writes_protected_config "sed -i 's/enable=all//' .shellcheckrc"
  assert_success
  assert_output ".shellcheckrc"
  run writes_protected_config "echo x > .claude/lint.sh"
  assert_success
  run writes_protected_config "cat .shellcheckrc"
  assert_failure
  run writes_protected_config "bash .claude/lint.sh 2>&1 | tail -5"
  assert_failure
  run writes_protected_config "python3 -c 'p.write_text(s)' && bash .claude/lint.sh 2>&1"
  assert_failure
}

# run_hook <tool> <json tool_input> — feeds one hook event to guard.sh as Claude Code would.
run_hook() {
  # shellcheck disable=SC2154 # REPO_ROOT is exported by helper.bash, loaded in setup
  local repo="${REPO_ROOT}" event
  event="$(jq -n --arg tool "$1" --argjson input "$2" '{tool_name: $tool, tool_input: $input}')"
  CLAUDE_PROJECT_DIR="${repo}" bash "${repo}/.claude/hooks/guard.sh" <<< "${event}"
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
