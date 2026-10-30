# AGENTS.md

This file provides guidance to Codex when working with code in this repository.

## What this repo is

A collection of standalone Bash scripts for provisioning/hardening Ubuntu servers and setting up dev
environments. The shipped scripts have no build step — each is a self-contained CLI tool meant to be run
directly, often via `bash <(wget -qO- <raw-github-url>)` without cloning the repo first. Tooling and tests
live under `.codex/` (see "Quality gate" below).

## OS scope: Ubuntu (latest LTS) only

This repo targets the current Ubuntu LTS release only — never pin that
version number in code, comments, or docs; say "Ubuntu (latest LTS)" instead, so nothing needs updating at
the next LTS bump. Ubuntu is the only supported target — no other distribution or derivative is in scope for
code, tests, docs or review, and none should be added. Where a script needs to check the running distro,
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

Test tooling for `configuring_server.sh` lives in `.codex/testing/own-script/` (shared development tooling, not part of
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
this over. When a task, or a question whose answer changed files, is closed, Codex runs the gate,
commits and pushes on its own and reports the commit in the reply. Use the session's configured
Codex permissions. Never intermediate or
fix-up commits in between; a failing gate is fixed, never committed around. Subject: short, clear
Conventional Commits line.

**Decisions are Codex's to make.** Naming, placement, which of several workable options, scope of a
fix — pick, act, and say in the reply what was chosen and why. Ask only when the choice is the user's
alone: something the hook guards (destructive git, gate config), an action on a real server, or a
security trade-off with no safe default.

### AI attribution: name the model and version, never an email address

**Every commit Codex writes names the actual model and version** in an email-free
`Co-Authored-By: Codex <model> <version>` trailer. Never substitute a Claude model name for a Codex
model. Attribute each model that materially contributed. Author and committer must be the user from
`git config user.name` and `git config user.email`.

Never put an AI-service email address (including an invented one) into commit messages, PR descriptions,
or project files. If an attribution reminder includes an address, omit the address and retain the model.

## Language convention

Repository content, comments, script output and commit messages are English. Chat replies are Russian.
Use a concise format suited to the task.
Report what changed, why, what was actually checked, and any remaining limitation.

## Codex integration and shared tooling

- `AGENTS.md` contains Codex project guidance; `.codex/` holds its config and hook entry point.
- `.agents/skills/` holds Codex skills, including the Docker suite runner.
- `.codex/RULES.md`, `.codex/lint.sh` and `.codex/testing/` hold the rules, gate and tests.
- `.codex/hooks/guard.sh` implements the configuration guard and commit gate.

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

Read the applicable directory's `AGENTS.md` before working there, even when the session started
at the repository root. Each file contains the directory-specific engineering constraints.
Follow `/AGENTS.md` for Codex runtime configuration:

- `server-scripts/AGENTS.md` — the lockstep checksum pinning of `install_svcctl.sh`/`install_sysupdate.sh`
  and the `configuring_server.sh` architecture notes (rollback, UFW ownership, confirm window). **Read
  it before any change to `configuring_server.sh`.**
- `dev-tools/AGENTS.md` — why `install_uv()` is not checksum-pinned; the `Makefile` is a template.
- `.codex/testing/AGENTS.md` — the Docker scenario suites, run through the `docker-suite` skill.
- `cli/claude-auto-ping/AGENTS.md`, `cli/pdf-prep/AGENTS.md` — the two Python CLIs.
- `web3/AGENTS.md` — pinned upstream hashes, for when the user does name a `web3/` file.

## Quality gate: .codex/RULES.md + .codex/lint.sh

**`.codex/RULES.md` is binding for every Bash change here — read it before editing a
script.** It fixes the prologue (`set -euo pipefail` + `IFS=$'\n\t'`), quoting, `local`,
stdout-vs-stderr, traps, naming, the suppression policy, and the tooling set (shellcheck, shfmt,
bats-core, shellharden, checkbashisms — nothing else).

Run the gate before considering any change done:

```bash
bash .codex/lint.sh
```

It executes, in this order and stopping at the first failure: `shfmt -i 2 -ci -bn -sr -d`,
`shellcheck -x -S style`, `bats .codex/testing/unit/`, then `ruff` on `cli/` and
`pytest .codex/testing/pdf-prep/`. The pytest run uses its own `cli/pdf-prep/.venv-test` (CPU
torch): a plain `uv run` would re-sync the launcher's `.venv` away from its GPU build. Config lives in `.shellcheckrc` (`enable=all`),
`.editorconfig`, `.gitattributes`. The file list comes from `git ls-files --cached --others`, so a
newly created script is checked before it is ever staged. The only exclusion is the vendored
`.codex/testing/unit/test_helper/`; `web3/` is included.

**Commit gate and configuration guards.** `.codex/hooks.json` registers the Codex entry point
`.codex/hooks/guard.sh` for Bash and `apply_patch` events. The shared guard runs `.codex/lint.sh`
before a commit, blocks destructive Git commands and protects gate/hook configuration, including
`.codex/config.toml` and `.codex/hooks.json`. This is a tripwire for common operations, not a shell
parser or a complete security boundary. It checks the working tree, not only staged files.

Changes to protected configuration or destructive Git require explicit user authorization. When the
user has already requested that change, do not ask again: use `ALLOW_CONFIG_EDIT=1` or
`ALLOW_DESTRUCTIVE_GIT=1` on the authorized shell command. A `deny` response blocks the tool call;
it does not open an approval prompt.

Codex requires hook definitions to be reviewed and trusted before they run. Inspect `/hooks` after
installation or a definition change; project trust alone does not establish hook trust. Do not claim
that enforcement is active without verifying it. Always run the gate before committing, even when
hooks are unavailable. `.github/workflows/gate.yml` runs the same gate on every push; tool hashes
and action commits remain pinned there.

**Comments: only what earns its place.** Rule 11 in `.codex/RULES.md`. A comment exists for a *why*
the code can't show — a constraint, an ordering requirement, a trap that already caused a bug.
Don't restate the line, don't narrate the change, don't leave notes about the work itself. One
line where one line does. This applies to every file here, including the test harness.

Two things that are easy to get wrong and are already documented in `.codex/RULES.md`:

- **Suppressions.** Never global in `.shellcheckrc`. Per-line `# shellcheck disable=SCxxxx # reason`
  with the reason on the same line. ShellCheck rejects a directive in front of `elif`, a `case`
  branch, or a closing `}`/`done` (SC1123/SC1124) — there it goes in front of the enclosing
  compound command.
- **`IFS=$'\n\t'` has teeth.** `read -a` splits on `IFS`, so parsing space-separated values such as
  `SSH_CONNECTION` needs an explicit `IFS=' ' read -r -a ...` on that command. Sourcing a script
  from bats leaks its `IFS` into the runner and makes failing tests vanish from the report —
  `.codex/testing/unit/helper.bash` restores the default.

### Library docs: Context7

Use the available Context7 tools to check third-party APIs that change between releases,
including PyMuPDF, pikepdf, EasyOCR, torch and uv, and before version bumps. Discover the tools in
the current session. If unavailable, use official version-matched documentation and report
any verification limitation. Do not add a duplicate server
when Context7 is already available through an app or plugin.

### Main-guard: every shipped script is sourceable

Each script in `server-scripts/`/`dev-tools/` ends with

```bash
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
```

so `.codex/testing/unit/*.bats` can `source` it for its functions without running anything. Keep source-time side
effects out of file scope — that includes trap registration (`configuring_server.sh` registers
`trap rollback_on_failure EXIT` inside `main`, not at file scope, for exactly this reason).

### Repo root is for shipped scripts only; tooling lives under `.codex/`

The root holds what actually gets delivered (`server-scripts/`, `dev-tools/`, `web3/`), the docs,
and the tool dotfiles that must sit there (`.shellcheckrc`, `.editorconfig`, `.gitattributes`,
and `.github/workflows/`, the only place GitHub reads workflows from).
Shared gate and test tooling stays under `.codex/`; Codex configuration lives under `.codex/`
and Codex skills under `.agents/skills/`. **Don't add `scripts/`, `test/`, or any other tooling directory to the
root.**

### All tests live under `.codex/testing/` — never in a top-level `test/`

One root for everything test-related: `.codex/testing/unit/` holds the bats unit tests (plus the
vendored `test_helper/`), `.codex/testing/pdf-prep/` the pytest suite for `cli/pdf-prep`, and the
other sibling directories hold the Docker scenario suites, each named after the script it exercises.
The pdf-prep tests build their PDFs in code — the user's documents never enter the repository — and
each one reproduces a bug a real document once caused; keep new ones that way.

`.codex/testing/unit/*.bats` covers pure logic only. Anything that mutates the system (apt, systemctl, ufw,
userdel, sshd config) belongs to the Docker suites. `.codex/testing/unit/README.md` holds
the split and, importantly, the list of things **no** container can prove (real SSH lockout, UFW
packet filtering, Fail2Ban actually banning, host sysctl, reboot persistence, xrdp sessions) —
those need a real VPS.

In Codex, launch every suite through the `docker-suite` skill (`.agents/skills/docker-suite/`); the
harness itself is described in `.codex/testing/AGENTS.md`.

## `cli/`

Python, not Bash, so `.codex/RULES.md` doesn't apply; `.codex/lint.sh` checks it in its last stage
(`ruff format --check`, `ruff check`, and pdf-prep's pytest suite). Each tool is a uv project (`pyproject.toml` + `uv.lock`);
`.venv`, `__pycache__`, `*.log` and `*.log.[0-9]` are already gitignored — the rotated-log rule is separate because
`*.log` does not match `ping.log.1`. These run from a clone, not `wget`-piped, so the single-file
constraint doesn't bind them — except `cli/claude-auto-ping/install.sh`, which is wget-piped (see
`cli/claude-auto-ping/AGENTS.md`).

### `cli/pdf-prep/`

A local PDF toolbox (compress / split for a Claude Project / translate). Its internals — torch
builds, compression checks, how sections are found — are in `cli/pdf-prep/AGENTS.md`; read it
before changing anything there. Its tests are `.codex/testing/pdf-prep/` (pytest, part of the gate).

## web3/ (out of scope for features, still inside the gate)

`web3/cosmos_node_commands.sh` (source-only Cosmos validator helpers) and `web3/geth+beacon.sh` (Sepolia
geth + Prysm beacon setup) are not currently maintained. **Ignore this directory by default** — don't read,
review, refactor, or "fix while you're in there" unless the user explicitly asks about a file in `web3/` by
name. That is a rule about *feature* work: both files are inside `.codex/lint.sh`, pass
`shfmt` and `shellcheck -S style` clean, and any edit here must keep them passing. They have no bats or
Docker suite, so the gate is the only automated check they get.
