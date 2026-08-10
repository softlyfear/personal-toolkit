#!/usr/bin/env bash
#
# cosmos_node_commands.sh — Cosmos validator helper functions
#
# Usage:  customize variables below, then source this file or append to .bash_profile
#         source cosmos_node_commands.sh
#
# Set project-specific values before sourcing:
#   addbash, chainid, project, token, decimals, wallet_name
#


# =============================================================================
# Project variables (customize per chain fork)
# =============================================================================

addbash="${addbash:-}"
chainid="${chainid:-}"
project="${project:-}"
token="${token:-}"
# Number of zeros in the minimal denomination (6 is standard for most Cosmos SDK
# chains, but not universal — check your fork's decimals before delegating).
decimals="${decimals:-6}"
# Keyring key name used across all delegate/rewards/unjail/voting commands.
wallet_name="${wallet_name:-wallet}"


# =============================================================================
# Checks and confirmations
# =============================================================================

_cosmos_require_vars() {
  local name=""

  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      printf 'Error: variable %s is not set\n' "$name" >&2
      return 1
    fi
  done
}

_cosmos_require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: command not found: %s\n' "$command_name" >&2
    return 1
  fi
}

_cosmos_denom_amount() {
  local quantity="$1"
  local zeros=""
  printf -v zeros '%0*d' "$decimals" 0
  printf '%s' "${quantity}${zeros}${token}"
}

_cosmos_confirm_transaction() {
  local description="$1"
  local answer=""

  printf '%s\n' "⚠️ RISK: this sends an on-chain transaction (${description}). Rollback: once included in a block the transaction cannot be undone; check the network, wallet, and parameters." >&2
  printf 'Continue on network %s? [y/N]: ' "$chainid" >&2
  IFS= read -r answer

  case "${answer,,}" in
    y | yes) return 0 ;;
    *)
      printf 'Transaction cancelled\n' >&2
      return 1
      ;;
  esac
}


# =============================================================================
# Validator commands
# =============================================================================

# Add auto-source hook to bash profile on login
add() {
  local script_path="${addbash:-${BASH_SOURCE[0]:-cosmos_node_commands.sh}}"
  local script_dir=""
  local quoted_path=""
  local line=""
  local profile="${HOME:-}/.bash_profile"

  [[ -n "${HOME:-}" ]] || {
    printf 'Error: HOME variable is not set\n' >&2
    return 1
  }

  if [[ "$script_path" != /* ]]; then
    script_dir="$(cd -- "$(dirname -- "$script_path")" && pwd -P)" || return 1
    script_path="${script_dir}/$(basename -- "$script_path")"
  fi

  printf -v quoted_path '%q' "$script_path"
  line="source ${quoted_path}"
  touch "$profile"
  if grep -qF "$line" "$profile"; then
    echo -e "\033[35mAlready present in ${profile}\033[97m"
    return 0
  fi
  printf '%s\n' "$line" >> "$profile"
}

# Delegate tokens to own validator
delegate() {
  local quantity=""
  local amount=""

  _cosmos_require_vars project chainid token || return 1
  _cosmos_require_command "$project" || return 1

  echo -e "\033[35mHow many tokens delegate? Enter an integer\033[97m"
  IFS= read -r quantity
  if [[ ! "$quantity" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Error: quantity must be a positive integer\n' >&2
    return 1
  fi

  amount="$(_cosmos_denom_amount "$quantity")"
  _cosmos_confirm_transaction "delegating ${amount}" || return 0

  "${project}" tx staking delegate \
    "$("${project}" keys show "${wallet_name}" --bech val -a)" \
    "$amount" \
    --from "${wallet_name}" --chain-id "${chainid}" \
    --gas-prices "0.1${token}" --gas-adjustment 1.5 --gas auto -y
}

# Show wallet balance
balance() {
  _cosmos_require_vars project || return 1
  _cosmos_require_command "$project" || return 1

  "${project}" q bank balances "$("${project}" keys show "${wallet_name}" -a)"
  echo -e "\033[35mDivide by 1$(printf '%0*d' "$decimals" 0) for whole tokens (${decimals} decimal places)\033[97m"
}

# Follow node logs
logs() {
  _cosmos_require_vars project || return 1
  sudo journalctl -u "${project}" -f --no-hostname -o cat
}

# Show sync status and latest block height
status() {
  local status_json=""

  _cosmos_require_vars project || return 1
  _cosmos_require_command "$project" || return 1
  _cosmos_require_command jq || return 1

  status_json="$("${project}" status 2>&1)" || {
    printf 'Error: failed to get node status\n' >&2
    return 1
  }
  jq -r '.sync_info.catching_up // .SyncInfo.catching_up // empty' <<< "$status_json"
  jq -r '.sync_info.latest_block_height // .SyncInfo.latest_block_height // empty' <<< "$status_json"
}

# Withdraw all staking rewards
rewards() {
  _cosmos_require_vars project chainid token || return 1
  _cosmos_require_command "$project" || return 1
  _cosmos_confirm_transaction "withdrawing all staking rewards" || return 0

  "${project}" tx distribution withdraw-all-rewards \
    --from "${wallet_name}" --chain-id "${chainid}" \
    --gas-prices "0.1${token}" --gas-adjustment 1.5 --gas auto -y
}

# Unjail validator
unjail() {
  _cosmos_require_vars project chainid token || return 1
  _cosmos_require_command "$project" || return 1
  _cosmos_confirm_transaction "unjailing the validator" || return 0

  "${project}" tx slashing unjail \
    --from "${wallet_name}" --chain-id "${chainid}" \
    --gas-prices "0.1${token}" --gas-adjustment 1.5 --gas auto -y
}

# Restart node systemd unit
restart() {
  local answer=""

  _cosmos_require_vars project || return 1

  printf '%s\n' "⚠️ RISK: restarting stops the validator from participating in consensus while it restarts (possible missed blocks). Rollback: the node resyncs automatically after restart; no manual rollback needed." >&2
  printf 'Restart %s? [y/N]: ' "${project}" >&2
  IFS= read -r answer

  case "${answer,,}" in
    y | yes) ;;
    *)
      printf 'Restart cancelled\n' >&2
      return 0
      ;;
  esac

  sudo systemctl restart "${project}"
}

# Vote on governance proposal
voting() {
  local id=""
  local selection=""

  _cosmos_require_vars project chainid token || return 1
  _cosmos_require_command "$project" || return 1

  echo -e "\033[35mEnter id proposals\033[97m"
  IFS= read -r id
  if [[ ! "$id" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Error: proposal ID must be a positive integer\n' >&2
    return 1
  fi

  echo -e "\033[35mEnter yes or no small case\033[97m"
  IFS= read -r selection
  if [[ "$selection" != "yes" && "$selection" != "no" ]]; then
    printf 'Error: only yes or no are allowed\n' >&2
    return 1
  fi

  _cosmos_confirm_transaction "voting ${selection} on proposal ${id}" || return 0
  "${project}" tx gov vote "${id}" "${selection}" \
    --from "${wallet_name}" --chain-id "${chainid}" \
    --gas-prices "0.1${token}" --gas-adjustment 1.5 --gas auto -y
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
