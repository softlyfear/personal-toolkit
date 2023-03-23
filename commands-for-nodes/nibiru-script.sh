#!/bin/bash
###############################
#Cosmos Variables Project forks
###############################

addbash="nibiru"
chainid="nibiru-itn-1"
project="nibid"
token="unibi"

#add a function to the bash profile to run when a user logs in
add() {
  if [[ ! -f "${HOME}"/.bash_profile ]]; then
    touch "${HOME}"/.bash_profile || exit
    source "${HOME}"/.bash_profile
  fi
  echo "source ${addbash}-script.sh" >> .bash_profile
}

#delegate tokens to yourself
delegate() {
  echo -e "\033[35mHow many tokens delegate? Enter an integer\033[97m"
  IFS= read -r quantity
  "${project}" tx staking delegate $("${project}" keys show wallet --bech val -a) "${quantity}"000000"${token}" --from wallet --chain-id "${chainid}" --gas-prices 0.1"${token}" --gas-adjustment 1.5 --gas auto -y
}

#check balance
balance() {
  "${project}" q bank balances $("${project}" keys show wallet -a)
echo -e "\033[35mDivide by 1000 for integers\033[97m"
}

#check logs
logs() {
  sudo journalctl -u "${project}" -f --no-hostname -o cat
}

#check status
status() {
  "${project}" status 2>&1 | jq .SyncInfo.catching_up
  "${project}" status 2>&1 | jq .SyncInfo.latest_block_height
}

#get rewards
rewards() {
  "${project}" tx distribution withdraw-all-rewards --from wallet --chain-id "${chainid}" --gas-prices 0.1"${token}" --gas-adjustment 1.5 --gas auto -y
}

#unjail validator
unjail() {
  "${project}" tx slashing unjail --from wallet --chain-id "${chainid}" --gas-prices 0.1"${token}" --gas-adjustment 1.5 --gas auto -y
}

#restart node
restart() {
  sudo systemctl restart "${project}"
}

#proposals for voting
voting() {
  echo -e "\033[35mEnter id proposals\033[97m"
  IFS= read -r id
  echo -e "\033[35mEnter yes or no small case\033[97m"
  IFS= read -r selection
  if [[ "${selection}" = yes ]]; then
    "${project}" tx gov vote "${id}" "${selection}" --from wallet --chain-id "${chainid}" --gas-prices 0.1"${token}" --gas-adjustment 1.5 --gas auto -y
  elif [[ "${selection}" = no ]]; then
    "${project}" tx gov vote "${id}" "${selection}" --from wallet --chain-id "${chainid}" --gas-prices 0.1"${token}" --gas-adjustment 1.5 --gas auto -y
  fi
}

#list all commands
help() {
  echo -e "
  \033[31mlist commands:\033[97m
    \033[31madd\033[97m - \033[35madd a function to the bash profile to run when a user logs in\033[97m
    \033[31mdelegate\033[97m - \033[35mdelegate tokens to yourself\033[97m
    \033[31mbalance\033[97m - \033[35mcheck balance\033[97m
    \033[31mlogs\033[97m - \033[35mcheck logs\033[97m
    \033[31mstatus\033[97m - \033[35mcheck the synchronization status and show the last block\033[97m
    \033[31mrewards\033[97m - \033[35mreceive rewards from all validators\033[97m
    \033[31munjail\033[97m - \033[35munjail validator\033[97m
    \033[31mrestart\033[97m - \033[35mrestart node\033[97m
    \033[31mvoting\033[97m - \033[35mvote\033[97m
    \033[31mhelp\033[97m - \033[35mlist all commands\033[97m
    "
}
