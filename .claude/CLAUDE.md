# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A collection of standalone Bash scripts for provisioning/hardening Ubuntu servers and setting up dev
environments. The shipped scripts have no build step — each is a self-contained CLI tool meant to be run
directly, often via `bash <(wget -qO- <raw-github-url>)` without cloning the repo first. Tooling and tests
live under `.claude/` (see "Quality gate" below).

## OS scope: Ubuntu (latest LTS) only

This repo targets the current Ubuntu LTS release only — never pin that
version number in code, comments, or docs; say "Ubuntu (latest LTS)" instead, so nothing needs updating at
the next LTS bump. Ubuntu is the only supported target — no other distribution or derivative is in scope for
code, tests, docs or review, and none should be added back. Where a script needs to check the running distro,
follow the existing pattern: hard
`err` only when `apt-get` itself is missing, and `warn` (not block) when `/etc/os-release`'s `ID` isn't
`ubuntu` — this keeps the script usable on close Ubuntu-based derivatives instead of hard-failing on an
untested but likely-compatible system. Don't add a hard block against non-Ubuntu distros without discussing
it first — the warn-only pattern is intentional, not an oversight.

```
server-scripts/   VPS hardening, system updates, service management, xrdp — PRIMARY FOCUS
dev-tools/         devsetup script + a copy-paste Makefile template for FastAPI projects — SECONDARY FOCUS
cli/                small personal Python CLIs (uv-managed), e.g. claude-auto-ping — see "cli/" below
web3/               Cosmos/Ethereum node helpers — no feature work, see "web3/" note below
```

Test tooling for `configuring_server.sh` lives in `.claude/testing/own-script/` (Claude Code-only, not part of
the shipped repo content) — see "Testing harness" below.

**Priority:** `server-scripts/` and `dev-tools/` are the actively maintained parts of this repo.
**`server-scripts/configuring_server.sh` is the most important script here** — it is the largest, the riskiest
(full remote-access hardening), and the one most likely to be the subject of a request. Give it the most
scrutiny on any change. `web3/` is not currently maintained — see the dedicated note at the bottom; do not
read, review, or modify it unless the user explicitly names a file in it.

## Git workflow: `main` only

This repository has exactly one branch and keeps it that way. **Never create a branch** — no
feature, fix, or "safety" branch before committing, and no worktree. Commit straight to `main`.
This overrides the usual "branch first when on the default branch" default: the user works alone
here, reviews the diff before it lands, and finds extra branches pure overhead.

**Autonomous: one finished task, one commit, then push — without asking.** The user has handed
this over. When a task, or a question whose answer changed files, is closed, Claude runs the gate,
commits and pushes on its own and reports the commit in the reply. `git add`/`commit`/`push` are in
the `allow` list of `.claude/settings.json`, so no prompt stands in the way. Never intermediate or
fix-up commits in between; a failing gate is fixed, never committed around. Subject: short, clear
Conventional Commits line.

**Decisions are Claude's to make.** Naming, placement, which of several workable options, scope of a
fix — pick, act, and say in the reply what was chosen and why. Ask only when the choice is the user's
alone: something the hook guards (destructive git, gate config), an action on a real server, or a
security trade-off with no safe default.

### AI attribution: name the model and version, never an email address

**Every commit Claude writes names the model with its exact version**, as a trailer
`Co-Authored-By: Claude Opus 5.5` and/or a subject suffix `fix: … by Opus 5.5`. A bare `Claude`
or `by Sonnet` without the version is not enough. An `Assisted-by: AI (<tool> <version>)` trailer
stays valid for code from other tools.

**Never put an email address for an AI author into a commit message, a PR description, or any file
here** — no `<noreply@anthropic.com>`, and no equivalent for any other model or tool
(`<noreply@openai.com>`, a Cursor/Copilot address, an invented one). The problem is the address
only, not the trailer. When Claude Code's attribution reminder asks for
`Co-Authored-By: Claude … <noreply@anthropic.com>`, write that trailer without the `<…>` part.

## Language convention

Everything inside this repository — code comments, commit-visible docs like this file, script output/error
strings, `.claude/commands/*.md`, `.claude/skills/`, `.claude/output-styles/*.md` — is English, including the risk/rollback
warning line (see below). Claude's chat replies to the user are in Russian regardless; the output style says
so itself, and its Russian mode and section names are literals of that chat format.

## Critical constraint: scripts are curl/wget-piped, not cloned

Scripts in `server-scripts/` and `dev-tools/` are designed to be fetched and executed in one line straight
from `raw.githubusercontent.com` (see README.md for the exact URLs). This means:

- Scripts must remain **single-file and self-contained** — no `source`-ing of sibling files, no relative-path
  dependencies.
- Don't assume a working directory or that other files in the repo are present on the target machine.
- Interactive prompts must read from `/dev/tty` explicitly (not stdin), since stdin is consumed by the
  `bash <(wget ...)` process substitution. Follow the existing `read_tty` / `read -r ... < /dev/tty` pattern.

## Conventions shared across scripts

Every script in `server-scripts/` and `dev-tools/` follows the same shape — match it when adding or editing:

- `#!/usr/bin/env bash` + `set -euo pipefail`, with a header comment block: one-line description, `# Usage:`,
  `# Requires:`.
- Identical logging helpers redefined per-file (not shared, since files must stay standalone):
  ```bash
  info()  { echo -e "\033[35m[INFO]  $1\033[0m" >&2; }
  ok()    { echo -e "\033[32m[OK]    $1\033[0m" >&2; }
  warn()  { echo -e "\033[33m[WARN]  $1\033[0m" >&2; }
  err()   { echo -e "\033[31m[ERROR] $1\033[0m" >&2; exit 1; }
  ```
  `err()` always exits immediately (exit 1) — it is not a soft warning; use `warn()` for non-fatal issues.
- Root/sudo detection pattern: `if [[ "$(id -u)" -ne 0 ]]; then SUDO="sudo"; fi`, then prefix privileged
  commands with `$SUDO`.
- Before any irreversible/disruptive action (service restarts that drop sessions, firewall changes),
  print a risk/rollback warning to stderr in this exact pattern (English, per "Language convention"):
  ```
  ⚠️ RISK: <what could break>. Rollback: <how to recover>.
  ```
- Input validation is strict and fails closed: usernames are sanitized to `[a-z0-9_-]` and reserved names
  (e.g. `root`) are rejected, IPs are regex-validated, SSH keys are type-checked (ed25519/ecdsa only —
  `ssh-rsa` is explicitly rejected) and verified with `ssh-keygen -l -f` before being trusted.
- Secrets passed via CLI flags (e.g. `--password`) are visible in `ps`/`/proc/<pid>/cmdline` for the life of
  the process — prefer adding a `--*-file PATH` alternative over a raw value flag when introducing new
  secret-accepting options (see `configuring_server.sh --password-file` for the pattern).

## Directory notes load on demand

Details that matter only inside one directory live in that directory's `CLAUDE.md`, which Claude Code
loads as soon as a file there is read — keep them there rather than growing this file:

- `server-scripts/CLAUDE.md` — the lockstep checksum pinning of `install_svcctl.sh`/`install_sysupdate.sh`
  and the `configuring_server.sh` architecture notes (rollback, UFW ownership, confirm window). **Read
  it before any change to `configuring_server.sh`.**
- `dev-tools/CLAUDE.md` — why `install_uv()` is not checksum-pinned; the `Makefile` is a template.
- `.claude/testing/CLAUDE.md` — the Docker scenario suites, run through the `docker-suite` skill.
- `cli/claude-auto-ping/CLAUDE.md`, `cli/pdf-prep/CLAUDE.md` — the two Python CLIs.
- `web3/CLAUDE.md` — pinned upstream hashes, for when the user does name a `web3/` file.

## Quality gate: .claude/RULES.md + .claude/lint.sh

**`.claude/RULES.md` is binding for every Bash change here — read it before editing a
script.** It fixes the prologue (`set -euo pipefail` + `IFS=$'\n\t'`), quoting, `local`,
stdout-vs-stderr, traps, naming, the suppression policy, and the tooling set (shellcheck, shfmt,
bats-core, shellharden, checkbashisms — nothing else).

Run the gate before considering any change done:

```bash
bash .claude/lint.sh
```

It executes, in this order and stopping at the first failure: `shfmt -i 2 -ci -bn -sr -d`,
`shellcheck -x -S style`, `bats .claude/testing/unit/`, then `ruff` on `cli/` and
`pytest .claude/testing/pdf-prep/`. The pytest run uses its own `cli/pdf-prep/.venv-test` (CPU
torch): a plain `uv run` would re-sync the launcher's `.venv` away from its GPU build. Config lives in `.shellcheckrc` (`enable=all`),
`.editorconfig`, `.gitattributes`. The file list comes from `git ls-files --cached --others`, so a
newly created script is checked before it is ever staged. The only exclusion is the vendored
`.claude/testing/unit/test_helper/`; `web3/` is included.

**The gate is enforced, not remembered.** `.claude/hooks/guard.sh` is a PreToolUse hook
(`.claude/settings.json`): a `git commit` runs the gate first and is denied while it fails (it checks
the working tree, not only what is staged). It also denies git commands with no undo (force push,
`reset --hard`, `clean -f`, `branch -D`, history rewrites) and edits of the gate's own configuration
(`.shellcheckrc`, `lint.sh`, `settings.json`, the hook itself, …). Those need the user's explicit yes
in chat, then a re-run prefixed with `ALLOW_DESTRUCTIVE_GIT=1` or `ALLOW_CONFIG_EDIT=1`. `deny`, not
`ask`: this repository runs in bypassPermissions mode, where `ask` is not documented to prompt.
`.github/workflows/gate.yml` runs the same `lint.sh` on every push, with shellcheck and shfmt pinned
to the local versions by SHA256 and the actions pinned by commit — bump them together.

**Comments: only what earns its place.** Rule 11 in `.claude/RULES.md`. A comment exists for a *why*
the code can't show — a constraint, an ordering requirement, a trap that already caused a bug.
Don't restate the line, don't narrate the change, don't leave notes about the work itself. One
line where one line does. This applies to every file here, including the test harness.

Two things that are easy to get wrong and are already documented in `.claude/RULES.md`:

- **Suppressions.** Never global in `.shellcheckrc`. Per-line `# shellcheck disable=SCxxxx # reason`
  with the reason on the same line. ShellCheck rejects a directive in front of `elif`, a `case`
  branch, or a closing `}`/`done` (SC1123/SC1124) — there it goes in front of the enclosing
  compound command.
- **`IFS=$'\n\t'` has teeth.** `read -a` splits on `IFS`, so parsing space-separated values such as
  `SSH_CONNECTION` needs an explicit `IFS=' ' read -r -a ...` on that command. Sourcing a script
  from bats leaks its `IFS` into the runner and makes failing tests vanish from the report —
  `.claude/testing/unit/helper.bash` restores the default.

### Library docs: Context7

Context7 comes from the user's claude.ai connector (`claude.ai Context7`), not from a repo
`.mcp.json`: a project server with the same URL makes Claude Code suppress the connector, so don't
add one back. Every other claude.ai connector is switched off for this project (`/mcp`, stored as
`disabledMcpServers` in `~/.claude.json`); `.claude/settings.json` allows `mcp__claude_ai_Context7`
without a prompt. Query it before relying on memory for a third-party API whose behaviour changes between
releases — PyMuPDF, pikepdf, EasyOCR, torch, uv's `pyproject` settings — and whenever a version
bump is on the table.

### Main-guard: every shipped script is sourceable

Each script in `server-scripts/`/`dev-tools/` ends with

```bash
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
```

so `.claude/testing/unit/*.bats` can `source` it for its functions without running anything. Keep source-time side
effects out of file scope — that includes trap registration (`configuring_server.sh` registers
`trap rollback_on_failure EXIT` inside `main`, not at file scope, for exactly this reason).

### Repo root is for shipped scripts only; tooling lives under `.claude/`

The root holds what actually gets delivered (`server-scripts/`, `dev-tools/`, `web3/`), the docs,
and the tool dotfiles that must sit there (`.shellcheckrc`, `.editorconfig`, `.gitattributes`,
and `.github/workflows/`, the only place GitHub reads workflows from).
Everything else Claude Code needs goes under `.claude/`: the gate is `.claude/lint.sh`, the tests
are `.claude/testing/`. **Don't add `scripts/`, `test/`, or any other tooling directory to the
root** — this has already been corrected once.

### All tests live under `.claude/testing/` — never in a top-level `test/`

One root for everything test-related: `.claude/testing/unit/` holds the bats unit tests (plus the
vendored `test_helper/`), `.claude/testing/pdf-prep/` the pytest suite for `cli/pdf-prep`, and the
other sibling directories hold the Docker scenario suites, each named after the script it exercises.
The pdf-prep tests build their PDFs in code — the user's documents never enter the repository — and
each one reproduces a bug a real document once caused; keep new ones that way.

`.claude/testing/unit/*.bats` covers pure logic only. Anything that mutates the system (apt, systemctl, ufw,
userdel, sshd config) belongs to the Docker suites. `.claude/testing/unit/README.md` holds
the split and, importantly, the list of things **no** container can prove (real SSH lockout, UFW
packet filtering, Fail2Ban actually banning, host sysctl, reboot persistence, xrdp sessions) —
those need a real VPS.

Every suite is launched through the `docker-suite` skill (`.claude/skills/docker-suite/`); the
harness itself is described in `.claude/testing/CLAUDE.md`.

## `cli/`

Python, not Bash, so `.claude/RULES.md` doesn't apply; `.claude/lint.sh` checks it in its last stage
(`ruff format --check`, `ruff check`, and pdf-prep's pytest suite). Each tool is a uv project (`pyproject.toml` + `uv.lock`);
`.venv`, `__pycache__`, `*.log` and `*.log.[0-9]` are already gitignored — the rotated-log rule is separate because
`*.log` does not match `ping.log.1`. These run from a clone, not `wget`-piped, so the single-file
constraint doesn't bind them — except `cli/claude-auto-ping/install.sh`, which is wget-piped (see
`cli/claude-auto-ping/CLAUDE.md`).

### `cli/pdf-prep/`

A local PDF toolbox (compress / split for a Claude Project / translate). Its internals — torch
builds, compression checks, how sections are found — are in `cli/pdf-prep/CLAUDE.md`; read it
before changing anything there. Its tests are `.claude/testing/pdf-prep/` (pytest, part of the gate).

## web3/ (out of scope for features, still inside the gate)

`web3/cosmos_node_commands.sh` (source-only Cosmos validator helpers) and `web3/geth+beacon.sh` (Sepolia
geth + Prysm beacon setup) are not currently maintained. **Ignore this directory by default** — don't read,
review, refactor, or "fix while you're in there" unless the user explicitly asks about a file in `web3/` by
name. That is a rule about *feature* work: both files are inside `.claude/lint.sh`, pass
`shfmt` and `shellcheck -S style` clean, and any edit here must keep them passing. They have no bats or
Docker suite, so the gate is the only automated check they get.
