from brownie import (
    accounts,
    ChainlinkFeedsRegistry,
    CubePool,
    MockToken,
)
import time


LONG = False
SHORT = True


def main():
    deployer = accounts.load("deployer")
    balance = deployer.balance()

    feeds = deployer.deploy(ChainlinkFeedsRegistry, publish_source=True)
    toBytes32 = feeds.stringToBytes32

    feeds.addEthFeed(toBytes32("BTC"), "0x2431452A0010a43878bF198e170F6319Af6d27F4")
    feeds.addUsdFeed(toBytes32("ETH"), "0x8A753747A1Fa494EC906cE90E9f37563A8AF630e")
    feeds.addUsdFeed(toBytes32("LINK"), "0xd8bD0a1cB028a31AA859A21A3758685a95dE4623")
    feeds.addUsdFeed(toBytes32("SNX"), "0xE96C4407597CD507002dF88ff6E0008AB41266Ee")

    pool = deployer.deploy(CubePool, feeds, publish_source=True)
    time.sleep(15)

    pool.setProtocolFee(2000) # 20%
    pool.setMaxPoolBalance(100e18) # 100 eth

    pool.addCubeToken("BTC", LONG)
    pool.addCubeToken("BTC", SHORT)
    pool.addCubeToken("ETH", LONG)
    pool.addCubeToken("ETH", SHORT)
    pool.addCubeToken("LINK", LONG)
    pool.addCubeToken("LINK", SHORT)
    pool.addCubeToken("SNX", LONG)
    pool.addCubeToken("SNX", SHORT)

    pool.setDepositWithdrawFee(pool.cubeTokens(0), 150)  # 1.5%
    pool.setDepositWithdrawFee(pool.cubeTokens(1), 150)  # 1.5%
    pool.setDepositWithdrawFee(pool.cubeTokens(2), 150)  # 1.5%
    pool.setDepositWithdrawFee(pool.cubeTokens(3), 150)  # 1.5%
    pool.setDepositWithdrawFee(pool.cubeTokens(4), 300)  # 3%
    pool.setDepositWithdrawFee(pool.cubeTokens(5), 300)  # 3%
    pool.setDepositWithdrawFee(pool.cubeTokens(6), 300)  # 3%
    pool.setDepositWithdrawFee(pool.cubeTokens(7), 300)  # 3%

    print(f"Pool address: {pool.address}")
    print(f"Gas used in deployment: {(balance - deployer.balance()) / 1e18:.4f} ETH")
