# my-script

A collection of bash scripts and utilities for quickly setting up Linux servers, dev environments, and Web3 nodes.  
All commands can be run directly from GitHub — no need to clone the repository.

**Platform:** Ubuntu / Debian  
**Author:** [softlyfear](https://github.com/softlyfear)

---

## Table of Contents

- [Repository Structure](#repository-structure)
- [Server](#server)
  - [Setup & Hardening](#setup--hardening)
  - [Remote Desktop (xrdp)](#remote-desktop-xrdp)
  - [System Updates](#system-updates)
  - [Service Management (svcctl)](#service-management-svcctl)
- [Dev Tools](#dev-tools)
  - [devsetup — Install Stack](#devsetup--install-stack)
  - [Makefile for FastAPI](#makefile-for-fastapi)
- [Web3](#web3)

---

## Repository Structure

```
my-script/
├── server-scripts/     # server setup, updates, svcctl, sysupdate
├── dev-tools/          # devsetup, Makefile for FastAPI projects
└── web3/               # Cosmos and Ethereum node scripts
```

---

## Server

### Setup & Hardening

Full initial VPS setup: system update, SSH hardening, UFW, Fail2Ban, automatic security updates, sysctl.

Both SSH modes use the **same port** (default `2244/tcp`). UFW opens **only that single TCP port** via `ufw limit` — not a range, not UDP, not port 22 unless you explicitly choose it.

| Feature | Details |
|---|---|
| SSH (yes) | Sudo user, **publickey only** (ed25519/ecdsa), port `2244/tcp` IPv4 only, `PermitRootLogin no` |
| SSH (no) | Sudo user, **password only**, same port `2244/tcp` IPv4 only, `PermitRootLogin no` |
| Firewall | UFW `default deny incoming` — only `${PORT}/tcp` (rate limit), **logging on** |
| Protection | Fail2Ban (sshd jail on same port), unattended-upgrades, cron/at restricted to root, rollback on failure |
| Network | Sysctl hardening in `98-hardening.conf` (`tcp_syncookies`, `secure_redirects`, `icmp_echo_ignore_broadcasts`) |
| Logs | journald limits in `journald.conf.d/99-vps-limits.conf` (`SystemMaxUse=200M`, `RuntimeMaxUse=100M`, `MaxRetentionSec=14day`) |
| Time | NTP via chrony or `systemd-timesyncd` (auto-detected), verifies `NTPSynchronized=yes` |

At step 5 the script asks one question: **use SSH key-only access on port PORT/tcp?** (default `2244`)  
Answering **no** switches to **login+password on the same port**. Root login is **disabled in both modes**.  
Default is **yes** (Enter or Space).

Pass a custom free port as the first argument: `bash configuring_server.sh 2255`

> **Requires root.** On a fresh VPS you are usually already root — just `bash`. The script installs `sudo` itself; do not use `sudo` before the first run.

In **key-only** mode the script:
- Creates a sudo user (`admin` by default, or enter a custom name)
- Installs your SSH public key for that user (not root) — **ed25519 or ecdsa only** (rsa rejected)
- Asks whether to enable passwordless sudo (`NOPASSWD`; **default no** — sudo requires password)
- Verifies the key before disabling root SSH login
- Sets `AuthenticationMethods publickey` — password and other methods **disabled**
- Rolls back SSH/fail2ban/sudoers changes if a critical step fails

Connect after setup (both modes use the same port):

```bash
ssh -p 2244 admin@<your-server-ip>    # key-only mode
ssh -p 2244 admin@<your-server-ip>    # password mode
sudo -i                               # root shell via sudo (not SSH root login)
```

If you answer **no**, the script creates a sudo user with a password and sets `AuthenticationMethods password` — SSH keys and other methods **disabled**. Only `${PORT}/tcp` is opened in UFW with rate limiting; Fail2Ban `sshd` jail monitors the same port.

> After setup, test SSH in a **new** terminal before closing your current root session.

#### Logs (after hardening)

| What | Command |
|---|---|
| UFW blocks / rate limit | `sudo tail -f /var/log/ufw.log` |
| UFW (if `ufw.log` empty) | `sudo grep UFW /var/log/syslog \| tail -30` |
| Fail2Ban | `sudo journalctl -u fail2ban -f` |
| Banned IPs | `sudo fail2ban-client status sshd` |
| SSH login attempts | `sudo journalctl -u ssh -f` |
| Auth log (classic) | `sudo tail -f /var/log/auth.log` |
| Sysctl apply (per run) | `sudo ls /var/log/sysctl-hardening-*.log` then `sudo cat /var/log/sysctl-hardening-YYYYMMDD_HHMMSS.log` |
| Suspicious packets (martians) | `sudo tail -f /var/log/kern.log` |

Each run writes sysctl output to `/var/log/sysctl-hardening-<timestamp>.log` (timestamp matches backup files, e.g. `20260617_212428`).

**Download and run** (recommended — easy to re-run or inspect the file):

```bash
curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/configuring_server.sh -o /tmp/configuring_server.sh
bash /tmp/configuring_server.sh

# Custom SSH port (must be free), e.g. 2255
bash /tmp/configuring_server.sh 2255
```

**Run without saving** (one-liner):

```bash
curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/configuring_server.sh | bash

# Custom SSH port
curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/configuring_server.sh | bash -s -- 2255
```

---

### Remote Desktop (xrdp)

Install a desktop environment and xrdp for remote GUI access.  
Both scripts also create a new user with `sudo` privileges.

**GNOME Desktop**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/add_gnome_xrdp.sh)
```

**XFCE Desktop** (lighter, lower resource usage)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/add_xfce_xrdp.sh)
```

---

### System Updates

Updates packages via **apt**, **snap**, and **flatpak** (when installed).

**One-time run**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/update_system_all.sh)
```

**Install global `sysupdate` command**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/install_sysupdate.sh)
```

After installation:

```bash
sysupdate
```

---

### Service Management (svcctl)

`svcctl` is a thin wrapper around `systemctl` for `postgresql` and `docker`: start / stop / restart / status / enable / disable.

**Install**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/install_svcctl.sh)
```

**Examples**

```bash
svcctl status all
svcctl start postgresql
svcctl stop docker
svcctl restart postgresql
svcctl enable docker
```

---

## Dev Tools

### devsetup — Install Stack

Installs selected development tools.  
Available packages: `git`, `uv`, `make`, `docker`, `postgresql`.

**Full default stack** (`git`, `uv`, `make`, `docker`, `postgresql`)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/dev-tools/install-dev-tools.sh)
```

**Selected packages only**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/dev-tools/install-dev-tools.sh) git uv make docker postgresql
```

**Interactive selection**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/dev-tools/install-dev-tools.sh) --interactive
```

---

### Makefile for FastAPI

A ready-to-use `Makefile` for FastAPI projects on `uv`: dev server, tests, ruff, type checking, migrations, Docker.

```bash
wget -O Makefile https://raw.githubusercontent.com/softlyfear/my-script/main/dev-tools/Makefile
```

| Command | Description |
|---|---|
| `make install` | Install / sync dependencies |
| `make run` | Dev server with auto-reload |
| `make test` | Run tests |
| `make fmt` | Format and fix code (ruff) |
| `make type` | Type check (`ty`) |
| `make check` | Run `fmt` + `type` |
| `make migrate` | Create and apply migration |
| `make docker-up` | Start containers |

Full list: `make help`

---

## Web3

Scripts for setting up and maintaining blockchain nodes. Run locally from the repository.

| File | Purpose |
|---|---|
| [`web3/cosmos_node_commands.sh`](web3/cosmos_node_commands.sh) | Cosmos node helpers: `balance`, `delegate`, `rewards`, `unjail`, `voting`, `status`, `logs`, `restart` |
| [`web3/geth+beacon.sh`](web3/geth+beacon.sh) | Geth + Beacon node setup for Ethereum |

**Cosmos** — configure variables at the top of the file (`project`, `chainid`, `token`), then:

```bash
source web3/cosmos_node_commands.sh
help
```

**Ethereum (Geth + Beacon)**

```bash
bash web3/geth+beacon.sh
```

---

## Quick Reference

```bash
# Server hardening (as root on fresh VPS)
bash <(curl -fsSL .../configuring_server.sh)

# Dev environment
bash <(curl -fsSL .../install-dev-tools.sh)

# Update everything
sysupdate

# Services
svcctl status all

# Type check (in a FastAPI project with the Makefile)
make type
```

Full URLs are in the sections above.
