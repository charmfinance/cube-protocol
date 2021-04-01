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


def main():
    deployer = accounts.load("deployer")
    balance = deployer.balance()

    gas_strategy = GasNowScalingStrategy()

    feeds = deployer.deploy(
        ChainlinkFeedsRegistry, publish_source=True, gas_price=gas_strategy
    )

    feeds.addEthFeed(
        "BTC",
        "0x2431452A0010a43878bF198e170F6319Af6d27F4",
        {"gas_price": gas_strategy},
    )
    feeds.addUsdFeed(
        "ETH",
        "0x8A753747A1Fa494EC906cE90E9f37563A8AF630e",
        {"gas_price": gas_strategy},
    )
    feeds.addUsdFeed(
        "LINK",
        "0xd8bD0a1cB028a31AA859A21A3758685a95dE4623",
        {"gas_price": gas_strategy},
    )
    feeds.addUsdFeed(
        "SNX",
        "0xE96C4407597CD507002dF88ff6E0008AB41266Ee",
        {"gas_price": gas_strategy},
    )

    cubeTokenImpl = deployer.deploy(
        CubeToken, publish_source=True, gas_price=gas_strategy
    )
    cubeTokenImpl.initialize(ZERO_ADDRESS, "", False, {"gas_price": gas_strategy})

    pool = deployer.deploy(
        CubePool, feeds, cubeTokenImpl, publish_source=True, gas_price=gas_strategy
    )
    time.sleep(15)

    pool.setProtocolFee(2000, {"gas_price": gas_strategy})  # 20%
    pool.setMaxPoolBalance(100e18, {"gas_price": gas_strategy})  # 100 eth

    pool.addCubeToken("BTC", LONG, 150, 0, {"gas_price": gas_strategy})
    pool.addCubeToken("BTC", SHORT, 150, 0, {"gas_price": gas_strategy})
    pool.addCubeToken("ETH", LONG, 150, 0, {"gas_price": gas_strategy})
    pool.addCubeToken("ETH", SHORT, 150, 0, {"gas_price": gas_strategy})
    pool.addCubeToken("LINK", LONG, 300, 0, {"gas_price": gas_strategy})
    pool.addCubeToken("LINK", SHORT, 300, 0, {"gas_price": gas_strategy})
    pool.addCubeToken("SNX", LONG, 300, 0, {"gas_price": gas_strategy})
    pool.addCubeToken("SNX", SHORT, 300, 0, {"gas_price": gas_strategy})

    print(f"Pool address: {pool.address}")
    print(f"Gas used in deployment: {(balance - deployer.balance()) / 1e18:.4f} ETH")
