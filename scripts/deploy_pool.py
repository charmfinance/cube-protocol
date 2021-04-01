from brownie import (
    accounts,
    ChainlinkFeedsRegistry,
    CubePool,
    CubeToken,
    ZERO_ADDRESS,
)
from brownie.network.gas.strategies import GasNowScalingStrategy
import time


LONG = False
SHORT = True


FEEDS_CONTRACT = "0x2a7963958168f32C0250aE470ccB4bEF15DB618e"

SYMBOLS_150 = [
    "BTC",
    "ETH",
]
SYMBOLS_300 = [
    "AAVE",
    "LINK",
    "UNI",
    "YFI",
]


def main():
    deployer = accounts.load("deployer")
    balance = deployer.balance()

    gas_strategy = GasNowScalingStrategy()

    cubeTokenImpl = deployer.deploy(
        CubeToken, publish_source=True, gas_price=gas_strategy
    )
    cubeTokenImpl.initialize(ZERO_ADDRESS, "", False, {"gas_price": gas_strategy})

    pool = deployer.deploy(
        CubePool,
        FEEDS_CONTRACT,
        cubeTokenImpl,
        publish_source=True,
        gas_price=gas_strategy,
    )
    time.sleep(5)

    pool.setProtocolFee(2000, {"gas_price": gas_strategy})  # 20%
    pool.setMaxPoolBalance(100e18, {"gas_price": gas_strategy})  # 100 eth

    # 1.5% fee
    for symbol in SYMBOLS_150:
        pool.addCubeToken(symbol, LONG, 150, 0, {"gas_price": gas_strategy})
        pool.addCubeToken(symbol, SHORT, 150, 0, {"gas_price": gas_strategy})

    # 3% fee
    for symbol in SYMBOLS_300:
        pool.addCubeToken(symbol, LONG, 300, 0, {"gas_price": gas_strategy})
        pool.addCubeToken(symbol, SHORT, 300, 0, {"gas_price": gas_strategy})

    print(f"Pool address: {pool.address}")
    print(f"Gas used in deployment: {(balance - deployer.balance()) / 1e18:.4f} ETH")
