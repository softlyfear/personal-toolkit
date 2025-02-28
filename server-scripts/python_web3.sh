#!/bin/bash
###############################################
# Automatic setup
# source <(curl -s https://raw.githubusercontent.com/softlyfear/my-script/refs/heads/main/server-scripts/python_web3.sh)
###############################################

# Создаём виртуальное окружение в директории .venv
apt install python3-venv -y
python3 -m venv .venv

# Активируем виртуальное окружение
source .venv/bin/activate
# Выйти deactivate

# Устанавливаем web3 в виртуальное окружение
pip install web3 -y
pip install --upgrade web3

echo -e "\033[35meactivate - source .venv/bin/activate\033[97m"
echo -e "\033[35mdeactivate - exit \033[97m"