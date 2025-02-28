import time
import logging
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware
from eth_account import Account
import json
import asyncio
from aiohttp import ClientSession

# Скрипт написан с помощью Grok3
# Мониторинг и мгновенная отправка заданного токена в сети Linea

# Настройка логирования
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Подключение к сети Linea
web3 = Web3(Web3.HTTPProvider('https://linea-rpc.publicnode.com'))
web3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)

if not web3.is_connected():
    logger.error("Не удалось подключиться к сети")
    exit(1)

# Адреса и ключи
monitored_address = web3.to_checksum_address('')
destination_address = web3.to_checksum_address('')
private_key = ''  # Храните безопасно!
proxy_address = web3.to_checksum_address('') # Контракт токена

# Загрузка ABI
try:
    with open('token_abi.json', 'r') as abi_file:
        implementation_abi = json.load(abi_file)
except FileNotFoundError:
    logger.error("Файл token_abi.json не найден")
    exit(1)

token = web3.eth.contract(address=proxy_address, abi=implementation_abi)

# Глобальные переменные для оптимизации
last_nonce_check = 0
last_gas_check = 0
nonce = None
max_priority_fee = None
base_fee = None
chain_id = web3.eth.chain_id  # Кэшируем chainId один раз

# Асинхронная функция для взаимодействия с RPC
async def fetch_balance(session):
    return token.functions.balanceOf(monitored_address).call()

async def update_gas_params(session):
    global max_priority_fee, base_fee
    max_priority_fee = web3.eth.max_priority_fee
    block = web3.eth.get_block('latest')
    base_fee = block['baseFeePerGas']
    return max_priority_fee, base_fee

async def send_transaction(balance, gas, nonce, max_fee_per_gas, max_priority_fee):
    tx = token.functions.transfer(destination_address, balance).build_transaction({
        'chainId': chain_id,
        'gas': gas,
        'maxFeePerGas': max_fee_per_gas,
        'maxPriorityFeePerGas': max_priority_fee,
        'nonce': nonce,
    })
    signed_tx = Account.sign_transaction(tx, private_key)
    return web3.eth.send_raw_transaction(signed_tx.raw_transaction)

async def check_and_send():
    global nonce, max_priority_fee, base_fee, last_nonce_check, last_gas_check

    async with ClientSession() as session:
        try:
            # Обновляем nonce и gas только при необходимости
            current_time = time.time()
            if current_time - last_nonce_check > 5:  # Уменьшил интервал до 5 секунд
                nonce = web3.eth.get_transaction_count(monitored_address, 'pending')  # Используем 'pending' для точности
                last_nonce_check = current_time

            if current_time - last_gas_check > 5:
                max_priority_fee, base_fee = await update_gas_params(session)
                last_gas_check = current_time

            # Проверяем баланс
            balance = await fetch_balance(session)
            if balance <= 0:
                logger.info("No balance to transfer.")
                return

            # Оценка газа с запасом
            estimated_gas = token.functions.transfer(destination_address, balance).estimate_gas(
                {'from': monitored_address})
            gas = int(estimated_gas * 1.2)  # Уменьшил запас до 20%, чтобы не переплачивать

            # Агрессивная стратегия газа
            initial_max_priority_fee = max_priority_fee * 2  # Удваиваем начальную приоритетную комиссию
            max_fee_per_gas = int((base_fee + initial_max_priority_fee) * 1.3)  # Увеличиваем на 30%

            # Первая попытка отправки
            multiplier = 1
            while True:
                try:
                    tx_hash = await send_transaction(balance, gas, nonce, max_fee_per_gas, initial_max_priority_fee)
                    logger.info(f"Transaction sent: {tx_hash.hex()}")
                    break
                except ValueError as ve:
                    if 'replacement transaction underpriced' in str(ve):
                        multiplier += 0.5  # Более плавное увеличение газа
                        initial_max_priority_fee = max_priority_fee * (2 + multiplier)
                        max_fee_per_gas = int((base_fee + initial_max_priority_fee) * 1.3)
                    else:
                        logger.error(f"Value Error: {ve}")
                        return

            # Проверка статуса транзакции асинхронно
            receipt = web3.eth.wait_for_transaction_receipt(tx_hash, timeout=30)  # Установил тайм-аут 30 секунд
            if receipt.status == 1:
                logger.info("Transaction confirmed successfully")
            else:
                logger.error("Transaction failed")
        except Exception as e:
            logger.error(f"Ошибка: {e}")

# Основной цикл с асинхронным выполнением
async def main_loop():
    while True:
        await check_and_send()
        await asyncio.sleep(0.5)  # Уменьшил задержку до 0.5 секунды

if __name__ == "__main__":
    asyncio.run(main_loop())
