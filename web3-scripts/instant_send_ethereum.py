import json
import time
from web3 import Web3

# Скрипт работает с контрактом напрямую

# Настройки
WALLET_ADDRESS = '' #Адрес отправителя
RECIPIENT_ADDRESS = '' # Адрес получателя
WALLET_PRIVATE_KEY = '' # Приватный ключ
TOKEN_CONTRACT_ADDRESS = '' # Адрес контракта
PUBLIC_RPC_URL = '' # Публичный RPC
CHAIN_ID = 1 # ID сети

# Преобразование адреса в формат контрольной суммы
wallet_address = Web3.to_checksum_address(WALLET_ADDRESS)
recipient_address = Web3.to_checksum_address(RECIPIENT_ADDRESS)

# Загрузка ABI из файла
with open('token_abi.json', 'r') as abi_file:
    token_abi = json.load(abi_file)

# Подключение к сети через публичный RPC
web3 = Web3(Web3.HTTPProvider(PUBLIC_RPC_URL))

# Проверка подключения
if not web3.is_connected():
    print("Не удалось подключиться к Ethereum")
exit()

# Подключение к контракту токена
token_contract = web3.eth.contract(
    address=TOKEN_CONTRACT_ADDRESS, abi=token_abi)


def send_tokens(amount):
    nonce = web3.eth.get_transaction_count(wallet_address)

    # Проверка баланса перед отправкой
    try:
        balance = token_contract.functions.balanceOf(
            wallet_address).call({'gas': 100000})
        print(f"Текущий баланс токенов: {balance}")
    except Exception as e:
        print(f"Ошибка при проверке баланса: {e}")
        return

    # Проверка, что баланс больше нуля и не превышает отправляемую сумму
    if balance == 0 or amount > balance:
        print("Недостаточно токенов для отправки.")
        return

    # Построение транзакции без указания газа
    txn = token_contract.functions.transfer(recipient_address, amount).build_transaction({
        'chainId': CHAIN_ID,
        'nonce': nonce,
        'from': wallet_address,
        'value': 0
    })

    print(f"Построенная транзакция: {txn}")

    # Оценка газа для транзакции
    try:
        gas_estimate = web3.eth.estimate_gas(txn)
    except ValueError as e:
        print(f"Ошибка при оценке газа: {e}")
        return

    gas_limit = int(gas_estimate * 1.5)  # Небольшой запас, умноженный на 1.5 для быстрой отправки

    # Получение текущих цен газа для EIP-1559
    latest_block = web3.eth.get_block('latest')
    base_fee_per_gas = latest_block.get('baseFeePerGas', web3.eth.gas_price)
    # Установка приоритетной платы в 2 Gwei
    max_priority_fee_per_gas = Web3.to_wei(2, 'gwei')

    # Вычисление общей максимальной комиссии за газ
    max_fee_per_gas = base_fee_per_gas + max_priority_fee_per_gas

    # Обновление транзакции с оценкой газа и ценой газа
    txn.update({
        'gas': gas_limit,
        'maxPriorityFeePerGas': max_priority_fee_per_gas,
        'maxFeePerGas': max_fee_per_gas,
    })

    print(f"Транзакция после обновления: {txn}")

    try:
        signed_txn = web3.eth.account.sign_transaction(
            txn, private_key=WALLET_PRIVATE_KEY)
        tx_hash = web3.eth.send_raw_transaction(signed_txn.raw_transaction)
        print(f"Токены отправлены, хэш транзакции: {web3.to_hex(tx_hash)}")
    except Exception as e:
        print(f"Ошибка при отправке транзакции: {e}")


def check_for_new_tokens():
    try:
        balance = token_contract.functions.balanceOf(
            wallet_address).call({'gas': 100000})
        if balance > 0:
            print(f"Обнаружены токены: {balance}")
            send_tokens(balance)
        else:
            print("Токены не обнаружены")
    except Exception as e:
        print(f"Ошибка при проверке баланса: {e}")


while True:
    check_for_new_tokens()
    time.sleep(1)  # Проверка каждую 1 секунды
