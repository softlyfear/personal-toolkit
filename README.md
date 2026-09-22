# personal-toolkit

> Bash utilities for **Ubuntu (latest LTS)** — fetched and run straight from GitHub, no clone required.

**Author:** [softlyfear](https://github.com/softlyfear)

## What's inside

| Folder                                   | Contents                                              | Details                                     |
| ---------------------------------------- | ----------------------------------------------------- | ------------------------------------------- |
| **[`server-scripts/`](server-scripts/)** | VPS hardening, system updates, `svcctl`, xrdp desktops | [README](server-scripts/README.md)          |
| **[`dev-tools/`](dev-tools/)**           | `devsetup` installer, FastAPI `Makefile` template      | [README](dev-tools/README.md)               |
| **[`cli/`](cli/)**                       | `claude-auto-ping`, `pdf-prep` — small Python tools    | [README](cli/README.md)                     |
| **[`web3/`](web3/)**                     | Cosmos and Ethereum node helpers · unmaintained        | [README](web3/README.md)                    |
| `.claude/`                               | Tooling only: the quality gate and all tests           | [RULES.md](.claude/RULES.md)                |

## Quick start

| Goal                                  | One-liner                                                       |
| ------------------------------------- | --------------------------------------------------------------- |
| Harden a fresh VPS                    | `bash <(wget -qO- .../server-scripts/configuring_server.sh)`    |
| Update everything (apt + snap + flat) | `bash <(wget -qO- .../server-scripts/update_system_all.sh)`     |
| Install dev tools                     | `bash <(wget -qO- .../dev-tools/install-dev-tools.sh)`          |
| Add a remote desktop                  | `bash <(wget -qO- .../server-scripts/add_xfce_xrdp.sh)`         |

`...` stands for `https://raw.githubusercontent.com/softlyfear/personal-toolkit/main` — the full URLs are
in the sections below.

## Contributing

Bash standards for this repository are fixed in [`.claude/RULES.md`](.claude/RULES.md). Before any change is
considered done:

```bash
bash .claude/lint.sh    # shfmt -d, then shellcheck -x -S style, then bats .claude/testing/unit/
```

Requires `shfmt`, `shellcheck`, `bats` and `git`. Test layers and the list of things only a real VPS can
verify are described in [`.claude/testing/unit/README.md`](.claude/testing/unit/README.md).

---

## Server

Full reference — [`server-scripts/README.md`](server-scripts/README.md)

### Hardening

[`configuring_server.sh`](server-scripts/configuring_server.sh) — first-run VPS setup.

**Requirements:** root · interactive TTY (SSH session) · after setup — test SSH in a **new terminal**

**Prompts:** SSH key only? → default **yes** · username → default `admin` · password setup or NOPASSWD sudo

|                   | Key mode (default)                        | Password mode |
| ----------------- | ----------------------------------------- | ------------- |
| **Auth**          | publickey · ed25519/ecdsa · rsa rejected  | password only |
| **Sudo user**     | `admin` (or custom) · `AllowUsers`        | same          |
| **Sudo password** | optional NOPASSWD — default **no**        | required      |
| **Root SSH**      | disabled                                  | disabled      |

|                  |                                                                                                                                                                                             |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Firewall**     | UFW deny incoming · `${PORT}/tcp` (`limit`) · logging on. Blanket rules on other ports are removed only after you confirm; rules restricted to a source IP are kept and listed in the summary |
| **Also applied** | Fail2Ban (sshd · banaction=ufw · systemd backend) · unattended-upgrades (no auto-reboot) · NTP · sysctl hardening · journald limits (200M / 14 days) · cron/at → root only                    |
| **Safety**       | rollback on failure · `ssh.socket` masked if port ≠ 22 · IPv4 only · optional `--confirm-window` auto-revert · password also written to `/root/.<user>-credentials` (mode 600)                |

**Install**

```bash
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/server-scripts/configuring_server.sh)
```

Default port `2244/tcp` · custom port · optional flags:

```bash
bash <(wget -qO- .../configuring_server.sh) 2255
bash <(wget -qO- .../configuring_server.sh) --user softly --password-file /root/.new-user-pass
bash <(wget -qO- .../configuring_server.sh) -u admin -p 'StrongP@ssw0rd!'
bash <(wget -qO- .../configuring_server.sh) 2255 --confirm-window 10
```

Without flags: username prompt · password step asks **generate secure password?** (default yes) or manual
entry · credentials in the summary.

<details>
<summary><strong>All flags</strong></summary>

<br>

| Flag               | Short | Value     | Default            | Description                                                                                                                                                                                            |
| ------------------ | ----- | --------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| _(positional)_     |       | `port`    | `2244`             | SSH port                                                                                                                                                                                               |
| `--user`           | `-u`  | `NAME`    | prompt → `admin`   | sudo username (`root` not allowed)                                                                                                                                                                     |
| `--password-file`  |       | `PATH`    | —                  | password from a file — recommended for automation, keeps it out of `ps`/shell history                                                                                                                  |
| `--password`       | `-p`  | `PASS`    | prompt or generate | user password — skips the password step. Visible via `ps`/`/proc` while the script runs; prefer `--password-file`                                                                                      |
| `--confirm-window` |       | `MINUTES` | off                | arm an auto-revert: SSH config and firewall return to their pre-hardening state after `MINUTES` (5–1440) unless you run `sudo /usr/local/sbin/hardening-confirm`. Use it when you have no console access |
| `--help`           | `-h`  |           |                    | show help and exit                                                                                                                                                                                     |

</details>

**Connect**

```bash
ssh -p 2244 admin@<ip>
sudo -i
```

<details>
<summary><strong>Logs</strong></summary>

<br>

| Source           | Command                                     |
| ---------------- | ------------------------------------------- |
| UFW              | `sudo tail -f /var/log/ufw.log`             |
| UFW (empty log)  | `sudo grep UFW /var/log/syslog \| tail -30` |
| Fail2Ban         | `sudo journalctl -u fail2ban -f`            |
| Banned IPs       | `sudo fail2ban-client status sshd`          |
| SSH              | `sudo journalctl -u ssh -f`                 |
| Auth             | `sudo tail -f /var/log/auth.log`            |
| Martians         | `sudo tail -f /var/log/kern.log`            |
| Sysctl (per run) | `sudo cat /var/log/sysctl-hardening-*.log`  |

</details>

---

### System Updates

`apt` + `snap` + `flatpak` (when installed).

```bash
# one-time
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/server-scripts/update_system_all.sh)

# install global command
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/server-scripts/install_sysupdate.sh)
sysupdate
```

---

### Service Management

`svcctl` — wrapper for `postgresql` and `docker`.

```bash
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/server-scripts/install_svcctl.sh)

svcctl status all
svcctl start postgresql
svcctl stop docker
```

---

### Remote Desktop (xrdp)

GNOME or XFCE (lighter) + new sudo user · RDP port `3389` · **Ubuntu only**.
During setup you can optionally restrict RDP access to a trusted source IP.

```bash
# GNOME
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/server-scripts/add_gnome_xrdp.sh)

# XFCE — lighter
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/server-scripts/add_xfce_xrdp.sh)
```

---

## Dev Tools

Full reference — [`dev-tools/README.md`](dev-tools/README.md)

### devsetup

Packages: `git` · `uv` · `make` · `docker` · `postgresql`

```bash
# all (default)
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/dev-tools/install-dev-tools.sh)

# selected
bash <(wget -qO- .../install-dev-tools.sh) git uv

# interactive
bash <(wget -qO- .../install-dev-tools.sh) --interactive
```

### FastAPI Makefile

Copy into your project — `uv`, ruff, tests, migrations, Docker.

```bash
wget -O Makefile https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/dev-tools/Makefile
make help
```

<details>
<summary><strong>Common commands</strong></summary>

<br>

| Command          | Does                     |
| ---------------- | ------------------------ |
| `make install`   | sync dependencies        |
| `make run`       | dev server               |
| `make test`      | pytest                   |
| `make fmt`       | ruff format + fix        |
| `make check`     | fmt + type               |
| `make migrate`   | create + apply migration |
| `make docker-up` | start containers         |

</details>

---

## CLI

Full reference — [`cli/README.md`](cli/README.md)

### claude-auto-ping

Pings Claude Code on a schedule (MSK: `07:00` · `12:01` · `17:02` · `22:03`) — each message opens a new
5-hour session window. `uv` + venv · no API key · auto-start via a systemd user unit.

**Install** — as your normal user, never root. Same command twice: the first run installs the tools and
stops if the Claude CLI is not logged in yet, the second finishes the setup.

```bash
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/personal-toolkit/main/cli/claude-auto-ping/install.sh)
```

Details — [`cli/claude-auto-ping/README.md`](cli/claude-auto-ping/README.md)

### pdf-prep

Local PDF toolbox: **compress**, **split into upload-ready parts for a Claude Project**, **translate**.
Drop files into `task/`, run one command, collect the results from `result/`. `uv` + venv · OCR via
EasyOCR (CPU) · Claude CLI by default for translation, API providers optional.

**Install** — from a clone, nothing else is fetched from this repository:

```bash
bash cli/pdf-prep/install.sh
```

```bash
pdf-prep split                        # compress + cut into parts with a manifest
pdf-prep compress --target-mb 20      # compress only, verified lossless by default
pdf-prep translate --lang russian     # translate into Markdown, DOCX or an overlay PDF
```

Details — [`cli/pdf-prep/README.md`](cli/pdf-prep/README.md)

---

## Web3

Run from a local clone. **Not currently maintained** — kept for reference.
Full reference — [`web3/README.md`](web3/README.md)

| Script                                                    | Provides                                                                                                                                              |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [`cosmos_node_commands.sh`](web3/cosmos_node_commands.sh) | `delegate` · `balance` · `rewards` · `unjail` · `voting` · `status` · `logs` · `restart` · `add` (on-chain actions and `restart` ask for confirmation) |
| [`geth+beacon.sh`](web3/geth+beacon.sh)                   | Sepolia geth + Prysm beacon                                                                                                                           |

```bash
# Cosmos — set variables in file, then:
source web3/cosmos_node_commands.sh && help

# Ethereum
bash web3/geth+beacon.sh
```
