#!/bin/bash
###############################################
# Server hardening script (run as root)
# Ubuntu/Debian focused (tested logic for Ubuntu 24.04)
###############################################
set -euo pipefail

#----------------------------------------------
# Helper functions
#----------------------------------------------
info()  { echo -e "\033[35m[INFO]  $1\033[0m"; }
ok()    { echo -e "\033[32m[OK]    $1\033[0m"; }
warn()  { echo -e "\033[33m[WARN]  $1\033[0m"; }
err()   { echo -e "\033[31m[ERROR] $1\033[0m"; exit 1; }
sep()   { echo -e "\033[35m-----------------------------------------------------------------\033[0m"; }

#----------------------------------------------
# 0. Root check + params
#----------------------------------------------
if [[ $EUID -ne 0 ]]; then
  err "This script must be run as root. Use: sudo bash $0"
fi

SSH_PORT="${1:-2222}"
KEEP_PORT_22_FALLBACK="true" # safer rollout

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  err "Invalid SSH port: $SSH_PORT"
fi

# Non-interactive apt/dpkg (avoid mail/setup dialogs)
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a

sep
info "Server hardening script started"
info "SSH port target: $SSH_PORT"
info "Ping replies: DISABLED (always)"
sep

#----------------------------------------------
# 1. Update & upgrade
#----------------------------------------------
info "Updating package lists and upgrading packages..."
apt-get update || err "apt-get update failed"
apt-get upgrade -y || err "apt-get upgrade failed"
ok "System updated"

#----------------------------------------------
# 2. Install essential packages (no mail extras)
#----------------------------------------------
sep
info "Installing essential security packages..."
apt-get install -y --no-install-recommends \
  fail2ban \
  ufw \
  unattended-upgrades \
  || err "Package installation failed"
ok "Packages installed"

#----------------------------------------------
# 3. Configure automatic security updates
#----------------------------------------------
sep
info "Configuring unattended-upgrades..."
cat > /etc/apt/apt.conf.d/51custom-unattended-upgrades << 'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF
dpkg-reconfigure -f noninteractive unattended-upgrades || err "unattended-upgrades reconfigure failed"
ok "Automatic security updates configured"

#----------------------------------------------
# 4. SSH key setup (root)
#----------------------------------------------
sep
info "Setting up SSH key authentication..."

mkdir -p /root/.ssh
chmod 700 /root/.ssh
chown root:root /root/.ssh

echo ""
info "Enter SSH public key OR path to .pub file:"
read -r sshkey_input

if [[ -f "$sshkey_input" ]]; then
  sshkey="$(tr -d '\r\n' < "$sshkey_input")"
  ok "Public key loaded from file: $sshkey_input"
else
  sshkey="$(echo "$sshkey_input" | tr -d '\r\n')"
  ok "Public key entered manually"
fi

if ! echo "$sshkey" | grep -qE "^(ssh-(rsa|dss|ecdsa|ed25519)|ecdsa-[a-zA-Z0-9]+) "; then
  err "Invalid SSH public key format"
fi

touch /root/.ssh/authorized_keys
if grep -qF "$sshkey" /root/.ssh/authorized_keys; then
  warn "Key already exists in /root/.ssh/authorized_keys"
else
  echo "$sshkey" >> /root/.ssh/authorized_keys
  ok "SSH key added"
fi

chmod 600 /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys

#----------------------------------------------
# 5. Harden SSH (with Ubuntu 24 ssh.socket fix)
#----------------------------------------------
sep
info "Hardening SSH configuration..."

SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN_FILE="${SSHD_DROPIN_DIR}/99-hardening.conf"

cp "$SSHD_MAIN" "${SSHD_MAIN}.bak_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$SSHD_DROPIN_DIR"

cat > "$SSHD_DROPIN_FILE" << EOF
Port $SSH_PORT
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
UsePAM yes
X11Forwarding no
AllowAgentForwarding no
MaxAuthTries 3
MaxSessions 3
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
EOF

# Critical for Ubuntu 24+: socket activation may force port 22
if systemctl list-unit-files | grep -q '^ssh.socket'; then
  if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
    warn "ssh.socket is active/enabled; disabling it to honor Port from sshd_config"
    systemctl disable --now ssh.socket || err "Failed to disable ssh.socket"
  fi
fi

info "Validating sshd config..."
sshd -t || err "sshd config validation failed"

if systemctl list-unit-files | grep -q '^ssh\.service'; then
  systemctl enable ssh.service || true
  systemctl restart ssh.service || err "Failed to restart ssh.service"
elif systemctl list-unit-files | grep -q '^sshd\.service'; then
  systemctl enable sshd.service || true
  systemctl restart sshd.service || err "Failed to restart sshd.service"
else
  err "No ssh service unit found (ssh.service/sshd.service)"
fi

# Verify effective port and listening socket before firewall changes
if ! sshd -T | awk '/^port /{print $2}' | grep -qx "$SSH_PORT"; then
  err "Effective sshd port does not include $SSH_PORT"
fi

if ! ss -tln | awk '{print $4}' | grep -qE "(^|:)$SSH_PORT$"; then
  err "sshd is not listening on port $SSH_PORT"
fi

ok "SSH configured and listening on port $SSH_PORT"

#----------------------------------------------
# 6. Configure UFW (AFTER SSH verification)
#----------------------------------------------
sep
info "Configuring UFW firewall..."
ufw default deny incoming
ufw default allow outgoing

ufw allow "${SSH_PORT}/tcp"
ufw limit "${SSH_PORT}/tcp"

if [[ "$SSH_PORT" != "22" && "$KEEP_PORT_22_FALLBACK" == "true" ]]; then
  ufw allow 22/tcp || true
  warn "Temporary 22/tcp fallback left enabled for safe rollout."
fi

ufw --force enable
ok "UFW enabled"

#----------------------------------------------
# 7. Configure Fail2Ban
#----------------------------------------------
sep
info "Configuring Fail2Ban..."
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
banaction = ufw

[sshd]
enabled  = true
port     = $SSH_PORT
backend  = systemd
maxretry = 3
EOF

systemctl enable fail2ban
systemctl restart fail2ban
ok "Fail2Ban configured"

#----------------------------------------------
# 8. Kernel/network hardening (sysctl)
#----------------------------------------------
sep
info "Applying kernel/network hardening..."
cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_echo_ignore_all = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
EOF

sysctl --system > /dev/null 2>&1 || err "Failed to apply sysctl settings"
ok "Kernel/network hardening applied (ping disabled)"

#----------------------------------------------
# 9. Restrict cron and at
#----------------------------------------------
sep
info "Restricting cron and at to root only..."
echo "root" > /etc/cron.allow
echo "root" > /etc/at.allow
chmod 600 /etc/cron.allow /etc/at.allow 2>/dev/null || true
ok "cron/at restricted"

#----------------------------------------------
# 10. Final summary
#----------------------------------------------
sep
ok "SERVER HARDENING COMPLETE"
sep
echo ""
info "Summary:"
echo "  - System updated/upgraded"
echo "  - SSH hardened, key-only auth"
echo "  - SSH port set to: $SSH_PORT"
echo "  - ssh.socket disabled (if present)"
echo "  - UFW enabled + SSH rate limit"
echo "  - Fail2Ban enabled for SSH"
echo "  - Unattended upgrades enabled"
echo "  - Sysctl hardening applied"
echo "  - IPv4 ping replies disabled (always)"
echo ""
warn "DO NOT CLOSE THIS SESSION YET."
echo "Test in a NEW terminal:"
echo "  ssh -p $SSH_PORT root@<your-server-ip>"
if [[ "$SSH_PORT" != "22" && "$KEEP_PORT_22_FALLBACK" == "true" ]]; then
  echo ""
  warn "After successful login on $SSH_PORT, remove fallback rule:"
  echo "  ufw delete allow 22/tcp"
fi
sep