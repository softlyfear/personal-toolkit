###############################################
# Automatic setup
# source <(curl -s https://raw.githubusercontent.com/softlyfear/my-script/refs/heads/main/server-scripts/add_xfce_xrdp.sh)
###############################################


# Обновление системы
sudo apt update && sudo apt upgrade -y

# Установка XFCE
sudo apt install xfce4 xfce4-goodies -y

# Установа xrdp для поддержки RDP
sudo apt install xrdp -y

# Проверка статуса xrdp и запуск, если не активен
sudo systemctl status xrdp || sudo systemctl start xrdp

# Включение автозапуска xrdp
sudo systemctl enable xrdp

# Настройка XFCE как сессию по умолчанию для xrdp
echo xfce4-session > ~/.xsession

# Открытие порта 3389 в брандмауэре
sudo ufw allow 3389 && sudo ufw reload

# (Опционально) Проверь логи xrdp при проблемах
# sudo cat /var/log/xrdp.log && sudo cat /var/log/xrdp-sesman.log