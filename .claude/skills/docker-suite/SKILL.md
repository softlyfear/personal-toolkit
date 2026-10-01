---
name: docker-suite
description: Run one of this repo's Docker scenario suites — own-script (configuring_server.sh, the default), devsetup (install-dev-tools.sh), svcctl (service-manager.sh + install_svcctl.sh), sysupdate (update_system_all.sh + install_sysupdate.sh) or xrdp (add_*_xrdp.sh) — in disposable systemd containers with expect driving the /dev/tty dialog, and clean every image and container up afterwards. Use it whenever a change to a script in server-scripts/ or dev-tools/ touches anything the bats unit tests cannot prove (apt, systemctl, ufw, fail2ban, sshd, users), before committing that change, or when the user asks to test, run scenarios, or check a script "for real".
argument-hint: "[own-script|devsetup|svcctl|sysupdate|xrdp] [scenario-filter]"
allowed-tools: Bash(bash .claude/skills/docker-suite/scripts/run-suite.sh:*), Bash(docker info:*), Bash(docker images:*), Bash(docker ps:*), Bash(docker volume:*), Bash(git rev-parse:*), Read
---

# Docker scenario suites

Runs a suite under `.claude/testing/<suite>/` against **real behaviour** (systemctl, ufw, fail2ban,
sshd) in disposable containers on this machine. Never touches a real SSH host. Arguments: `$ARGUMENTS`
— the first word is the suite (default `own-script`), the second an optional scenario filter.

## 1. Run

Pick the suite from the script under change if no argument names one. Say once, before starting, that
only disposable local containers are involved. Then, with `run_in_background: true` (a full matrix is
20–40+ minutes: every scenario runs a real `apt-get update/upgrade`), and wait for the completion
notification instead of polling:

```bash
bash .claude/skills/docker-suite/scripts/run-suite.sh <suite> [scenario-filter]
```

The script checks the Docker daemon, builds `<suite>-test-driver` from that suite's own
`images/driver.Dockerfile` (all five differ — never reuse one suite's driver for another), runs the
suite's `run.sh` with the repo mounted read-only, and removes the driver image on any exit.

The filter (`20_ROLLBACK`, say) is honoured by `own-script` only, and only for iterating on one
scenario: the run that answers "does this change pass" is unfiltered.

⚠️ RISK: target containers run `--privileged` (systemd and ufw need it) and get broad host-kernel access. Rollback: each scenario's container and image are removed right after it (`cleanup_scenario`), the rest by `trap full_teardown EXIT` in `run.sh`, the driver image by the runner's own trap; resources are capped per target (`TARGET_MEMORY`/`TARGET_CPUS` in the suite's `lib.sh`).

## 2. Report

The harness prints the summary table and, for every failing scenario, the tail of its log to stderr.
There is no log file to read on the host, by design — don't add a `results/` mount.

Present `| Scenario | Result | Note |`, then a one-sentence verdict: all passed / which failed / the run
did not finish and why (Docker down, base image tag gone, expect timeout).

A failing scenario caused by the change under work is part of that task: fix it and re-run. A failure
the change cannot explain (flaky network, an upstream package) is reported with the quoted log lines,
not "fixed" by weakening the assertion.

## 3. Confirm the host is clean

```bash
docker images --format '{{.Repository}}:{{.Tag}}'
docker ps -a --format '{{.Names}}'
docker volume ls --format '{{.Name}}'
```

Summarise in one line. Leftovers carrying the suite's prefix mean `full_teardown` never ran (an
interrupted run): name them and ask before removing them by hand.

## What no container proves

Real SSH lockout, UFW packet filtering from outside, Fail2Ban actually banning, host sysctl, reboot
persistence, xrdp sessions — see `.claude/testing/unit/README.md`. Say so when the change is in one of
those areas: it needs a real VPS.
