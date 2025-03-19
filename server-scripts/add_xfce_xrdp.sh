#!/bin/bash
###############################################
# Automatic setup
# source <(curl -s https://raw.githubusercontent.com/softlyfear/my-script/refs/heads/main/server-scripts/add_xfce_xrdp.sh)
###############################################


# Update the system to ensure all packages are up-to-date
sudo apt update && sudo apt upgrade -y

# Install xfce4 for XFCE desktop experience and xrdp for remote desktop
sudo apt install xfce4 xfce4-goodies xrdp -y

# Add xrdp to ssl-cert group to allow login after setup
sudo adduser xrdp ssl-cert

# Start and enable xrdp service
sudo systemctl start xrdp manual start
sudo systemctl enable xrdp

# Ask for the new username interactively
echo "Введите имя нового пользователя:"
read NEW_USER

# Create a new user with administrative privileges
sudo adduser --gecos "" --disabled-password "$NEW_USER"
sudo passwd "$NEW_USER"  # Interactive password setup

# Add a user to the SUDO group
sudo usermod -aG sudo "$NEW_USER"

# Set up .xsession for XFCE session
sudo -u "$NEW_USER" bash -c "echo 'startxfce4' > /home/$NEW_USER/.xsession"
sudo chown "$NEW_USER:$NEW_USER" /home/$NEW_USER/.xsession

# Set up .xsessionrc for XFCE experience
sudo -u "$NEW_USER" bash -c "echo 'export XAUTHORITY=\${HOME}/.Xauthority' > /home/$NEW_USER/.xsessionrc"
sudo -u "$NEW_USER" bash -c "echo 'export XDG_CURRENT_DESKTOP=XFCE' >> /home/$NEW_USER/.xsessionrc"
sudo chown "$NEW_USER:$NEW_USER" /home/$NEW_USER/.xsessionrc

# Disable root login for xrdp to enhance security
sudo bash -c 'echo "auth required pam_succeed_if.so user != root" >> /etc/pam.d/xrdp-sesman'
sudo systemctl restart xrdp

# Install and configure ufw for firewall management
sudo apt install ufw -y
sudo ufw allow 3389  # Allow RDP port
sudo ufw enable  # Enable firewall