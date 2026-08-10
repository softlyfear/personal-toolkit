#!/usr/bin/env bash
#
# geth+beacon.sh — Sepolia execution (geth) + consensus (Prysm beacon) node setup
#
# Usage:  bash geth+beacon.sh
# Requires: Ubuntu/Debian; root or sudo
#
# After setup, wait for sync (may take 1–2 hours). Verify with commands at the bottom.
#
set -euo pipefail


# =============================================================================
# Constants
# =============================================================================

readonly GETH_VERSION="1.15.11-36b2371c"
readonly GETH_ARCHIVE="geth-linux-amd64-${GETH_VERSION}.tar.gz"
readonly GETH_URL="https://gethstore.blob.core.windows.net/builds/${GETH_ARCHIVE}"
readonly GETH_ARCHIVE_SHA256="a14a4285daedf75ea04a7a298e6caa48d566a2786c93fc5e86ec2c5998c92455"
readonly GETH_BIN="/usr/local/bin/geth"
readonly JWT_SECRET="/var/lib/secrets/jwt.hex"
readonly NODE_USER="ethnode"
readonly NODE_GROUP="ethnode"
readonly NODE_HOME="/var/lib/ethnode"
readonly GETH_DATA="${NODE_HOME}/geth/data"
readonly BEACON_HOME="${NODE_HOME}/beacon"
readonly PRYSM_VERSION="v7.1.8"
readonly PRYSM_SCRIPT_COMMIT="ea3fbe48b48170e7f7252fbc15e9591d462a0f87"
readonly PRYSM_SCRIPT_URL="https://raw.githubusercontent.com/OffchainLabs/prysm/${PRYSM_SCRIPT_COMMIT}/prysm.sh"
readonly PRYSM_SCRIPT_SHA256="7beb6fc967380d1a82bd88921960c8d02f5321867a05aebf4222a5b600e7dbac"


# =============================================================================
# UI helpers
# =============================================================================

info()  { echo -e "\033[35m[INFO]  $1\033[0m" >&2; }
ok()    { echo -e "\033[32m[OK]    $1\033[0m" >&2; }
warn()  { echo -e "\033[33m[WARN]  $1\033[0m" >&2; }
err()   { echo -e "\033[31m[ERROR] $1\033[0m" >&2; exit 1; }


# =============================================================================
# Helpers
# =============================================================================

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    err "sudo is required when running as non-root user"
  fi
  SUDO="sudo"
fi

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual=""

  [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || err "Invalid expected SHA256 for $file"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || err "SHA256 mismatch for $file"
  ok "SHA256 verified: $(basename "$file")"
}


# =============================================================================
# MAIN
# =============================================================================

# --- Step 1: system packages ---
info "Updating system packages..."
$SUDO apt-get update
$SUDO apt-get upgrade -y

info "Installing build dependencies..."
$SUDO apt-get install -y coreutils curl iptables build-essential \
  git wget lz4 jq make gcc nano automake autoconf tmux htop \
  nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar \
  clang bsdmainutils ncdu unzip gnupg openssl

info "Removing unused packages..."
$SUDO apt-get autoremove -y
ok "System packages ready"

# --- Step 2: geth binary (pinned version in /usr/local/bin) ---
info "Downloading geth ${GETH_VERSION}..."
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
wget -q "${GETH_URL}" -O "${tmpdir}/${GETH_ARCHIVE}"
verify_sha256 "${tmpdir}/${GETH_ARCHIVE}" "$GETH_ARCHIVE_SHA256"
tar -xf "${tmpdir}/${GETH_ARCHIVE}" -C "$tmpdir"
$SUDO install -m 755 "${tmpdir}/geth-linux-amd64-${GETH_VERSION}/geth" "$GETH_BIN"
command -v "$GETH_BIN" >/dev/null || err "geth not found at $GETH_BIN"
ok "geth installed: $($GETH_BIN version | head -1)"

# --- Step 3: data dirs and JWT secret ---
$SUDO groupadd --system "$NODE_GROUP" 2>/dev/null || true
$SUDO useradd --system --gid "$NODE_GROUP" --home-dir "$NODE_HOME" --create-home --shell /usr/sbin/nologin "$NODE_USER" 2>/dev/null || true
$SUDO install -d -m 750 -o "$NODE_USER" -g "$NODE_GROUP" "${GETH_DATA}"
$SUDO install -d -m 750 -o "$NODE_USER" -g "$NODE_GROUP" "${BEACON_HOME}/bin" "${BEACON_HOME}/data"
$SUDO mkdir -p /var/lib/secrets
if [[ ! -f "${JWT_SECRET}" ]]; then
  openssl rand -hex 32 | tr -d '\n' | $SUDO tee "${JWT_SECRET}" >/dev/null
  $SUDO chmod 600 "${JWT_SECRET}"
fi
$SUDO chown "$NODE_USER:$NODE_GROUP" "${JWT_SECRET}"
ok "Data directories and JWT secret ready"

# --- Step 4: UFW ---
# Restrict by source IP for better security:
#   sudo ufw allow from <YOUR_PC_IP> to any port <PORT>
info "Configuring UFW..."
$SUDO apt-get install -y ufw
ssh_port="22"
if command -v sshd >/dev/null 2>&1; then
  ssh_port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
fi
ssh_port="${ssh_port:-22}"
$SUDO ufw allow 30303/tcp
$SUDO ufw allow 30303/udp
$SUDO ufw allow 12000/udp
$SUDO ufw allow 13000/tcp
$SUDO ufw allow "${ssh_port}/tcp"
$SUDO ufw --force enable
ok "UFW enabled"

# --- Step 5: geth systemd unit ---
info "Creating geth.service..."
$SUDO tee /etc/systemd/system/geth.service > /dev/null <<EOF
[Unit]
Description=Geth
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
Restart=always
RestartSec=5s
User=${NODE_USER}
Group=${NODE_GROUP}
WorkingDirectory=${NODE_HOME}/geth
ExecStart=${GETH_BIN} \\
  --sepolia \\
  --syncmode snap \\
  --http \\
  --http.addr "127.0.0.1" \\
  --http.port 9999 \\
  --authrpc.addr "127.0.0.1" \\
  --authrpc.port 8551 \\
  --http.api "eth,net,web3" \\
  --http.corsdomain "http://localhost" \\
  --http.vhosts "localhost" \\
  --datadir ${GETH_DATA} \\
  --authrpc.jwtsecret ${JWT_SECRET}
[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable geth
$SUDO systemctl restart geth
ok "geth service started"

warn "Wait for geth log: 'Post-merge network, but no beacon client seen' — then beacon starts below"
info "Check geth logs: journalctl -f -n 100 -u geth -o cat"

# --- Step 6: Prysm beacon ---
# Note: this script only verifies the SHA256 of the prysm.sh loader. The beacon-chain
# binary itself is downloaded by prysm.sh on the first run of beacon.service — that
# download is outside this script's checksum-pinning scope; the version is constrained
# via Environment=USE_PRYSM_VERSION in the unit file below.
info "Installing Prysm beacon..."
wget -qO "${tmpdir}/prysm.sh" "${PRYSM_SCRIPT_URL}"
verify_sha256 "${tmpdir}/prysm.sh" "$PRYSM_SCRIPT_SHA256"
$SUDO install -m 750 -o "$NODE_USER" -g "$NODE_GROUP" \
  "${tmpdir}/prysm.sh" "${BEACON_HOME}/bin/prysm.sh"

info "Creating beacon.service..."
$SUDO tee /etc/systemd/system/beacon.service > /dev/null <<EOF
[Unit]
Description=Prysm Beacon
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
Restart=always
RestartSec=5s
User=${NODE_USER}
Group=${NODE_GROUP}
Environment=USE_PRYSM_VERSION=${PRYSM_VERSION}
ExecStart=${BEACON_HOME}/bin/prysm.sh beacon-chain \\
  --sepolia \\
  --http-modules=beacon,config,node,validator \\
  --rpc-host=127.0.0.1 \\
  --rpc-port=4000 \\
  --grpc-gateway-host=127.0.0.1 \\
  --grpc-gateway-port=3500 \\
  --datadir ${BEACON_HOME}/data \\
  --execution-endpoint=http://127.0.0.1:8551 \\
  --checkpoint-sync-url=https://checkpoint-sync.sepolia.ethpandaops.io/ \\
  --genesis-beacon-api-url=https://checkpoint-sync.sepolia.ethpandaops.io/ \\
  --jwt-secret=${JWT_SECRET} \\
  --accept-terms-of-use \\
  --subscribe-all-data-subnets
[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable beacon
$SUDO systemctl restart beacon
ok "beacon service started"

# --- Step 7: verification hints ---
echo ""
info "Setup complete. Wait 1–2 hours for full sync, then verify:"
echo ""
echo "  # geth sync status"
echo "  curl -s -X POST --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_syncing\",\"params\":[],\"id\":1}' \\"
echo "    -H 'Content-Type: application/json' http://localhost:9999 | jq"
echo ""
echo "  # beacon sync status"
echo "  curl -s http://localhost:3500/eth/v1/node/syncing | jq"
echo ""
echo "  # follow logs"
echo "  journalctl -f -n 100 -u geth -o cat"
echo "  journalctl -f -n 100 -u beacon -o cat"
