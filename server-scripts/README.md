# server-scripts

> VPS provisioning and hardening for **Ubuntu (latest LTS)**. Seven standalone Bash scripts, each fetched
> and executed in one line — no clone, no shared library, no config file.

```bash
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/server-scripts/<script>.sh)
```

| Script                                            | What it is for                                                          | Privileges              |
| ------------------------------------------------- | ------------------------------------------------------------------------ | ----------------------- |
| [`configuring_server.sh`](configuring_server.sh) | First-run hardening: sudo user, SSH, UFW, Fail2Ban, sysctl, journald     | root + interactive TTY  |
| [`update_system_all.sh`](update_system_all.sh)   | One-shot full update: apt + snap + flatpak                               | root or sudo            |
| [`install_sysupdate.sh`](install_sysupdate.sh)   | Installs the above as the global `sysupdate` command                     | root or sudo            |
| [`service-manager.sh`](service-manager.sh)       | `systemctl` wrapper restricted to `postgresql` and `docker`              | root or sudo            |
| [`install_svcctl.sh`](install_svcctl.sh)         | Installs the above as the global `svcctl` command                        | root or sudo            |
| [`add_gnome_xrdp.sh`](add_gnome_xrdp.sh)         | GNOME desktop + xrdp on port 3389                                        | root/sudo + TTY         |
| [`add_xfce_xrdp.sh`](add_xfce_xrdp.sh)           | XFCE desktop + xrdp on port 3389 (lighter)                               | root/sudo + TTY         |

**Jump to:** [configuring_server.sh](#configuring_serversh) · [system updates](#update_system_allsh--install_sysupdatesh) ·
[service manager](#service-managersh--install_svcctlsh) · [xrdp](#add_gnome_xrdpsh--add_xfce_xrdpsh) ·
[testing](#testing)

## Conventions shared by all seven

- `set -euo pipefail` + `IFS=$'\n\t'`, a `main()` behind a main-guard so the file can be sourced for tests.
- The same `info` / `ok` / `warn` / `err` helpers — **all output goes to stderr**, and `err` always exits 1.
- `$SUDO` is set from `id -u`, so each script works both as root and under `sudo`.
- A `⚠️ RISK: … Rollback: …` line is printed before any step that can drop remote access.

**Distro check.** A missing `apt-get` is fatal. An `/etc/os-release` `ID` other than `ubuntu` is a warning,
not a block — that keeps close derivatives usable. The one exception is `add_gnome_xrdp.sh`, which hard-fails
on a non-Ubuntu `ID` because it installs `ubuntu-gnome-desktop`.

**Prompts read from `/dev/tty`, not stdin** — stdin is already consumed by `bash <(wget …)`. As a
consequence, redirecting the output of an interactive script (`| tee log`, `> log`) while running under
`sudo` breaks the prompts; run as root or drop the redirect.

---

# configuring_server.sh

The flagship. Takes a freshly provisioned VPS where you log in as `root` and leaves it with one
key-authenticated sudo user, a closed firewall and no root SSH.

```bash
bash <(wget -qO- .../configuring_server.sh)                  # port 2244, all prompts
bash <(wget -qO- .../configuring_server.sh) 2255             # custom port
bash <(wget -qO- .../configuring_server.sh) --user softly --password-file /root/.new-user-pass
bash <(wget -qO- .../configuring_server.sh) 2255 --confirm-window 10
```

## Flags

| Flag               | Short | Value     | Default            | Notes                                                                                     |
| ------------------ | ----- | --------- | ------------------ | ------------------------------------------------------------------------------------------- |
| _(positional)_     |       | `port`    | `2244`             | 1–65535, must be free — an sshd already on it is treated as a re-run                        |
| `--user`           | `-u`  | `NAME`    | prompt → `admin`   | sanitized to `[a-z0-9_-]`; `root` rejected                                                  |
| `--password-file`  |       | `PATH`    | —                  | first line of the file; warns if the file is group/world-readable                           |
| `--password`       | `-p`  | `PASS`    | prompt or generated | visible in `ps` / `/proc/<pid>/cmdline` while the script runs — prefer `--password-file`   |
| `--confirm-window` |       | `MINUTES` | off                | 5–1440; arms the [auto-revert](#auto-revert-the-confirm-window)                             |
| `--help`           | `-h`  |           |                    | print usage and exit                                                                        |

## Execution order

The order **is** the safety property — each step assumes the previous one succeeded.

| # | Step                  | What happens                                                                                                                                       |
| - | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 | System update         | `apt-get update` + `upgrade`, waiting up to 300 s for the dpkg lock                                                                                |
| 2 | Packages              | `sudo openssh-server fail2ban ufw unattended-upgrades`                                                                                             |
| 3 | Auto-upgrades, NTP    | Unattended security upgrades with `Automatic-Reboot "false"`; `chrony` / `chronyd` / `systemd-timesyncd`, then polls `NTPSynchronized` for ≤ 30 s |
| 4 | **SSH + sudo user**   | Asks key-only or password-only, creates the user, grants sudo, installs and **verifies** the key, writes the sshd drop-in, restarts sshd            |
| 5 | **UFW**               | Opens the SSH port *first*, sets `deny incoming` / `allow outgoing`, prunes other rules, enables logging and the firewall, re-checks the SSH rule   |
| 6 | Fail2Ban              | `sshd` jail, `banaction = ufw`, `backend = systemd` — ban 1 h after 3 failures in 10 min                                                            |
| 7 | sysctl                | `/etc/sysctl.d/98-hardening.conf` plus a re-apply unit                                                                                             |
| 8 | journald, cron/at     | Journal size and retention limits; `cron` and `at` restricted to root                                                                              |
| 9 | Cleanup               | Removes the provider's default `user` account, clears shell history if a password flag was used, prints the summary                                 |

## The two modes

The first prompt picks one. Root SSH login is disabled either way.

|              | Key mode (default)                                                                                       | Password mode                              |
| ------------ | -------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| sshd auth    | `AuthenticationMethods publickey`                                                                        | `AuthenticationMethods password`           |
| Key types    | ed25519 / ecdsa only — `ssh-rsa` is rejected on input **and** stripped from an existing `authorized_keys` | pubkey auth off                            |
| Password     | only if `--password`/`--password-file` was given, so console login still works                           | required — typed, generated, or from a flag |
| Sudo         | prompt: NOPASSWD, default **no**                                                                         | always password                            |

A generated password is 24 hex characters plus `Aa1!`. Whatever its source, it is mirrored into
`/root/.<user>-credentials` (mode 600) — the summary scrollback is otherwise the only copy, and losing it
strands a reachable server with unusable sudo.

## What lands on disk

| Path                                                             | Content                                                                    |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `/etc/ssh/sshd_config.d/00-hardening.conf`                      | Every hardening directive (see below)                                      |
| `/etc/sudoers.d/<user>`                                          | Only when NOPASSWD was chosen; validated with `visudo -cf`                 |
| `~<user>/.ssh/authorized_keys`                                   | `600`, owned by the user; `.ssh` is `700`                                  |
| `/etc/apt/apt.conf.d/20auto-upgrades`, `51custom-unattended-…`  | Unattended upgrades, no auto-reboot                                        |
| `/etc/fail2ban/jail.local`                                       | `[DEFAULT]` + `[sshd]` jail on the new port                                |
| `/etc/sysctl.d/98-hardening.conf`                                | Syncookies, redirect/source-route rejection, `rp_filter`, `log_martians`   |
| `/etc/systemd/system/sysctl-hardening.service`                   | Re-applies the file after `network-online.target`                          |
| `/etc/systemd/journald.conf.d/99-vps-limits.conf`                | `SystemMaxUse=200M`, `RuntimeMaxUse=100M`, `MaxRetentionSec=14day`         |
| `/etc/cron.allow`, `/etc/at.allow`                               | The single line `root`, mode 600                                           |
| `/root/.<user>-credentials`                                      | User, password, SSH port, timestamp — mode 600                             |
| `/var/log/sysctl-hardening-<timestamp>.log`                      | Output of the sysctl pass                                                  |

The drop-in is named `00-` on purpose: sshd keeps the **first** value it reads and drop-ins are read in
lexicographic order, so `00-` wins over Ubuntu's `50-cloud-init.conf`. It pins `Port`, `AddressFamily inet`,
`ListenAddress 0.0.0.0`, `PermitRootLogin no`, `AllowUsers <user>`, the auth block, and then
`MaxAuthTries 3`, `MaxSessions 3`, `MaxStartups 10:30:60`, `LoginGraceTime 30`, `ClientAliveInterval 300`,
forwarding/tunnel/X11/agent all off, `PermitUserEnvironment no`, `Compression no`.

`/etc/ssh/sshd_config` itself is never edited — it is backed up before the drop-in is written, and the
backup is deleted once the run succeeds.

## Safety mechanisms

### Verification, not assumption

After the sshd restart the script reads the *effective* config with `sshd -T` — `PermitRootLogin`, the auth
method, the port — and checks `ss -tln` for a listener on the new port and for the absence of an IPv6 one.
A key is verified with `ssh-keygen -l -f` **before** root login is disabled. `net.ipv4.tcp_syncookies` is
read back after the sysctl pass, because `/etc/sysctl.conf` is read last by `sysctl --system` and a provider
image once overrode the hardened value from there.

### Rollback on failure

`trap rollback_on_failure EXIT` is armed at the top of `main()`. Any exit before `SCRIPT_SUCCEEDED=true`:

- restores `sshd_config` and the drop-in, then restarts sshd if `sshd -t` passes;
- unmasks and re-enables `ssh.socket`, restoring the original `ssh.service` enablement;
- restores `jail.local` and `/etc/sudoers.d/<user>`;
- restores the UFW state files **and** the previous enabled/disabled state;
- removes the sysctl unit and disarms the auto-revert timer.

The created *account* is never deleted — it is reported instead, with a pointer to the credentials file.
UFW is rolled back by restoring `user.rules`, `user6.rules`, `ufw.conf` and `/etc/default/ufw`, because
`ufw delete` has no inverse.

`SCRIPT_SUCCEEDED=true` is set **before** the last two steps (default-user removal, history clearing) on
purpose: a failure there must not undo working SSH, and is surfaced as a non-zero exit after the summary has
already printed the credentials.

### Auto-revert: the confirm window

This is the only mechanism that recovers a server nobody can log into. Before the first access-affecting
change it snapshots `/etc/ssh` + `/etc/ufw` + `/etc/default/ufw` into `/root/.pre-hardening-ssh.tar`
(mode 600) and arms `hardening-autorevert.timer`. If the timer fires, it puts SSH and the firewall back the
way they were, unmasks `ssh.socket` and stops Fail2Ban. Cancel it from the new session:

```bash
sudo /usr/local/sbin/hardening-confirm
```

The timer is restarted at every prompt and again just before the summary, so time spent answering questions
does not eat the window. The printed "test in a new terminal" warning is advice — *this* is the recovery.

> ⚠️ RISK: a hardening run changes the SSH port, the auth method and the firewall in one pass, so a mistake
> ends remote access. Rollback: keep the current session open and test a new one before closing it, or run
> with `--confirm-window 10` so the pre-hardening `/etc/ssh` and UFW state come back automatically.

## UFW rules it will and will not touch

The goal state is "only `<port>/tcp` reachable", but existing rules belong to the operator:

| Rule                                                                       | Treatment                            |
| -------------------------------------------------------------------------- | ------------------------------------ |
| Its own `LIMIT` on another `N/tcp` — left by an earlier run on another port | Removed silently                     |
| The blanket `ALLOW 22/tcp` that `add_*_xrdp.sh` leaves behind              | Removed silently                     |
| Anything else open from `Anywhere` — 80/443, a bare `ufw allow 80`, udp, a range, an app profile | Listed, removed only after an explicit yes |
| Any rule restricted to a source IP                                         | Never touched, and named in the summary |

That last row is why the final summary says "also open: …" instead of claiming a single open port — the
claim stays honest. If the `LIMIT` rule for the SSH port is missing after `ufw --force enable`, the run
fails and rolls back rather than leaving SSH firewalled off.

## Re-runs

Re-running is safe, and is the supported way to change the port or add a key: the user is reused, the sshd
drop-in and `jail.local` are rewritten, journald is skipped if already configured, an existing `LIMIT` rule
is detected instead of duplicated, and `ssh.socket` is not masked twice.

Two things it refuses:

- `--user root` — `PermitRootLogin no` would block that account anyway;
- granting sudo/SSH to an existing **system** account (uid < 1000) without an explicit confirmation.

## After the run

```bash
ssh -p 2244 admin@<ip>
sudo -i
shred -u /root/.admin-credentials     # once the password is stored elsewhere
```

| Log          | Command                                                                |
| ------------ | ---------------------------------------------------------------------- |
| UFW          | `sudo tail -f /var/log/ufw.log`                                        |
| Fail2Ban     | `sudo journalctl -u fail2ban -f` · `sudo fail2ban-client status sshd` |
| SSH          | `sudo journalctl -u ssh -f` · `sudo tail -f /var/log/auth.log`        |
| Martians     | `sudo tail -f /var/log/kern.log`                                       |
| sysctl pass  | `sudo cat /var/log/sysctl-hardening-*.log`                             |

---

# update_system_all.sh · install_sysupdate.sh

`apt-get update` → `full-upgrade` → `autoremove --purge` → `autoclean`, then `snap refresh` and
`flatpak update` for both the `--user` and `--system` installations. Each optional block is skipped with an
`[INFO]` line when the command is absent, and a failing snap/flatpak step warns instead of aborting the run.
Ends with a reboot notice if `/var/run/reboot-required` exists.

```bash
bash <(wget -qO- .../update_system_all.sh)      # one-time
bash <(wget -qO- .../install_sysupdate.sh)      # then: sysupdate
```

The installer downloads `update_system_all.sh`, compares its SHA256 against a pinned `EXPECTED_SHA256`, runs
`bash -n` on it, and installs it atomically to `/usr/local/bin/sysupdate` (`755`, root:root) via a staged
temp file. An identical file already in place is reported as up to date and nothing is written.

# service-manager.sh · install_svcctl.sh

A deliberately small `systemctl` wrapper: the action must be one of
`start` · `stop` · `restart` · `enable` · `disable` · `status`, and the service one of `postgresql` or
`docker` (`pg`, `postgres` are aliases; `all` expands to both). Anything else is refused — that allowlist is
the whole point of the script.

```bash
bash <(wget -qO- .../install_svcctl.sh)

svcctl status all
svcctl start postgresql
svcctl stop docker
```

`stop` and `restart` execute immediately, with no confirmation. `status` uses `--no-pager` and degrades to a
warning if a unit cannot be read, so `svcctl status all` does not abort on the first missing service.

## Checksum pinning — update in lockstep

`install_svcctl.sh` pins the SHA256 of `service-manager.sh`, and `install_sysupdate.sh` pins the one of
`update_system_all.sh`. Editing either script without recomputing its checksum makes the installer fail
closed. That is the supply-chain check working, not a bug:

```bash
sha256sum server-scripts/service-manager.sh
sha256sum server-scripts/update_system_all.sh
```

Both installers also validate the pinned value itself against `^[[:xdigit:]]{64}$` before comparing.

---

# add_gnome_xrdp.sh · add_xfce_xrdp.sh

The same script twice, differing only in the desktop: `ubuntu-gnome-desktop` with a `gnome-session`
`.xsession`, or `xfce4 xfce4-goodies` with `startxfce4`. XFCE is the lighter choice and the one to prefer on
a small VPS.

```bash
bash <(wget -qO- .../add_xfce_xrdp.sh)
```

**Order of operations, and it matters:** system update → install UFW → *make sure the current SSH port stays
open* → add the RDP rule → enable UFW → install the desktop and xrdp → create the sudo user and its session
files → deny root in `/etc/pam.d/xrdp-sesman` → only then `systemctl enable --now xrdp`. The firewall is up
before xrdp ever listens, and the service starts only after root login has been denied.

The SSH port is resolved from `$SSH_PORT`, else from the 4th field of `$SSH_CONNECTION`, else from
`sshd -T`; if none of those yields a valid port the script aborts rather than guess 22.

Two prompts: the new sudo username (`root` rejected — PAM would refuse the session anyway) and an optional
trusted IPv4. With an IP the rule becomes `ufw allow from <ip> to any port 3389 proto tcp`; empty means
`3389/tcp` open to the world, and the script says so with a warning. The user is created with
`--disabled-password` followed by an interactive `passwd`, so the RDP password never appears in argv.

> ⚠️ RISK: enabling UFW with a wrong SSH rule, or restarting xrdp, ends the current remote session.
> Rollback: from a second open SSH session or the provider's console run `sudo ufw disable`, or
> `sudo systemctl start xrdp`.

Note that these scripts leave a blanket `ALLOW 22/tcp` behind. `configuring_server.sh` recognises that
specific rule as its own and removes it without asking.

---

# Testing

| Layer    | Where                                                               | Covers                                                             |
| -------- | ------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Unit     | `.claude/testing/unit/*.bats`                                       | Pure logic: parsing, validation, rule classification               |
| Scenario | `.claude/testing/{own-script,svcctl,sysupdate,xrdp}/`                | Whole scripts inside systemd Docker containers, driven by `expect` |

What no container can prove — a real SSH lockout, UFW actually filtering packets, Fail2Ban actually banning,
host sysctl, reboot persistence, a working xrdp session — is listed in
[`.claude/testing/unit/README.md`](../.claude/testing/unit/README.md) and needs a real VPS.

Before any change here is done:

```bash
bash .claude/lint.sh    # shfmt -d → shellcheck -x -S style → bats
```
