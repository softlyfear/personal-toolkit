#!/bin/bash
#################################################
# Configuring the server to run as a root user
#################################################
# Automatic setup
# source <(curl -s https://gist.githubusercontent.com/softlyfear/a98b91607633ba5a1f7bb8c2a9dffb12/raw/5f8e21fb0f9c8bc996d3783aaf2d0d6e457d129b/serversetup.sh)
#################################################

#1 update server
echo -e "\033[35mUpdate & Upgrade Server\033[97m"
sudo apt update && \
sudo apt upgrade -y && \
echo -e "\033[35m-----------------------------------------------------------------------------------\033[97m"

#2 setting up ssh login & disable password login
echo -e "\033[35mSetting up ssh login & disable password login\033[97m"
if [[ ! -d "/root/.ssh" ]]; then
  mkdir root/.ssh || exit
fi
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCorSuABVdEg6tXEyQQ5N1UW44qSKt15QVjtC2u1O866fPApcenxZAat0ZX54esA9Btf63WlfMPypsjFr3FtQU/AK3GR+5+SZoQTLKqxwfg3GVzksRitkbt33ppB5xI0H2c5oPP9atGpoOCHrTPBqEMD0QrP28UsHY4MQeCjwnbrDdUmMPb52lAEyQmHhMzNwvohYxSIkU/uWuK21e2kQ+F69vuPyDMEqiCDlq/Xmw6VY+SmQS+r2U1ap0J0dwM+5/ZFIlrrUU0fVVF9sXvmXI7yIZTT8LoVhNKNMPsmifzQvsIsNYnLPVidutMqWrWskDFCBQpKPgoDM1KHibKxMq1URplmhBAVVz9J3MewqDZ+844fHHcBEXtmcVstxAoVo2Wf9AeX5/V0eMdv6W81CD9FvmnHMOfHHmoLmD+GCWmbeXnM3TYCIJ0wWYEzKkYV1iMo/d8GYtxEO/ZLjzU2uurqPREN3zNMJxhe5s/115vSTtHIrK4fEjg4d/9miiMoj0= malygos@WIN-ODSO4HDAV3H
" > /root/.ssh/authorized_keys
sudo sed -i 's|^PermitRootLogin .*|PermitRootLogin prohibit-password|' /etc/ssh/sshd_config
sudo sed -i 's/^ChallengeResponseAuthentication\s.*$/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#PasswordAuthentication\s.*$/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#PermitEmptyPasswords\s.*$/PermitEmptyPasswords no/' /etc/ssh/sshd_config
sudo sed -i 's/^#PubkeyAuthentication\s.*$/PubkeyAuthentication yes/' /etc/ssh/sshd_config
echo HostKeyAlgorithms +ssh-rsa >> /etc/ssh/sshd_config
echo PubkeyAcceptedAlgorithms +ssh-rsa >> /etc/ssh/sshd_config
sudo systemctl restart sshd
echo -e "\033[35m-----------------------------------------------------------------------------------\033[97m"

#3 install fail2Ban
echo -e "\033[35mInstalling Fail2Ban\033[97m"
sudo apt install -y fail2ban && \
echo -e "\033[35m-----------------------------------------------------------------------------------\033[97m"

#4 install and configure Unf
echo -e "\033[35mInstalling and configure Unf\033[97m"
sudo apt-get install -y ufw && \
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw enable
echo -e "\033[35m-----------------------------------------------------------------------------------\033[97m"
echo -e "\033[35mInstallation and setup complete\033[97m"
echo -e "\033[35m-----------------------------------------------------------------------------------\033[97m"

