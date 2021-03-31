from brownie import (
    accounts,
    ChainlinkFeedsRegistry,
    CubePool,
    MockToken,
)
from brownie.network.gas.strategies import GasNowScalingStrategy
import time


LONG = False
SHORT = True


def main():
    deployer = accounts.load("deployer")
    balance = deployer.balance()

    gas_strategy = GasNowScalingStrategy()

    feeds = deployer.deploy(
        ChainlinkFeedsRegistry, publish_source=True, gas_price=gas_strategy
    )
    toBytes32 = feeds.stringToBytes32

    feeds.addEthFeed(
        toBytes32("BTC"),
        "0x2431452A0010a43878bF198e170F6319Af6d27F4",
        gas_price=gas_strategy,
    )
    feeds.addUsdFeed(
        toBytes32("ETH"),
        "0x8A753747A1Fa494EC906cE90E9f37563A8AF630e",
        gas_price=gas_strategy,
    )
    feeds.addUsdFeed(
        toBytes32("LINK"),
        "0xd8bD0a1cB028a31AA859A21A3758685a95dE4623",
        gas_price=gas_strategy,
    )
    feeds.addUsdFeed(
        toBytes32("SNX"),
        "0xE96C4407597CD507002dF88ff6E0008AB41266Ee",
        gas_price=gas_strategy,
    )

    pool = deployer.deploy(CubePool, feeds, publish_source=True, gas_price=gas_strategy)
    time.sleep(15)

    pool.setProtocolFee(2000, gas_price=gas_strategy)  # 20%
    pool.setMaxPoolBalance(100e18, gas_price=gas_strategy)  # 100 eth

    pool.addCubeToken("BTC", LONG, gas_price=gas_strategy)
    pool.addCubeToken("BTC", SHORT, gas_price=gas_strategy)
    pool.addCubeToken("ETH", LONG, gas_price=gas_strategy)
    pool.addCubeToken("ETH", SHORT, gas_price=gas_strategy)
    pool.addCubeToken("LINK", LONG, gas_price=gas_strategy)
    pool.addCubeToken("LINK", SHORT, gas_price=gas_strategy)
    pool.addCubeToken("SNX", LONG, gas_price=gas_strategy)
    pool.addCubeToken("SNX", SHORT, gas_price=gas_strategy)

    pool.setDepositWithdrawFee(pool.cubeTokens(0), 150, gas_price=gas_strategy)  # 1.5%
    pool.setDepositWithdrawFee(pool.cubeTokens(1), 150, gas_price=gas_strategy)  # 1.5%
    pool.setDepositWithdrawFee(pool.cubeTokens(2), 150, gas_price=gas_strategy)  # 1.5%
    pool.setDepositWithdrawFee(pool.cubeTokens(3), 150, gas_price=gas_strategy)  # 1.5%
    pool.setDepositWithdrawFee(pool.cubeTokens(4), 300, gas_price=gas_strategy)  # 3%
    pool.setDepositWithdrawFee(pool.cubeTokens(5), 300, gas_price=gas_strategy)  # 3%
    pool.setDepositWithdrawFee(pool.cubeTokens(6), 300, gas_price=gas_strategy)  # 3%
    pool.setDepositWithdrawFee(pool.cubeTokens(7), 300, gas_price=gas_strategy)  # 3%

    print(f"Pool address: {pool.address}")
    print(f"Gas used in deployment: {(balance - deployer.balance()) / 1e18:.4f} ETH")
