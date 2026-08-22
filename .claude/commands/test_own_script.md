---
description: Run server-scripts/configuring_server.sh through a matrix of Docker scenarios (systemd containers + expect automation of the /dev/tty dialog), with guaranteed image/container cleanup after every scenario and a full cleanup at the end.
argument-hint: (no arguments — just /test_own_script)
allowed-tools: Bash(docker build:*), Bash(docker run:*), Bash(docker rm:*), Bash(docker rmi:*), Bash(docker images:*), Bash(docker volume:*), Bash(docker ps:*), Bash(docker info:*), Bash(git rev-parse:*), Read
---

# Run configuring_server.sh scenarios through Docker

## Goal

Verify `server-scripts/configuring_server.sh` against **real behavior** (systemctl/ufw/fail2ban/sshd), not just
syntax, through a scenario matrix in disposable Docker containers. Never connects to a real SSH host (no
`ssh`/`AMD` — Docker on this machine only). Every image and container created during the run gets removed:
per-scenario ones right after their scenario, shared ones (driver, base layers, apt cache) at the very end.
Nothing should remain in `docker images`/`docker ps -a`/`docker volume ls` after the command finishes.

The harness lives in `.claude/testing/own-script/` — Claude Code's own tooling (not part of the shipped
`server-scripts/`/`dev-tools/`), nested one level under a folder named after the script under test, so other
scripts in this repo could get their own sibling `.claude/testing/<other-script>/` suite later without mixing
files. Two images with distinct roles inside, not duplication: `images/driver.Dockerfile` — the orchestrator
(docker CLI + expect), never runs the script itself, only drives sibling containers over the host socket;
`images/target.Dockerfile` — the system under test (systemd + iproute2/procps), has neither docker CLI nor
socket access.

## Step 0 — Safety checks

1. Confirm we're at the repo root:
   !`git rev-parse --show-toplevel`
   If this isn't a git repo, or isn't `my-script` — stop and tell the user.

2. Check Docker is reachable:
   !`docker info`
   If unavailable (Docker Desktop not running / not installed) — say so plainly and stop; don't try to fix or
   install anything yourself.

3. Explicitly state to the user before running: this run works ONLY with disposable Docker containers on this
   machine — no real SSH host is ever touched.

## Step 1 — Build the driver image

Run via the Bash tool (not `!` — this must run only after Step 0 passes, not pre-executed at command load time):

```bash
docker build --quiet -t cfgsrv-test-driver -f .claude/testing/own-script/images/driver.Dockerfile .claude/testing/own-script/images
```

If the build fails — stop, show the error as-is, don't silently guess at a fix.

## Step 2 — Run the harness

Add `-e SCENARIO_FILTER=<substring>` to run only the matching scenarios (e.g.
`SCENARIO_FILTER=20_ROLLBACK` finishes in ~3 min instead of ~25). That is for iterating on
one scenario only — the run that answers "does this change pass" must be unfiltered.

Use the Bash tool (not `!`, since output can be long and needs interpreting):

```bash
MSYS_NO_PATHCONV=1 docker run --rm \
  -e HOST_REPO_PATH="$(pwd)" \
  -e FULL_CLEAN=1 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd):/work/repo:ro" \
  cfgsrv-test-driver bash /work/repo/.claude/testing/own-script/run.sh
```

`/work/repo` is read-only and nothing is mounted writable: scenario logs stay inside the container under
`/tmp/results` and die with it. **Don't add a results mount back** — the user does not read these logs and
does not want them accumulating in the repo. Everything needed to judge the run is on stderr: the summary
table always, plus the tail of each failing scenario's log (`dump_failed_logs` in `run.sh`).

Works unchanged on both Windows (Docker Desktop) and native Ubuntu (Docker Engine) — the user works on this
repo from both. `MSYS_NO_PATHCONV=1` only matters under Git Bash (disables its path-mangling of `-v`
arguments); it's a harmless no-op on native Linux, so don't drop it or make it conditional.

Run it in the background (`run_in_background: true`) — all 16 scenarios run the script to completion, including
a real `apt-get update/upgrade` in every systemd container, which can take 20-40+ minutes depending on network
speed (a shared apt cache across scenarios helps a bit but doesn't remove the cost). Don't sleep-poll — wait for
the background-completion notification.

⚠️ RISK: `--privileged` containers get broad access to the host kernel (needed for systemd/ufw to work inside
the container). This is specifically for DISPOSABLE test containers, fully isolated in their own network
namespace — they never touch the real network/host beyond Docker. Each target container is also resource-capped
(`--memory 2g --cpus 2` by default, see `TARGET_MEMORY`/`TARGET_CPUS` in `.claude/testing/own-script/lib.sh`) so
one scenario can't exhaust host resources. Rollback: the container and its image are removed right after that
scenario (`lib.sh:cleanup_scenario`); the whole set via `trap full_teardown EXIT` in `run.sh` (fires on any exit,
including Ctrl-C) and in Step 4 of this command.

## Step 3 — Read the results

1. Take the summary table from the run's own output (the harness prints it to stderr) — there is no file to
   read, and none should be created.
2. Present the user a table shaped like:

   | Scenario | Result | Note |
   |---|---|---|

3. If something failed — don't try to fix `configuring_server.sh` yourself as part of this command. Show which
   scenario and which check failed, quoting the relevant lines from the failing scenario's log tail that the
   harness already printed, and ask the user whether to fix it now (a separate step — Изменение) or whether
   it's expected.
4. Give one-sentence overall verdict: all scenarios passed / there are issues (which ones) / the run didn't
   finish (technical reason — Docker unavailable, the jrei/systemd-ubuntu tag not found, an expect timeout,
   etc.).

## Step 4 — Final host-side cleanup

The driver container ran with `--rm`, so it doesn't leave itself behind, but its IMAGE (`cfgsrv-test-driver`)
stays in `docker images` on the host — remove it separately. Run via the Bash tool (not `!` — must run only
after Step 2 finishes, not pre-executed at command load time):

```bash
docker rmi cfgsrv-test-driver
docker images --format "{{.Repository}}:{{.Tag}}"
docker ps -a --format "{{.Names}}"
docker volume ls --format "{{.Name}}"
```

The last three confirm to the user that things are clean — show a short summary, not a full dump.

If anything with a `cfgsrv-test` prefix remains — the harness didn't reach `full_teardown()` (the run probably
got interrupted early); say so explicitly and ask whether to clean up manually rather than doing it yourself
without confirmation.

## Known limitations (say these out loud, don't stay quiet about them)

- Ubuntu only (`jrei/systemd-ubuntu:latest`) — no other distribution is in scope for this harness.
- 23 scenarios (`.claude/testing/own-script/scenarios.sh:run_all_scenarios`): 5 on argument parsing (`--help`,
  invalid port, unknown flag, `--user root`, missing `--password-file`) + 18 end-to-end with a full dialog —
  both auth modes, auto/manual password, fully interactive input with no presets, port 22 (edge case),
  `ssh-rsa` rejection, inline-pasted private key rejection, provider default user, an existing system account
  (uid<1000) both accepted and declined, username retry after invalid characters, password mismatch retry,
  foreign UFW rules kept, the confirm window, two rollback paths, an idempotent re-run. Extend by following
  the `run_heavy_scenario` pattern.
- The manual-password scenarios assert that a hash was set, not *which* password it hashes — the container has
  no non-interactive way to authenticate as that user.
- `ufw`/`fail2ban` inside the container are checked for "did the command succeed and what ended up in the
  ruleset", not real traffic filtering from an external host — the container is in its own network namespace,
  nothing leaks out.
- Comments inside the harness itself (`.claude/testing/own-script/*.sh`, `*.exp`, `images/*.Dockerfile`) are in
  English, matching the rest of this repository's code-comment convention; this command and chat replies to the
  user stay in Russian.

## Source attribution

Not applicable — this command's only inputs are local repository files and the output of docker/git on this
machine.
