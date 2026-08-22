# Bash: project standards

Target environment: Bash 5.x on Ubuntu (latest LTS). Executable scripts use
`#!/usr/bin/env bash`. `#!/bin/sh` is only for genuinely POSIX code, verified with
`checkbashisms`.

Enforced by `.claude/lint.sh`, which is the single source of truth for "does this pass".

## Tooling (the only permitted set)

| Tool | Purpose | Invocation |
|---|---|---|
| shellcheck | linting, mandatory | `shellcheck -x -S style` |
| shfmt | formatting | `shfmt -i 2 -ci -bn -sr` |
| bats-core (+ bats-support, bats-assert) | tests | `bats .claude/testing/unit/` |
| shellharden | one-off mass quoting of legacy code only | — |
| checkbashisms | only for files with a `/bin/sh` shebang | — |

Coverage tooling (kcov/bashcov) is not used on Windows.

Config lives in `.shellcheckrc` (`enable=all`), `.editorconfig` and `.gitattributes`.

## Mandatory rules (a violation is a bug)

1. Prologue of an executable script: `set -euo pipefail` and `IFS=$'\n\t'`.
2. Every expansion quoted: `"${var}"`, `"${arr[@]}"`, `"$(cmd)"`.
3. `[[ ... ]]` for conditions, `(( ... ))` for arithmetic, `$(...)` instead of backticks.
4. Inside functions every variable is `local`. Assignment from a command substitution is
   declared separately: `local x; x=$(cmd)` — otherwise the exit code is lost.
5. Data goes to stdout, diagnostics and logs to stderr, the outcome is the exit code.
6. Cleanup through a trap: `tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT`.
7. `cd "$dir" || return 1`, or a subshell: `( cd "$dir" && ... )`.
8. Read line by line only as: `while IFS= read -r line; do ...; done < "$file"`.
9. File lists via arrays/globs or `find -print0` + `read -r -d ''`.
10. Constants: `readonly` / `declare -r`, UPPER_CASE. Functions: lower_snake_case.
11. Comments earn their place or they go. Write a comment only for a *why* the code cannot
    show: a non-obvious constraint, an ordering requirement, a trap that already cost a
    bug. Never restate what the line does, never narrate a change, never leave commentary
    about the work. One line where one line does; a paragraph only for a real trap.

### Note on rule 6 and the single EXIT slot

A shell has one EXIT trap. `configuring_server.sh` spends it on `rollback_on_failure`, so a
second `trap ... EXIT` for a temp file would *replace* the rollback handler and silently
disable it. Its four `mktemp` sites therefore clean up with an explicit `rm -f` on every
branch — including before each `err` — instead of a trap. Keep it that way.

A RETURN trap set inside a function stays installed after that function returns and fires
again when the caller returns. If you use one, make it clear itself:
`trap 'rm -f "${tmp:-}"; trap - RETURN' RETURN`.

State consumed by a trap must outlive the function that set it. `install_svcctl.sh` and
`install_sysupdate.sh` declare `tmp_file`/`staged_file` at file scope for that reason: their
EXIT trap runs after `main` has returned, when `main`'s locals no longer exist. This is the
documented exception to rule 4.

### Note on rule 1 and `IFS`

Setting `IFS=$'\n\t'` changes word splitting for code that was written under the default
`IFS`. Two consequences already hit this repository, so check for both when adding code:

- **Any `read` that fills more than one variable splits on `IFS`** — both
  `read -r -a parts` and plain `read -r a b`. Under `IFS=$'\n\t'` a space-separated value
  lands entirely in the first variable and the rest come back empty, with no error. Set it
  on the command: `IFS=' ' read -r -a parts <<< "${value}"`, `IFS=' ' read -r a b <<< "${s}"`.
  This bit twice here: `SSH_CONNECTION` parsing in the xrdp scripts, and `<tag> <cname>`
  parsing in 15 places across the test harness.
- `"${arr[*]}"` joins on the FIRST character of `IFS`, a newline here. Never use
  `[[ " ${arr[*]} " == *" x "* ]]` for membership (use a loop) and never interpolate an
  array straight into a message (use a space-scoped join helper).
- Sourcing a script from a test leaks its `IFS` into the test runner and breaks bats'
  failure reporting. `.claude/testing/unit/helper.bash` restores the default after sourcing.

## Structure

**This repository is an explicit exception to the usual `bin/` + `lib/` layout.**

Scripts in `server-scripts/` and `dev-tools/` are fetched and executed one file at a time,
straight from `raw.githubusercontent.com`:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/configuring_server.sh)
```

Nothing is cloned, so a `source "${SCRIPT_DIR}/../lib/log.sh"` would fail at run time on
every target machine. Therefore:

- Scripts stay **single-file and self-contained**. No sourcing of sibling files, no
  relative-path dependencies, no assumption about the working directory.
- Shared helpers (`info`/`ok`/`warn`/`err`) are duplicated per file on purpose.
- Interactive prompts read from `/dev/tty`, never stdin — stdin belongs to the
  `bash <(wget ...)` process substitution.

What is kept from the original structure rule:

- **Main-guard** — every script ends with

  ```bash
  if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
  fi
  ```

  so `.claude/testing/unit/*.bats` can `source` the file, reach its functions, and never run `main`.
- **No side effects at source time.** Everything that acts on the system lives inside
  `main`, including trap registration. `configuring_server.sh` registers
  `trap rollback_on_failure EXIT` inside `main` for exactly this reason.

### Repository root holds shipped scripts only

The root contains the scripts that are actually delivered to a target machine, plus
documentation and the tool dotfiles that must live there (`.shellcheckrc`, `.editorconfig`,
`.gitattributes`). Development and test tooling goes under `.claude/` — the quality gate is
`.claude/lint.sh`, the tests are in `.claude/testing/`. Do not add a `scripts/`, `test/`, or
similar tooling directory to the root.

### All tests live under `.claude/testing/`

There is no top-level `test/` directory and nothing test-related belongs in the repository
root. Every test in this project goes under one root:

```
.claude/testing/
├── unit/               bats-core unit tests + vendored test_helper/
├── own-script/         Docker scenarios for configuring_server.sh
├── devsetup/           Docker scenarios for install-dev-tools.sh
├── svcctl/             Docker scenarios for service-manager.sh + install_svcctl.sh
├── sysupdate/          Docker scenarios for update_system_all.sh + install_sysupdate.sh
└── xrdp/               Docker scenarios for add_xfce_xrdp.sh / add_gnome_xrdp.sh
```

Scenario suites are named after the script under test; `unit/` is named after its scope
because its tests span every script. When adding tests: pure logic goes in
`.claude/testing/unit/<script>.bats`, anything that mutates a system goes in the matching
scenario suite — create `.claude/testing/<script-name>/` if none exists yet, following an
existing suite's `run.sh` / `lib.sh` / `scenarios.sh` / `images/` layout.

`.claude/testing/` is also the one place where sourcing siblings is fine — it is Claude
Code's own tooling, runs only inside Docker, and is never piped from the web. Nothing here
ships to a target machine, so the single-file constraint above does not apply.

## Testability

- A function takes input as arguments and returns its result on stdout or through a
  nameref (`local -n`).
- External commands are injected as variables (`: "${CURL:=curl}"`, called as `"${CURL}"`)
  or shadowed by a function in the test.
- Global state is limited to readonly configuration declared in one place.
- Functions that mutate the system (apt, systemctl, ufw, userdel) are **not** unit-tested;
  they are covered by the Docker scenario suites in `.claude/testing/`. See
  `.claude/testing/unit/README.md` for the split.

## Errors

- `die() { printf 'error: %s\n' "$*" >&2; exit 1; }` — in this repository the equivalent
  is the shared `err()` helper, which also exits 1.
- A function validates its contract on entry: argument count, readability of paths.
- Exit code 2 for a usage error, 1 for a runtime error.

## Suppressions

Global disables in `.shellcheckrc` are forbidden. A finding is either fixed or suppressed
with a per-line directive carrying its reason on the same line:

```bash
# shellcheck disable=SC2310 # predicate; its return code is handled by this conditional
if ! unit_exists ssh.socket; then
```

ShellCheck itself rejects a directive placed in front of an `elif`, a `case` branch, or a
closing `}`/`done` (SC1123/SC1124). In those three positions the directive goes in front of
the enclosing compound command instead — still scoped, never file-global.

## Applicability boundary

A script longer than ~100 lines, or one with non-trivial control flow, nested data
structures, JSON parsing beyond a single `jq` query, parallelism with synchronisation, or
floating-point arithmetic, should be rewritten in Python/Go, with Bash left as the glue
layer.

This repository knowingly violates that boundary — see the "Applicability boundary" section
of the audit in `.claude/testing/unit/README.md` for the file-by-file position. The constraint above
(single-file delivery over wget) is what keeps them in Bash.

## Forbidden

- Disabling shellcheck checks globally.
- Logging to stdout from a function whose output is consumed as data.
- Relying on `set -e` inside `if` / `&&` / `||` / `!` or in an assignment from a command
  substitution — check exit codes explicitly.
