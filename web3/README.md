# web3

> Two node-operator helpers kept for reference. **Not currently maintained** — no feature work happens here.

They are still held to the repository's formatting and static-analysis gate (`bash .claude/lint.sh`), but
they have no bats unit tests and no Docker scenario suite, so that gate is the only automated check they
get. Both run from a local clone, not `wget`-piped.

| File                                                    | What it is                                                                     |
| ------------------------------------------------------- | -------------------------------------------------------------------------------- |
| [`cosmos_node_commands.sh`](cosmos_node_commands.sh)   | Shell functions for operating a Cosmos SDK validator — **sourced**, not executed |
| [`geth+beacon.sh`](geth+beacon.sh)                      | One-shot setup of a Sepolia execution + consensus node (geth + Prysm beacon)     |

---

## cosmos_node_commands.sh

A function library. It has no `main()` and no `set -euo pipefail` on purpose — strict mode in a sourced file
would change the behaviour of the interactive shell that sources it.

Set the project variables first (they default to empty, and every command refuses to run without the ones it
needs), then source the file:

```bash
export project=<chain-binary> chainid=<chain-id> token=<denom> decimals=6 wallet_name=wallet
source web3/cosmos_node_commands.sh
help
```

| Variable      | Meaning                                                                         |
| ------------- | --------------------------------------------------------------------------------- |
| `project`     | The chain's binary name; also the systemd unit used by `logs` and `restart`      |
| `chainid`     | `--chain-id` passed to every transaction                                        |
| `token`       | Minimal denomination suffix, e.g. `uatom`                                       |
| `decimals`    | Zeros in the minimal denomination — 6 on most forks, **check yours before delegating** |
| `wallet_name` | Keyring key name used by every command                                          |
| `addbash`     | Path `add` writes into `~/.bash_profile`; defaults to this file's resolved path  |

| Command    | Does                                                                                        |
| ---------- | --------------------------------------------------------------------------------------------- |
| `add`      | Appends `source <abs-path>` to `~/.bash_profile`, idempotently                              |
| `delegate` | Prompts for a whole-token amount, resolves the validator address via `keys show --bech val` |
| `balance`  | `q bank balances`, plus a reminder of the decimal shift                                     |
| `rewards`  | `tx distribution withdraw-all-rewards`                                                      |
| `unjail`   | `tx slashing unjail`                                                                        |
| `voting`   | Prompts for a proposal id and `yes`/`no`, then `tx gov vote`                                |
| `status`   | `catching_up` and `latest_block_height` via `jq`, tolerating both status JSON shapes        |
| `logs`     | `journalctl -u <project> -f`                                                                |
| `restart`  | `systemctl restart <project>` after a confirmation                                          |
| `help`     | The same list, in colour                                                                    |

Every transaction uses `--gas auto --gas-adjustment 1.5 --gas-prices 0.1<token> -y`.

> ⚠️ RISK: `delegate`, `rewards`, `unjail` and `voting` broadcast an on-chain transaction, which cannot be
> undone once included in a block; `restart` takes the validator out of consensus and can cost missed
> blocks. Rollback: none for a broadcast transaction — each of these prompts for a `y/N` confirmation
> naming the chain id first, and the node resyncs by itself after a restart.

Two things the validation actually catches: a non-integer amount or proposal id is rejected before anything
is sent, and the validator address is resolved *before* the transaction — a failing `keys show` used to
expand into an empty argument and send the delegation nowhere.

---

## geth+beacon.sh

Sets up a full Sepolia node on Ubuntu (latest LTS) as two systemd services, running as a dedicated
`ethnode` system user with `nologin`:

```bash
bash web3/geth+beacon.sh
SSH_PORT=2244 bash web3/geth+beacon.sh    # when the SSH port cannot be auto-detected
```

**Steps, in order:** apt update/upgrade plus build dependencies → download the pinned geth tarball, verify
its SHA256, install to `/usr/local/bin/geth` → create `ethnode`, the data directories (`750`) and a 32-byte
JWT secret at `/var/lib/secrets/jwt.hex` (`600`) → UFW → `geth.service` → download and verify `prysm.sh`,
then `beacon.service`.

| Setting    | Value                                                                       |
| ---------- | ----------------------------------------------------------------------------- |
| Data root  | `/var/lib/ethnode` — `geth/data`, `beacon/data`, `beacon/bin`               |
| geth RPC   | `127.0.0.1:9999` (`eth,net,web3`), auth RPC `127.0.0.1:8551`                |
| Beacon     | RPC `127.0.0.1:4000`, gateway `127.0.0.1:3500`, checkpoint sync from ethpandaops |
| UFW opens  | `30303/tcp`, `30303/udp`, `12000/udp`, `13000/tcp`, and the detected SSH port |

Nothing but the P2P ports is reachable from outside — both RPC endpoints bind to loopback.

The SSH port is taken from `$SSH_PORT`, else the 4th field of `$SSH_CONNECTION`, else `sshd -T`; if none of
those produces a valid port the script aborts rather than assume 22 and lock you out. Restricting the P2P
ports to a source IP is left to you: `sudo ufw allow from <ip> to any port <port>`.

> ⚠️ RISK: enabling UFW with a wrong SSH rule ends remote access. Rollback: from a second open SSH session
> or the provider's console run `sudo ufw disable`.

### Version pinning — update in lockstep

`GETH_VERSION` is paired with `GETH_ARCHIVE_SHA256`, and `PRYSM_SCRIPT_COMMIT` with `PRYSM_SCRIPT_SHA256`;
`PRYSM_VERSION` is passed to the loader as `Environment=USE_PRYSM_VERSION`. Bumping any version means taking
the matching hash from the upstream release — the same discipline as the installers in `server-scripts/`.

One gap worth knowing: only the `prysm.sh` **loader** is checksum-verified here. The `beacon-chain` binary
itself is downloaded by that loader on the first start of `beacon.service`, which is outside this script's
pinning scope; the version is constrained through `USE_PRYSM_VERSION` only.

### After the run

A full sync takes roughly 1–2 hours. The script prints these at the end:

```bash
curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
  -H 'Content-Type: application/json' http://localhost:9999 | jq
curl -s http://localhost:3500/eth/v1/node/syncing | jq

journalctl -f -n 100 -u geth -o cat
journalctl -f -n 100 -u beacon -o cat
```

geth logging `Post-merge network, but no beacon client seen` before the beacon comes up is expected.
