# CLAUDE.md — .claude/testing/

Loaded when work touches this directory; the repository-wide rules are in `/.claude/CLAUDE.md`.

## Docker scenario suites

Five suites, one per script, all on the same `run.sh`/`lib.sh`/`scenarios.sh`/`images/` shape:
`own-script/` (`configuring_server.sh`), `devsetup/` (`install-dev-tools.sh`), `svcctl/`
(`service-manager.sh` + `install_svcctl.sh`), `sysupdate/` (`update_system_all.sh` + `install_sysupdate.sh`)
and `xrdp/` (`add_*_xrdp.sh`). Every one is launched through the `docker-suite` skill
(`.claude/skills/docker-suite/scripts/run-suite.sh <suite>`), which builds that suite's **own**
`images/driver.Dockerfile` — all five differ. Sourcing sibling files is fine here: this is Claude Code's
own tooling, never curl/wget-piped.
All comments inside the harness itself are in English, per the repo-wide language convention.

- `run.sh` — entry point, must run inside the `images/driver.Dockerfile` container (docker-outside-of-docker,
  needs `/var/run/docker.sock` mounted) so it can drive `expect` against the script's `/dev/tty` prompts.
- `lib.sh` — shared helpers (image build/run, expect wrapper, assertions, cleanup registry).
- `scenarios.sh` — the scenario matrix (`run_all_scenarios`); add new scenarios following the existing
  `run_heavy_scenario` pattern.
- `images/driver.Dockerfile` and `images/target.Dockerfile` are two distinct roles, not duplication: driver has
  the docker CLI + `expect` and only ever calls `docker exec` on sibling containers, never running the script
  itself; target has systemd as PID 1 (via `jrei/systemd-ubuntu:latest` — most of the script's steps are
  `systemctl`/`ufw`/`fail2ban`, which don't work in a plain container) plus `iproute2`/`procps`, and has no
  docker CLI or socket access at all. Ubuntu only by design.
- Every scenario runs the full script to completion (or its natural error exit) inside a real target container —
  including argument-parsing scenarios that fail before touching any service, kept on the same image for
  consistency rather than a separate lightweight path.
- Scenario logs are written to `/tmp/results/<ts>/` **inside the driver container** and die with it. Nothing
  is mounted writable from the host: the user does not read these logs and asked that they stop accumulating
  in the repo. Don't reintroduce a `results/` mount or a host-side `results/` directory — the summary table
  and, on failure, the tail of each failing scenario's log (`dump_failed_logs` in `run.sh`) go to stderr,
  which is the only report there is. **Keep the `.claude/testing/*/results/` line in `.gitignore`**: the
  generic `*.log` rule does not cover `summary.md`, and dropping the explicit rule once already let 42 of
  them into a commit.
- Cleanup: each scenario's container+image are removed right after that scenario (`cleanup_scenario`); the
  shared base layers, apt-cache volume, and driver image are removed at the end via `trap full_teardown EXIT`
  (fires on normal completion, error, or Ctrl-C) so nothing accumulates on the host. Never points at a real SSH
  host — Docker-only, by design.
- Host-OS-agnostic by construction: the user works on this repo from both Windows and native Ubuntu, so the
  only thing that ever touches the host shell directly is the one `docker run` in `run-suite.sh` that
  launches the driver container (plain POSIX, `MSYS_NO_PATHCONV=1` is a harmless no-op outside Git Bash) —
  every actual test step (`lib.sh`, `scenarios.sh`, `run.sh`, `drive.exp`) runs inside Linux containers
  regardless of host OS. Don't reintroduce host-OS-specific paths or tools into `lib.sh`/`scenarios.sh`/`run.sh`.
