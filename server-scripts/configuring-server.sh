#!/bin/bash
###############################################
# Configuring the server to run as a root user
###############################################
# Automatic setup
# source <(curl -s https://raw.githubusercontent.com/softlyfear/my-script/refs/heads/main/server-scripts/configuring-server.sh)
###############################################

###############################################
# 1 update server
###############################################
echo -e "\033[35m-----------------------------------------------------------------\033[97m"
echo -e "\033[35mStarting to set up\033[97m"
echo -e "\033[35m-----------------------------------------------------------------\033[97m"
echo -e "\033[35mUpdate & Upgrade Server\033[97m"
echo -e "\033[35m-----------------------------------------------------------------\033[97m"
sudo apt update && sudo apt upgrade -y || { echo "System update error"; exit 1; }

###############################################
# #2 install fail2Ban
###############################################
echo -e "\033[35m-----------------------------------------------------------------\033[97m"
echo -e "\033[35mInstalling Fail2Ban\033[97m"
echo -e "\033[35m-----------------------------------------------------------------\033[97m"
sudo apt install -y fail2ban && \

###############################################
# 3 install and configure Unf
###############################################
echo -e "\033[35m-----------------------------------------------------------------\033[97m"
echo -e "\033[35mInstalling and configure Unf\033[97m"
echo -e "\033[35m-----------------------------------------------------------------\033[97m"
sudo apt-get install -y ufw && \
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw enable
echo -e "\033[35m-----------------------------------------------------------------\033[97m"
echo -e "\033[35mInstallation and setup complete\033[97m"
echo -e "\033[35m-----------------------------------------------------------------\033[97m"

###############################################
# 4 SSH Login Configuration and Disabling Password Authentication
###############################################
echo -e "\033[35m-----------------------------------------------------------------\033[97m"
echo -e "\033[35mConfiguring SSH login and disabling password authentication\033[97m"
echo -e "\033[35m-----------------------------------------------------------------\033[97m"

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
  echo -e "\033[31mError: This script must be run as root. Use sudo.\033[97m"
  exit 1
fi
echo -e "\033[32mPrivilege check: running as root.\033[97m"

# Check if SSH server is installed
if ! dpkg -l | grep -q openssh-server; then
  echo -e "\033[35mSSH server not found. Installing...\033[97m"
  if ! apt update && apt install -y openssh-server; then
    echo -e "\033[31mError: Failed to install openssh-server. Check your network connection.\033[97m"
    exit 1
  fi
  echo -e "\033[32mSSH server successfully installed.\033[97m"
else
  echo -e "\033[33mSSH server is already installed. Skipping installation.\033[97m"
fi

# Create or verify .ssh directory for root
if [ ! -d /root/.ssh ]; then
  mkdir -p /root/.ssh || {
    echo -e "\033[31mError: Failed to create /root/.ssh directory\033[97m"
    exit 1
  }
  echo -e "\033[32mDirectory /root/.ssh created.\033[97m"
fi

# Set permissions for .ssh
chmod 700 /root/.ssh || {
  echo -e "\033[31mError: Failed to set permissions 700 on /root/.ssh\033[97m"
  exit 1
}
chown root:root /root/.ssh || {
  echo -e "\033[31mError: Failed to set owner root for /root/.ssh\033[97m"
  exit 1
}
echo -e "\033[32mPermissions and owner for /root/.ssh set.\033[97m"

# Add public key (User should manually copy or specify file path)
echo -e "\033[35mEnter your SSH public key or specify the file path:\033[97m"
echo -e "\033[35m(Example: paste from ~/.ssh/id_rsa.pub or specify path like /tmp/key.pub)\033[97m"
read -r sshkey_input
sshkey=""
if [ -f "$sshkey_input" ]; then
  sshkey=$(cat "$sshkey_input" | tr -d '\r\n')
  echo -e "\033[32mPublic key loaded from file $sshkey_input\033[97m"
else
  sshkey=$(echo "$sshkey_input" | tr -d '\r\n')
  echo -e "\033[32mPublic key entered manually\033[97m"
fi

# Validate key format
if ! echo "$sshkey" | grep -qE "^(ssh-(rsa|dss|ecdsa|ed25519)|ecdsa-[a-zA-Z0-9]+)"; then
  echo -e "\033[31mError: Invalid SSH key format. Expected 'ssh-' or 'ecdsa-'.\033[97m"
  exit 1
fi

# Add key to authorized_keys
echo "$sshkey" >> /root/.ssh/authorized_keys || {
  echo -e "\033[31mError: Failed to add key to /root/.ssh/authorized_keys\033[97m"
  exit 1
}
echo -e "\033[32mSSH key added to /root/.ssh/authorized_keys\033[97m"

# Set permissions for authorized_keys
chmod 600 /root/.ssh/authorized_keys || {
  echo -e "\033[31mError: Failed to set permissions 600 on /root/.ssh/authorized_keys\033[97m"
  exit 1
}
chown root:root /root/.ssh/authorized_keys || {
  echo -e "\033[31mError: Failed to set owner root for /root/.ssh/authorized_keys\033[97m"
  exit 1
}
echo -e "\033[32mPermissions and owner for /root/.ssh/authorized_keys set.\033[97m"

# Backup existing SSH configuration
if [ -f /etc/ssh/sshd_config ]; then
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak_$(date +%Y%m%d_%H%M%S) || {
    echo -e "\033[33mWarning: Failed to create backup of sshd_config\033[97m"
  }
  echo -e "\033[32mBackup of /etc/ssh/sshd_config created.\033[97m"
fi

# Update SSH configuration
echo -e "\033[35mUpdating SSH configuration...\033[97m"
sed -i 's|^#PermitRootLogin .*|PermitRootLogin prohibit-password|' /etc/ssh/sshd_config
sed -i 's|^PermitRootLogin .*|PermitRootLogin prohibit-password|' /etc/ssh/sshd_config
sed -i 's|^#PubkeyAuthentication .*|PubkeyAuthentication yes|' /etc/ssh/sshd_config
sed -i 's|^PubkeyAuthentication .*|PubkeyAuthentication yes|' /etc/ssh/sshd_config
sed -i 's|^#PasswordAuthentication .*|PasswordAuthentication no|' /etc/ssh/sshd_config
sed -i 's|^PasswordAuthentication .*|PasswordAuthentication no|' /etc/ssh/sshd_config
sed -i 's|^#KbdInteractiveAuthentication .*|KbdInteractiveAuthentication no|' /etc/ssh/sshd_config
sed -i 's|^KbdInteractiveAuthentication .*|KbdInteractiveAuthentication no|' /etc/ssh/sshd_config

# Restart SSH service
echo -e "\033[35mRestarting SSH service...\033[97m"
if systemctl is-active --quiet ssh.service; then
  systemctl restart ssh.service || {
    echo -e "\033[31mError: Failed to restart ssh.service\033[97m"
    exit 1
  }
  echo -e "\033[32mSSH service (ssh.service) restarted.\033[97m"
elif systemctl is-active --quiet sshd.service; then
  systemctl restart sshd.service || {
    echo -e "\033[31mError: Failed to restart sshd.service\033[97m"
    exit 1
  }
  echo -e "\033[32mSSH service (sshd.service) restarted.\033[97m"
else
  echo -e "\033[31mError: SSH service not found or inactive. Ensure SSH server is installed.\033[97m"
  exit 1
fi

# Instructions for connecting
echo -e "\033[35mConfiguration complete. Set up your terminal for private key authentication:\033[97m"
echo -e "\033[35m- If using PuTTY: Load your private key (e.g., D:\\Crypto\\ssh-key\\local) in PuTTYgen, save as .ppk, and configure in 'Connection > SSH > Auth'.\033[97m"
echo -e "\033[35m- If using OpenSSH (PowerShell/WSL): Ensure your key (e.g., D:/Crypto/ssh-key/local) is added with 'ssh-add' or specified in ~/.ssh/config.\033[97m"
echo -e "\033[35mConnect using the server IP (find it with 'hostname -I', e.g., 192.168.56.101).\033[97m"
echo -e "\033[35mExample command for OpenSSH: ssh root@192.168.56.101\033[97m"
echo -e "\033[33mNote: Check /var/log/auth.log for troubleshooting.\033[97m"
echo -e "\033[35m-----------------------------------------------------------------\033[97m"
echo -e "\033[32mSSH setup successfully completed\033[97m"
echo -e "\033[35m-----------------------------------------------------------------\033[97m"