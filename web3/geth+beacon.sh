# обновляем пакеты
sudo apt -y update && sudo apt -y upgrade

# устанавливаем зависимости
sudo apt-get install coreutils curl iptables build-essential \
git wget lz4 jq make gcc nano automake autoconf tmux htop \
nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar \
clang bsdmainutils ncdu unzip libleveldb-dev -y

# обновляем дистрибутив
sudo apt dist-upgrade -y && sudo apt autoremove -y

# устанавливаем 'ethereum'
sudo add-apt-repository -y ppa:ethereum/ethereum && \
sudo apt-get update && \
sudo apt-get install ethereum -y

# скачиваем 'geth'
wget https://gethstore.blob.core.windows.net/builds/geth-linux-amd64-1.15.11-36b2371c.tar.gz && \
tar -xvf geth-linux-amd64-1.15.11-36b2371c.tar.gz && \
mv geth-linux-amd64-1.15.11-36b2371c/geth /usr/bin/geth && \
rm -Rvf geth-linux-amd64-1.15.11-36b2371c*

# проверяем присутствие 'geth'
which geth

# создаём каталог для работы 'geth'
mkdir -p $HOME/geth/data

# генерируем секреты
sudo mkdir -p /var/lib/secrets
sudo openssl rand -hex 32 | tr -d '\n' | sudo tee /var/lib/secrets/jwt.hex > /dev/null

# включаем ufw
# Доступ к порту разрешённому ip для большей безопасности
# sudo ufw allow from <IP_вашего_ПК> to any port <PORT>
sudo ufw allow 9999/tcp
sudo ufw allow 3500/tcp
sudo ufw allow 4000/tcp
sudo ufw allow 30303/tcp
sudo ufw allow 30303/udp
sudo ufw allow 12000/udp
sudo ufw allow 13000/tcp
sudo ufw allow 22/tcp
sudo ufw allow 443/tcp

# создаём сервис 'geth'
sudo tee /etc/systemd/system/geth.service > /dev/null <<EOF
[Unit]
Description=Geth
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
Restart=always
RestartSec=5s
User=root
WorkingDirectory=${HOME}/geth
ExecStart=$(which geth) \
  --sepolia \
  --syncmode snap \
  --http \
  --http.addr "0.0.0.0" \
  --http.port 9999 \
  --authrpc.addr "127.0.0.1" \
  --authrpc.port 8551 \
  --http.api "eth,net,engine,admin" \
  --http.corsdomain "*" \
  --http.vhosts "*" \
  --datadir ${HOME}/geth/data \
  --authrpc.jwtsecret /var/lib/secrets/jwt.hex
[Install]
WantedBy=multi-user.target
EOF

# запускаем 'geth'
sudo systemctl enable geth && \
sudo systemctl daemon-reload && \
sudo systemctl restart geth

# смотрим логи
journalctl -f -n 100 -u geth -o cat

# дождитесь следующего лога, в котором говорится, что необходимо запустить ещё и 'beacon-client'
WARN [05-13|11:22:05.061] Post-merge network, but no beacon client seen. Please launch one to follow the chain!

# подготавливаем директории
mkdir -p $HOME/beacon/bin $HOME/beacon/data
curl https://raw.githubusercontent.com/prysmaticlabs/prysm/master/prysm.sh --output $HOME/beacon/bin/prysm.sh
chmod +x $HOME/beacon/bin/prysm.sh

# создаём сервис 'beacon'
sudo tee /etc/systemd/system/beacon.service > /dev/null <<EOF
[Unit]
Description=Prysm Beacon
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
Restart=always
RestartSec=5s
User=root
ExecStart=${HOME}/beacon/bin/prysm.sh beacon-chain \
  --sepolia \
  --http-modules=beacon,config,node,validator \
  --rpc-host=0.0.0.0 \
  --rpc-port=4000 \
  --grpc-gateway-host=0.0.0.0 \
  --grpc-gateway-port=3500 \
  --datadir ${HOME}/beacon/data \
  --execution-endpoint=http://127.0.0.1:8551 \
  --checkpoint-sync-url=https://checkpoint-sync.sepolia.ethpandaops.io/ \
  --genesis-beacon-api-url=https://checkpoint-sync.sepolia.ethpandaops.io/ \
  --jwt-secret=/var/lib/secrets/jwt.hex \
  --accept-terms-of-use \
  --subscribe-all-data-subnets
[Install]
WantedBy=multi-user.target
EOF

# запускаем 'beacon'
sudo systemctl enable beacon && \
sudo systemctl daemon-reload && \
sudo systemctl restart beacon

# смотрим логи
journalctl -f -n 100 -u beacon -o cat

# теперь нужно дождаться, пока оба сервиса синхронизируются

# проверка geth
curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
-H "Content-Type: application/json" http://localhost:9999 | jq

# проверка beacon
curl -s http://localhost:3500/eth/v1/node/syncing | jq

# ждём час-два до полной синхронизации