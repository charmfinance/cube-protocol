from brownie import (
    accounts,
    ChainlinkFeedsRegistry,
)
from brownie.network.gas.strategies import GasNowScalingStrategy
import time


# https://docs.chain.link/docs/ethereum-addresses
USD_FEEDS = {
    "AAVE": "0x547a514d5e3769680Ce22B2361c10Ea13619e8a9",
    "BTC": "0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c",
    "ETH": "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419",
    "LINK": "0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c",
    "UNI": "0x553303d460EE0afB37EdFf9bE42922D8FF63220e",
    "YFI": "0xA027702dbb89fbd58938e4324ac03B58d812b0E1",
}
ETH_FEEDS = {}


def main():
    deployer = accounts.load("deployer")
    balance = deployer.balance()

    gas_strategy = GasNowScalingStrategy()

    feeds = deployer.deploy(
        ChainlinkFeedsRegistry, publish_source=True, gas_price=gas_strategy
    )
    time.sleep(5)

    for symbol, feed in USD_FEEDS.items():
        feeds.addUsdFeed(symbol, feed, {"gas_price": gas_strategy})

    for symbol, feed in ETH_FEEDS.items():
        feeds.addEthFeed(symbol, feed, {"gas_price": gas_strategy})

    print(f"Feeds address: {feeds.address}")
    print(f"Gas used in deployment: {(balance - deployer.balance()) / 1e18:.4f} ETH")
