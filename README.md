# my-script

Bash utilities for **Ubuntu / Debian** — run from GitHub, no clone required.

**Author:** [softlyfear](https://github.com/softlyfear)

## Structure

```
my-script/
├── server-scripts/     # VPS hardening, updates, svcctl
├── dev-tools/          # devsetup, FastAPI Makefile
└── web3/               # Cosmos, Ethereum nodes
```

---

## Server

### Hardening

[`configuring_server.sh`](server-scripts/configuring_server.sh) — first-run VPS setup.

**Requirements:** root · interactive TTY · after setup — test SSH in a **new terminal**

**One prompt:** SSH key only? → default **yes** (Enter)

| | Key mode (default) | Password mode |
|---|---|---|
| Auth | publickey · ed25519/ecdsa · rsa rejected | password only |
| Sudo user | `admin` (or custom) · `AllowUsers` | same |
| Sudo password | optional NOPASSWD — default **no** | required |
| Root SSH | disabled in both modes | disabled |

| | |
|---|---|
| Firewall | UFW deny incoming · **only** `${PORT}/tcp` (`limit`) · logging on |
| Also applied | Fail2Ban (sshd) · unattended-upgrades · NTP · sysctl · journald limits · cron/at → root only |
| Safety | rollback on failure · `ssh.socket` masked if port ≠ 22 · IPv4 only |

**Install — download** (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/configuring_server.sh \
  -o /tmp/setup.sh && bash /tmp/setup.sh
```

Default port `2244/tcp` · custom port · optional flags:

```bash
bash /tmp/setup.sh 2255
bash /tmp/setup.sh --user softly --password 'MySecret123'
bash /tmp/setup.sh -u admin -p a3f9c2e1
```

Without flags: username prompt · password step asks **generate hex8?** (default yes) or manual entry · credentials in summary

**Install — one-liner**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/configuring_server.sh)

bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/configuring_server.sh) 2255
```

> One-liner needs a real TTY (SSH session). For SSH key paste, use **download** method.

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

### Remote Desktop (xrdp)

GNOME or XFCE + new sudo user · RDP port `3389`.

```bash
# GNOME
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/add_gnome_xrdp.sh)

# XFCE (lighter)
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/add_xfce_xrdp.sh)
```

---

### System Updates

`apt` + `snap` + `flatpak` (when installed).

```bash
# one-time
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/update_system_all.sh)

# install global command
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/install_sysupdate.sh)
sysupdate
```

---

### Service Management

`svcctl` — wrapper for `postgresql` and `docker`.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/server-scripts/install_svcctl.sh)

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
bash <(curl -fsSL https://raw.githubusercontent.com/softlyfear/my-script/main/dev-tools/install-dev-tools.sh)

# selected
bash <(curl -fsSL .../install-dev-tools.sh) git uv

# interactive
bash <(curl -fsSL .../install-dev-tools.sh) --interactive
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

## Web3

Run from a local clone.

| Script | |
|---|---|
| [`cosmos_node_commands.sh`](web3/cosmos_node_commands.sh) | `balance` · `delegate` · `rewards` · `status` · `logs` |
| [`geth+beacon.sh`](web3/geth+beacon.sh) | Sepolia geth + Prysm beacon |

```bash
# Cosmos — set variables in file, then:
source web3/cosmos_node_commands.sh && help

# Ethereum
bash web3/geth+beacon.sh
```
