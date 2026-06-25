#!/usr/bin/env bash
#
# cosmos_node_commands.sh — Cosmos validator helper functions
#
# Usage:  customize variables below, then source this file or append to .bash_profile
#         source cosmos_node_commands.sh
#
# Set project-specific values before sourcing:
#   addbash, chainid, project, token
#


# =============================================================================
# Project variables (customize per chain fork)
# =============================================================================

addbash=""
chainid=""
project=""
token=""


# =============================================================================
# Validator commands
# =============================================================================

# Add auto-source hook to bash profile on login
add() {
  local line="source ${addbash}-script.sh"
  touch .bash_profile
  if grep -qF "$line" .bash_profile; then
    echo -e "\033[35mAlready present in .bash_profile\033[97m"
    return 0
  fi
  echo "$line" >> .bash_profile
}

# Delegate tokens to own validator
delegate() {
  echo -e "\033[35mHow many tokens delegate? Enter an integer\033[97m"
  IFS= read -r quantity
  "${project}" tx staking delegate \
    "$("${project}" keys show wallet --bech val -a)" \
    "${quantity}000000${token}" \
    --from wallet --chain-id "${chainid}" \
    --gas-prices "0.1${token}" --gas-adjustment 1.5 --gas auto -y
}

# Show wallet balance
balance() {
  "${project}" q bank balances "$("${project}" keys show wallet -a)"
  echo -e "\033[35mDivide by 1000 for integers\033[97m"
}

# Follow node logs
logs() {
  sudo journalctl -u "${project}" -f --no-hostname -o cat
}

# Show sync status and latest block height
status() {
  "${project}" status 2>&1 | jq .SyncInfo.catching_up
  "${project}" status 2>&1 | jq .SyncInfo.latest_block_height
}

# Withdraw all staking rewards
rewards() {
  "${project}" tx distribution withdraw-all-rewards \
    --from wallet --chain-id "${chainid}" \
    --gas-prices "0.1${token}" --gas-adjustment 1.5 --gas auto -y
}

# Unjail validator
unjail() {
  "${project}" tx slashing unjail \
    --from wallet --chain-id "${chainid}" \
    --gas-prices "0.1${token}" --gas-adjustment 1.5 --gas auto -y
}

# Restart node systemd unit
restart() {
  sudo systemctl restart "${project}"
}

# Vote on governance proposal
voting() {
  echo -e "\033[35mEnter id proposals\033[97m"
  IFS= read -r id
  echo -e "\033[35mEnter yes or no small case\033[97m"
  IFS= read -r selection
  if [[ "${selection}" == "yes" || "${selection}" == "no" ]]; then
    "${project}" tx gov vote "${id}" "${selection}" \
      --from wallet --chain-id "${chainid}" \
      --gas-prices "0.1${token}" --gas-adjustment 1.5 --gas auto -y
  fi
}


# =============================================================================
# Help
# =============================================================================

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
