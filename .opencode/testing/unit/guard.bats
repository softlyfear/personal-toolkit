#!/usr/bin/env bats
# Unit tests for the repository guard.
# Commit interception uses a stub gate; no git commit or destructive command is executed.

bats_require_minimum_version 1.5.0

setup() {
  load 'helper'
  source_script .opencode/hooks/guard.sh
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
  protected_config .opencode/lint.sh
  protected_config .opencode/hooks/guard.sh
  run ! protected_config server-scripts/configuring_server.sh
  run ! protected_config cli/pdf-prep/src/pdfprep/pdfdoc.py
}

@test "guard: shell writes to a protected config are caught, reads are not" {
  run writes_protected_config "sed -i 's/enable=all//' .shellcheckrc"
  assert_success
  assert_output ".shellcheckrc"
  run writes_protected_config "echo x > .opencode/lint.sh"
  assert_success
  run writes_protected_config "cat .shellcheckrc"
  assert_failure
  run writes_protected_config "bash .opencode/lint.sh 2>&1 | tail -5"
  assert_failure
  run writes_protected_config "python3 -c 'p.write_text(s)' && bash .opencode/lint.sh 2>&1"
  assert_failure
}

# run_guard <json event> [cwd] — feeds one event to guard.sh.
run_guard() {
  # shellcheck disable=SC2154 # REPO_ROOT is exported by helper.bash, loaded in setup
  local event="$1" cwd="${2:-${REPO_ROOT}}"
  if [[ ${event} != *'"cwd"'* ]]; then
    event="$(jq -c --arg cwd "${cwd}" '. + {cwd: $cwd}' <<< "${event}")"
  fi
  bash "${REPO_ROOT}/.opencode/hooks/guard.sh" <<< "${event}"
}

@test "guard: main denies a force push and lets the override through" {
  run run_guard '{"tool":"shell","command":"git push --force"}'
  assert_success
  assert_output --partial '"effect": "deny"'

  run run_guard '{"tool":"shell","command":"ALLOW_DESTRUCTIVE_GIT=1 git push --force"}'
  assert_success
  assert_output ""
}

@test "guard: main denies an edit of a protected config by absolute path" {
  run run_guard "$(jq -n --arg path "${REPO_ROOT}/.shellcheckrc" '{tool:"edit", paths:[$path]}')"
  assert_success
  assert_output --partial '"effect": "deny"'
}

@test "guard: main lets an edit of a source file through" {
  run run_guard "$(jq -n --arg path "${REPO_ROOT}/cli/pdf-prep/src/pdfprep/pdfdoc.py" '{tool:"edit", paths:[$path]}')"
  assert_success
  assert_output ""
}

@test "guard: gate configuration and the CI workflow are protected" {
  local path
  for path in .opencode/hooks/guard.sh .opencode/plugins/guard/index.ts opencode.jsonc .github/workflows/gate.yml; do
    protected_config "${path}"
    run run_guard "$(jq -n --arg command "tee ${path}" '{tool:"shell", command:$command}')"
    assert_success
    assert_output --partial '"effect": "deny"'
  done
}

@test "guard: edit targets resolve relative to the event cwd" {
  run run_guard '{"tool":"edit","paths":["../.opencode/./hooks/guard.sh"]}' "${REPO_ROOT}/server-scripts"
  assert_success
  assert_output --partial '"effect": "deny"'

  run run_guard "$(jq -n --arg path "${REPO_ROOT}/.opencode/../.shellcheckrc" '{tool:"edit", paths:[$path]}')"
  assert_success
  assert_output --partial '"effect": "deny"'
}

@test "guard: mentioning a protected path in a shell command is not a write" {
  run run_guard '{"tool":"shell","command":"echo .opencode/hooks/guard.sh"}'
  assert_success
  assert_output ""
}

@test "guard: an edit of several files returns one JSON decision" {
  local decision
  run run_guard '{"tool":"edit","paths":[".opencode/hooks/guard.sh",".shellcheckrc"]}'
  assert_success
  decision="$(jq -s 'length' <<< "${output}")"
  assert_equal "${decision}" 1
  assert_output --partial '"effect": "deny"'
}

@test "guard: commits honour the gate result from the event repository" {
  local fixture="${BATS_TEST_TMPDIR}/gate-fixture" event
  mkdir -p "${fixture}/.opencode"
  git -C "${fixture}" init -q
  event="$(jq -n --arg cwd "${fixture}" '{tool:"shell", command:"git commit -m example", cwd:$cwd}')"
  printf 'exit 1\n' > "${fixture}/.opencode/lint.sh"
  run bash "${REPO_ROOT}/.opencode/hooks/guard.sh" <<< "${event}"
  assert_success
  assert_output --partial '"effect": "deny"'

  printf 'exit 0\n' > "${fixture}/.opencode/lint.sh"
  run bash "${REPO_ROOT}/.opencode/hooks/guard.sh" <<< "${event}"
  assert_success
  assert_output ""
}
