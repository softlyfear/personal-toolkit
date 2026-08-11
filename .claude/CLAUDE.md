# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A collection of standalone Bash scripts for provisioning/hardening Ubuntu/Debian servers and setting up dev
environments. There is no build system, package manager, or test suite — each script is a self-contained CLI
tool meant to be run directly, often via `bash <(wget -qO- <raw-github-url>)` without cloning the repo first.

```
server-scripts/   VPS hardening, system updates, service management, xrdp — PRIMARY FOCUS
dev-tools/         devsetup script + a copy-paste Makefile template for FastAPI projects — SECONDARY FOCUS
web3/               Cosmos/Ethereum node helpers — out of scope, see "web3/ (out of scope)" below
```

Test tooling for `configuring_server.sh` lives in `.claude/testing/own-script/` (Claude Code-only, not part of
the shipped repo content) — see "Testing harness" below.

**Priority:** `server-scripts/` and `dev-tools/` are the actively maintained parts of this repo.
**`server-scripts/configuring_server.sh` is the most important script here** — it is the largest, the riskiest
(full remote-access hardening), and the one most likely to be the subject of a request. Give it the most
scrutiny on any change. `web3/` is not currently maintained — see the dedicated note at the bottom; do not
read, review, or modify it unless the user explicitly names a file in it.

## Language convention

Everything inside this repository — code comments, commit-visible docs like this file, script output/error
strings, `.claude/commands/*.md` — is English. This includes the risk/rollback warning line (see below): it
used to be a Russian "⚠️ РИСК: ... Откат: ..." phrasing, now it's English. The one exception is
`.claude/output-styles/senior_linux.md`: only its embedded risk-line *template* was updated to English (since
that template gets written into delivered code); the rest of that file governs chat-response formatting and
stays Russian, since Claude's chat replies to the user in this project are in Russian regardless of the
repository's own code-language convention.

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
  print a risk/rollback warning to stderr. Existing warnings use this exact pattern — keep it (English
  only as of the repo-wide English convention below; older revisions of this repo used a Russian
  "⚠️ РИСК: ... Откат: ..." phrasing for this line — don't reintroduce it):
  ```
  ⚠️ RISK: <what could break>. Rollback: <how to recover>.
  ```
- Input validation is strict and fails closed: usernames are sanitized to `[a-z0-9_-]` and reserved names
  (e.g. `root`) are rejected, IPs are regex-validated, SSH keys are type-checked (ed25519/ecdsa only —
  `ssh-rsa` is explicitly rejected) and verified with `ssh-keygen -l -f` before being trusted.
- Secrets passed via CLI flags (e.g. `--password`) are visible in `ps`/`/proc/<pid>/cmdline` for the life of
  the process — prefer adding a `--*-file PATH` alternative over a raw value flag when introducing new
  secret-accepting options (see `configuring_server.sh --password-file` for the pattern).

## Checksum pinning — update in lockstep

Two installer scripts pin a SHA256 of the script they fetch and install to `/usr/local/bin`:

- `server-scripts/install_svcctl.sh` pins the checksum of `server-scripts/service-manager.sh` (installs as
  `svcctl`)
- `server-scripts/install_sysupdate.sh` pins the checksum of `server-scripts/update_system_all.sh` (installs
  as `sysupdate`)

**Any edit to `service-manager.sh` or `update_system_all.sh` requires recomputing and updating
`EXPECTED_SHA256` in the corresponding `install_*.sh`**, or the installer will fail closed (by design — this
is a supply-chain integrity check, not a bug). Recompute with:

```bash
sha256sum server-scripts/service-manager.sh
sha256sum server-scripts/update_system_all.sh
```

Both installers also validate `EXPECTED_SHA256` itself against `^[[:xdigit:]]{64}$` before comparing, and run
`bash -n` on the downloaded script before installing it.

## `configuring_server.sh` — architecture notes

The flagship script: a full VPS hardening flow (`server-scripts/configuring_server.sh`). Key structural
points to preserve when modifying it:

- **Execution order matters and is documented in the header**: system update → SSH/sudo user hardening → UFW
  → Fail2Ban → sysctl → journald → cron/at → final cleanup. SSH hardening happens before the firewall is
  locked down; the new user's key is verified (`verify_ssh_authorized_key`) *before* root login is disabled,
  so a bad key can't lock the operator out.
- **Rollback via `trap rollback_on_failure EXIT`**: every risky mutation (sshd config, sudoers, UFW rules,
  Fail2Ban config, `ssh.socket` mask/disable) records enough state (`ROLLBACK_*` globals) to be undone if the
  script exits before `SCRIPT_SUCCEEDED=true` is set. If you add a new mutating step before that point, add
  matching rollback state and handle it in `rollback_on_failure()`.
- **`SCRIPT_SUCCEEDED=true` is set before the final cleanup steps** (removing the provider's default user,
  clearing password history), not at the very end of the script. This is intentional: those steps run after
  all critical hardening has already succeeded, so their failure must not roll back working SSH/UFW/Fail2Ban
  config — it's surfaced instead as a non-zero exit *after* `print_final_summary` has already shown the
  operator their credentials and reconnect command.
- `is_reserved_username()` rejects `root` as the sudo username (checked in both the interactive prompt and
  `--user`). This isn't cosmetic: `PermitRootLogin no` blocks root SSH regardless of `AllowUsers`, so allowing
  `root` here would let the script "succeed" while leaving the operator with no working account.
  `ensure_sudo_user()` also requires an explicit confirmation before granting sudo/SSH access to an *existing*
  system account (uid < 1000), to avoid silently escalating a service account.
- `remove_provider_default_user()` (removes the cloud provider's default account, e.g. `user`) retries
  `pkill` → `pkill -9` → `userdel -rf`, verifying via `id` that the account is actually gone rather than
  trusting a single command's exit code.
- Functions are grouped by section banners (`UI`, prompts, SSH keys, network/systemd, rollback, users, sshd,
  other services) — keep new functions under the matching banner rather than appending at the end.
- `verify_ssh_port_available`, `verify_sshd_port`, and `verify_ssh_ipv4_only` re-check the *effective* runtime
  config via `sshd -T` after writing config, rather than trusting the written file — don't replace these with
  static file checks.
- All inline comments in this file are in English (see "Language convention" below) — e.g. the rationale for
  the `00-hardening.conf` drop-in ordering. Don't reintroduce Russian comments here.

## `dev-tools/`

- `install-dev-tools.sh` — installs `git`/`uv`/`make`/`postgresql`/`docker` on apt-based systems, with
  `--all` (default), `--interactive`, or an explicit tool list. `install_uv()` downloads astral.sh's own
  installer to a temp file and runs `bash -n` on it before executing — it is **not** checksum-pinned like
  `service-manager.sh`/`update_system_all.sh` are, since it's a third-party script that changes upstream; keep
  that distinction in mind if asked to "harden" this file further.
- `dev-tools/Makefile` is not part of this repo's own build — it's a template meant to be copied into
  external FastAPI projects (see README "Copy into your project"). It assumes `uv`, `ruff`, `ty`, `pytest`,
  and optionally `alembic`/`docker compose` in the *target* project, not here. `PROJECT_NAME` is a placeholder
  (`<PROJECT_NAME>`) meant to be filled in by whoever copies it.

## No linter or CI configured; scenario testing lives in testing/

There's no shellcheck config and no CI workflow in this repo. The closest thing to static validation
is the installer scripts running `bash -n <downloaded-script>` (syntax-only check) before installing. When
changing a script, at minimum run:

```bash
bash -n path/to/script.sh
```

and, if available, `shellcheck path/to/script.sh` before considering a change done.

### Testing harness (`.claude/testing/own-script/`)

Runs `server-scripts/configuring_server.sh` through a matrix of Docker scenarios via the `/test_own_script`
command (`.claude/commands/test_own_script.md`). Lives under `.claude/` because it's Claude Code's own tooling,
not shipped repo content — unlike `server-scripts/`/`dev-tools/`, sourcing sibling files here is fine, it's
never curl/wget-piped. Nested one level under `.claude/testing/<script-name>/` (currently just `own-script/`,
named after the `/test_own_script` command) so other scripts in this repo can get their own sibling test suite
later without mixing files. All comments inside the harness itself are in English, per the repo-wide language
convention above.

- `run.sh` — entry point, must run inside the `images/driver.Dockerfile` container (docker-outside-of-docker,
  needs `/var/run/docker.sock` mounted) so it can drive `expect` against the script's `/dev/tty` prompts.
- `lib.sh` — shared helpers (image build/run, expect wrapper, assertions, cleanup registry).
- `scenarios.sh` — the scenario matrix (`run_all_scenarios`); add new scenarios following the existing
  `run_heavy_scenario` pattern.
- `images/driver.Dockerfile` and `images/target.Dockerfile` are two distinct roles, not duplication: driver has
  the docker CLI + `expect` and only ever calls `docker exec` on sibling containers, never running the script
  itself; target has systemd as PID 1 (via `jrei/systemd-ubuntu:26.04` — most of the script's steps are
  `systemctl`/`ufw`/`fail2ban`, which don't work in a plain container) plus `iproute2`/`procps`, and has no
  docker CLI or socket access at all. Ubuntu only by design — Debian is intentionally not covered.
- Every scenario runs the full script to completion (or its natural error exit) inside a real target container —
  including argument-parsing scenarios that fail before touching any service, kept on the same image for
  consistency rather than a separate lightweight path.
- Cleanup: each scenario's container+image are removed right after that scenario (`cleanup_scenario`); the
  shared base layers, apt-cache volume, and driver image are removed at the end via `trap full_teardown EXIT`
  (fires on normal completion, error, or Ctrl-C) so nothing accumulates on the host. Never points at a real SSH
  host — Docker-only, by design.
- Host-OS-agnostic by construction: the user works on this repo from both Windows and native Ubuntu, so the
  only thing that ever touches the host shell directly is the one `docker run` in `test_own_script.md` that
  launches the driver container (plain POSIX, `MSYS_NO_PATHCONV=1` is a harmless no-op outside Git Bash) —
  every actual test step (`lib.sh`, `scenarios.sh`, `run.sh`, `drive.exp`) runs inside Linux containers
  regardless of host OS. Don't reintroduce host-OS-specific paths or tools into `lib.sh`/`scenarios.sh`/`run.sh`.

## web3/ (out of scope)

`web3/cosmos_node_commands.sh` (source-only Cosmos validator helpers) and `web3/geth+beacon.sh` (Sepolia
geth + Prysm beacon setup) are not currently maintained. **Ignore this directory by default** — don't read,
review, refactor, or "fix while you're in there" unless the user explicitly asks about a file in `web3/` by
name. The one exception worth remembering if that ever happens: `web3/geth+beacon.sh` pins
`GETH_VERSION`/`GETH_ARCHIVE_SHA256` and `PRYSM_VERSION`/`PRYSM_SCRIPT_COMMIT`/`PRYSM_SCRIPT_SHA256`, so
bumping either binary version requires updating its paired hash from the upstream release — the same
lockstep-checksum discipline as the `server-scripts/` installers.
