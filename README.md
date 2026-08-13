# my-script

Bash utilities for **Ubuntu** (latest LTS) — run from GitHub, no clone required.

**Author:** [softlyfear](https://github.com/softlyfear)

## Structure

```
my-script/
├── server-scripts/     # VPS hardening, updates, svcctl, xrdp
├── dev-tools/          # devsetup, FastAPI Makefile
└── web3/               # Cosmos, Ethereum nodes
```

---

## Server

### Hardening

[`configuring_server.sh`](server-scripts/configuring_server.sh) — first-run VPS setup.

**Requirements:** root · interactive TTY (SSH session) · after setup — test SSH in a **new terminal**

**Prompts:** SSH key only? → default **yes** · username → default `admin` · password setup or NOPASSWD sudo

| | Key mode (default) | Password mode |
|---|---|---|
| Auth | publickey · ed25519/ecdsa · rsa rejected | password only |
| Sudo user | `admin` (or custom) · `AllowUsers` | same |
| Sudo password | optional NOPASSWD — default **no** | required |
| Root SSH | disabled in both modes | disabled |

| | |
|---|---|
| Firewall | UFW deny incoming · **only** `${PORT}/tcp` (`limit`) · logging on |
| Also applied | Fail2Ban (sshd · banaction=ufw · systemd backend) · unattended-upgrades (no auto-reboot) · NTP · sysctl hardening · journald limits (200M / 14 days) · cron/at → root only |
| Safety | rollback on failure · `ssh.socket` masked if port ≠ 22 · IPv4 only |

**Install**

```bash
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/configuring_server.sh)
```

Default port `2244/tcp` · custom port · optional flags:

```bash
bash <(wget -qO- .../configuring_server.sh) 2255
bash <(wget -qO- .../configuring_server.sh) --user softly --password-file /root/.new-user-pass
bash <(wget -qO- .../configuring_server.sh) -u admin -p 'StrongP@ssw0rd!'
```

Without flags: username prompt · password step asks **generate secure password?** (default yes) or manual entry · credentials in summary

<details>
<summary><strong>All flags</strong></summary>

| Flag | Short | Value | Default | Description |
|---|---|---|---|---|
| *(positional)* | | `port` | `2244` | SSH port |
| `--user` | `-u` | `NAME` | prompt → `admin` | sudo username (`root` not allowed) |
| `--password-file` | | `PATH` | — | password from a file — recommended for automation, keeps it out of `ps`/shell history |
| `--password` | `-p` | `PASS` | prompt or generate | user password — skips password step. Visible via `ps`/`/proc` while the script runs; prefer `--password-file` |
| `--help` | `-h` | | | show help and exit |

</details>

**Connect**

```bash
ssh -p 2244 admin@<ip>
sudo -i
```

<details>
<summary><strong>Logs</strong></summary>

| | |
|---|---|
| UFW | `sudo tail -f /var/log/ufw.log` |
| UFW (empty log) | `sudo grep UFW /var/log/syslog \| tail -30` |
| Fail2Ban | `sudo journalctl -u fail2ban -f` |
| Banned IPs | `sudo fail2ban-client status sshd` |
| SSH | `sudo journalctl -u ssh -f` |
| Auth | `sudo tail -f /var/log/auth.log` |
| Martians | `sudo tail -f /var/log/kern.log` |
| Sysctl (per run) | `sudo cat /var/log/sysctl-hardening-*.log` |

</details>

---

### System Updates

`apt` + `snap` + `flatpak` (when installed).

```bash
# one-time
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/update_system_all.sh)

# install global command
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/install_sysupdate.sh)
sysupdate
```

---

### Service Management

`svcctl` — wrapper for `postgresql` and `docker`.

```bash
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/install_svcctl.sh)

svcctl status all
svcctl start postgresql
svcctl stop docker
```

---

## Dev Tools

### devsetup

Packages: `git` · `uv` · `make` · `docker` · `postgresql`

```bash
# all (default)
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/my-script/main/dev-tools/install-dev-tools.sh)

# selected
bash <(wget -qO- .../install-dev-tools.sh) git uv

# interactive
bash <(wget -qO- .../install-dev-tools.sh) --interactive
```

---

### FastAPI Makefile

Copy into your project — `uv`, ruff, tests, migrations, Docker.

```bash
wget -O Makefile https://raw.githubusercontent.com/softlyfear/my-script/main/dev-tools/Makefile
make help
```

<details>
<summary><strong>Common commands</strong></summary>

| | |
|---|---|
| `make install` | sync dependencies |
| `make run` | dev server |
| `make test` | pytest |
| `make fmt` | ruff format + fix |
| `make check` | fmt + type |
| `make migrate` | create + apply migration |
| `make docker-up` | start containers |

</details>

---

## Remote Desktop (xrdp)

GNOME or XFCE (lighter) + new sudo user · RDP port `3389` · **Ubuntu only**.
During setup you can optionally restrict RDP access to a trusted source IP.

```bash
# GNOME
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/add_gnome_xrdp.sh)

# XFCE — lighter
bash <(wget -qO- https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/add_xfce_xrdp.sh)
```

---

## Web3

Run from a local clone.

| Script | |
|---|---|
| [`cosmos_node_commands.sh`](web3/cosmos_node_commands.sh) | `delegate` · `balance` · `rewards` · `unjail` · `voting` · `status` · `logs` · `restart` · `add` (on-chain actions and `restart` ask for confirmation) |
| [`geth+beacon.sh`](web3/geth+beacon.sh) | Sepolia geth + Prysm beacon |

```bash
# Cosmos — set variables in file, then:
source web3/cosmos_node_commands.sh && help

# Ethereum
bash web3/geth+beacon.sh
```
