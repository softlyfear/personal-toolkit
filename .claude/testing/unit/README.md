# Tests

Two layers, deliberately split by what each can actually prove.

| Layer | Location | Runs | Proves |
|---|---|---|---|
| Unit | `.claude/testing/unit/*.bats` | `bats .claude/testing/unit/` (seconds) | Pure logic: parsing, validation, sanitising, formatting |
| Scenario | `.claude/testing/<suite>/` | Docker, `run.sh` per suite (minutes to hours) | Real behaviour of systemctl / ufw / fail2ban / sshd / apt |

Both are gated by `.claude/lint.sh`, which runs `shfmt -d`, then
`shellcheck -x -S style`, then `bats .claude/testing/unit/`, and fails on any non-zero exit.

## Unit layer

Scripts are single-file and wget-piped, so there is no `lib/` to import. Each script
instead carries a main-guard, which lets a test `source` it, reach its functions, and never
execute `main`. `.claude/testing/unit/helper.bash` provides `source_script` and restores the default `IFS`
afterwards — the scripts set `IFS=$'\n\t'`, and letting that leak into bats breaks its
failure reporting (a failing test silently disappears instead of being reported).

External commands are shadowed by functions inside the test rather than mocked on disk.

| File | Covers |
|---|---|
| `configuring_server.bats` | `configuring_server.sh` — UI helpers, username sanitising, password strength/generation, SSH key sanitising and path expansion, key file validation, IP detection, unit/port probes, CLI argument parsing |
| `service_manager.bats` | `service-manager.sh` — usage, service-name normalisation, allow-list |
| `update_system_all.bats` | `update_system_all.sh` — UI helpers, `need_cmd` |
| `installers.bats` | `install_svcctl.sh`, `install_sysupdate.sh` — UI helpers, checksum-pin shape, base URL |
| `install_dev_tools.bats` | `install-dev-tools.sh` — usage, `need_cmd`, tool list ↔ installer function consistency |
| `xrdp.bats` | `add_xfce_xrdp.sh`, `add_gnome_xrdp.sh` — UI helpers, `setup_sudo` privilege selection, dpkg-lock wait, RDP port and PAM constants |

Functions that mutate the system (apt, systemctl, ufw, userdel, sshd config) are
intentionally absent here — a unit test asserting against a mocked `systemctl` proves only
that the mock was called. Those live in the scenario layer.

## Scenario layer

Five Docker suites, each with a driver container (docker CLI + expect) driving a disposable
systemd target container. 62 scenarios total: `own-script` 20, `devsetup` 12, `svcctl` 11,
`xrdp` 10, `sysupdate` 9.

Two scenarios exercise `rollback_on_failure()`, and they are not redundant.
`19_ROLLBACK_ON_FAILURE` forces a deterministic failure in step 6 (a `fail2ban.service`
drop-in with `ExecStartPre=/bin/false`, written before the unit exists) and asserts the box
is back where it started. `20_ROLLBACK_UFW_MIDSTEP` fails the *first* `ufw ... enable` via a
pass-through wrapper, so the run dies partway through step 5 — the window where the rollback
flag used to be unset, leaving default policies flipped and pruned rules gone. Both compare
`ufw status verbose` byte-for-byte against a snapshot taken before the run.

Killing a run with SIGKILL does **not** test any of this: bash cannot trap SIGKILL, so the
EXIT trap never fires and nothing is rolled back.

## What Docker cannot prove — VPS only

The scenario suites run in containers sharing the host kernel, in their own network
namespace, with no external client. The following therefore need a real VPS and are
**not** covered by any automated layer:

| Area | Why a container cannot prove it | How to verify on a VPS |
|---|---|---|
| Actual SSH lockout risk | No external client ever connects; the suites assert config and listeners, not a real login | Open a **second** session before hardening, then `ssh -p <port> <user>@<ip>` from outside |
| UFW packet filtering | Rules are asserted as present in the ruleset; no traffic crosses a real interface | `nmap`/`nc` from another host against open and closed ports |
| Fail2Ban actually banning | The jail is asserted as enabled; no repeated failed logins arrive from a real source IP | Deliberately fail auth N times from a second host, then `fail2ban-client status sshd` |
| sysctl network hardening | Container `sysctl` writes are namespaced or rejected; the host kernel is untouched | `sysctl -a` on the VPS after reboot, compare with `/etc/sysctl.d/98-hardening.conf` |
| `systemd-timesyncd` synchronising | The unit ships `ConditionVirtualization=!container`, so it is enabled but never started; `NTPSynchronized=yes` inside Docker is the host clock showing through | `timedatectl` on the VPS |
| Reboot-persistent state | Containers are destroyed after each scenario | Reboot the VPS and re-check ports, UFW, Fail2Ban, sysctl |
| `unattended-upgrades` actually upgrading | Only the config is asserted; no timer fires within a scenario | `unattended-upgrade --dry-run -d` on the VPS |
| xrdp session usability | No RDP client, no X server, no GPU | Connect a real RDP client and log into the desktop |
| Provider default-user removal under load | No real logged-in session holding the account open | Run on a fresh provider VPS that still has its default account |
| Cloud-init interaction | Absent in the base image | Run on a freshly provisioned VPS before cloud-init settles |

## Running

```bash
bash .claude/lint.sh                 # format + lint + unit tests
bats .claude/testing/unit/                           # unit tests only
```

Scenario suites are driven from `.claude/` tooling; see
`.claude/commands/test_own_script.md` for the exact `docker run` invocation.
