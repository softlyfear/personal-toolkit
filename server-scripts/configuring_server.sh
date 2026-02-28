#!/bin/bash
###############################################
# Server hardening script (run as root)
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
# 0. Root check (FIRST thing)
#----------------------------------------------
if [[ $EUID -ne 0 ]]; then
  err "This script must be run as root. Use: sudo bash $0"
fi

SSH_PORT="${1:-2222}"

sep
info "Server hardening script started"
info "SSH port will be set to: $SSH_PORT"
sep

#----------------------------------------------
# 1. Update & upgrade
#----------------------------------------------
info "Updating and upgrading system packages..."
apt update && apt upgrade -y || err "System update failed"
ok "System updated"

#----------------------------------------------
# 2. Install essential packages
#----------------------------------------------
sep
info "Installing essential security packages..."
apt install -y \
  fail2ban \
  ufw \
  unattended-upgrades \
  apt-listchanges \
  logwatch \
  || err "Package installation failed"
ok "Packages installed"

#----------------------------------------------
# 3. Configure automatic security updates
#----------------------------------------------
sep
info "Configuring automatic security updates..."
echo 'Unattended-Upgrade::Automatic-Reboot "false";' \
  > /etc/apt/apt.conf.d/51custom-unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades
ok "Automatic security updates configured"

#----------------------------------------------
# 4. Configure UFW
#----------------------------------------------
sep
info "Configuring UFW firewall..."
ufw default deny incoming
ufw default allow outgoing

ufw allow "$SSH_PORT"/tcp
ufw limit "$SSH_PORT"/tcp

if [[ "$SSH_PORT" != "22" ]]; then
  ufw delete allow ssh 2>/dev/null || true
  ufw delete limit ssh 2>/dev/null || true
fi

ufw --force enable
ok "UFW configured (port $SSH_PORT, rate-limited)"

#----------------------------------------------
# 5. Configure Fail2Ban
#----------------------------------------------
sep
info "Configuring Fail2Ban..."
cat > /etc/fail2ban/jail.local << JAILEOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
banaction = ufw

[sshd]
enabled  = true
port     = $SSH_PORT
logpath  = %(sshd_log)s
backend  = systemd
maxretry = 3
JAILEOF

systemctl enable fail2ban
systemctl restart fail2ban
ok "Fail2Ban configured and started"

#----------------------------------------------
# 6. SSH key setup
#----------------------------------------------
sep
info "Setting up SSH key authentication..."

mkdir -p /root/.ssh
chmod 700 /root/.ssh
chown root:root /root/.ssh

echo ""
info "Enter your SSH public key or path to a .pub file:"
info "(Example: paste from ~/.ssh/id_rsa.pub or path like /tmp/key.pub)"
read -r sshkey_input

sshkey=""
if [[ -f "$sshkey_input" ]]; then
  sshkey=$(tr -d '\r\n' < "$sshkey_input")
  ok "Public key loaded from file: $sshkey_input"
else
  sshkey=$(echo "$sshkey_input" | tr -d '\r\n')
  ok "Public key entered manually"
fi

if ! echo "$sshkey" | grep -qE "^(ssh-(rsa|dss|ecdsa|ed25519)|ecdsa-[a-zA-Z0-9]+) "; then
  err "Invalid SSH key format. Expected key starting with 'ssh-rsa', 'ssh-ed25519', etc."
fi

if grep -qF "$sshkey" /root/.ssh/authorized_keys 2>/dev/null; then
  warn "This key is already in authorized_keys, skipping"
else
  echo "$sshkey" >> /root/.ssh/authorized_keys
  ok "SSH key added to /root/.ssh/authorized_keys"
fi

chmod 600 /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys

#----------------------------------------------
# 7. Harden sshd_config
#----------------------------------------------
sep
info "Hardening SSH configuration..."

SSHD_CONFIG="/etc/ssh/sshd_config"

cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak_$(date +%Y%m%d_%H%M%S)"
ok "Backup of sshd_config created"

declare -A SSH_SETTINGS=(
  ["Port"]="$SSH_PORT"
  ["PermitRootLogin"]="prohibit-password"
  ["PubkeyAuthentication"]="yes"
  ["PasswordAuthentication"]="no"
  ["KbdInteractiveAuthentication"]="no"
  ["PermitEmptyPasswords"]="no"
  ["X11Forwarding"]="no"
  ["AllowAgentForwarding"]="no"
  ["MaxAuthTries"]="3"
  ["MaxSessions"]="3"
  ["ClientAliveInterval"]="300"
  ["ClientAliveCountMax"]="2"
  ["LoginGraceTime"]="30"
)

for key in "${!SSH_SETTINGS[@]}"; do
  val="${SSH_SETTINGS[$key]}"
  if grep -qE "^#?${key}\b" "$SSHD_CONFIG"; then
    sed -i "s|^#\?${key}.*|${key} ${val}|" "$SSHD_CONFIG"
  else
    echo "${key} ${val}" >> "$SSHD_CONFIG"
  fi
done

info "Validating sshd_config..."
if ! sshd -t; then
  err "sshd_config validation failed! Check the configuration manually."
fi
ok "sshd_config is valid"

if systemctl is-active --quiet ssh.service; then
  systemctl restart ssh.service
  ok "ssh.service restarted"
elif systemctl is-active --quiet sshd.service; then
  systemctl restart sshd.service
  ok "sshd.service restarted"
else
  err "SSH service not found or inactive"
fi

#----------------------------------------------
# 8. Kernel / network hardening (sysctl)
#----------------------------------------------
sep
info "Applying kernel network hardening..."
cat > /etc/sysctl.d/99-hardening.conf << 'SYSEOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
SYSEOF

sysctl --system > /dev/null 2>&1
ok "Kernel hardening applied"

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
sep
ok "SERVER HARDENING COMPLETE"
sep
echo ""
info "Summary of changes:"
echo "  - System updated & upgraded"
echo "  - UFW enabled: deny incoming, allow outgoing"
echo "  - SSH port: $SSH_PORT (rate-limited via ufw limit)"
echo "  - Fail2Ban: enabled for SSH (3 attempts, 1h ban)"
echo "  - SSH: key-only auth, password disabled"
echo "  - SSH: MaxAuthTries=3, LoginGraceTime=30s"
echo "  - SSH: X11/AgentForwarding disabled"
echo "  - Automatic security updates enabled"
echo "  - Kernel hardening (sysctl) applied"
echo "  - cron/at restricted to root"
echo ""
sep
warn "!!! CRITICAL: DO NOT close this session yet !!!"
warn "Open a NEW terminal and verify SSH access:"
echo ""
echo "    ssh -p $SSH_PORT root@<your-server-ip>"
echo ""
warn "Only after successful login in the new terminal, close this one."
sep