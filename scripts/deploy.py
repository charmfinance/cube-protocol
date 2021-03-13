from brownie import (
    accounts,
    ChainlinkFeedsRegistry,
    CubePool,
    MockToken,
)


def main():
    deployer = accounts.load("deployer")
    balance = deployer.balance()

    feeds = deployer.deploy(ChainlinkFeedsRegistry, publish_source=True)
    feeds.addUsdFeed("ETH", "0x8A753747A1Fa494EC906cE90E9f37563A8AF630e")
    feeds.addEthFeed("BTC", "0x2431452A0010a43878bF198e170F6319Af6d27F4")
    feeds.addUsdFeed("SNX", "0xE96C4407597CD507002dF88ff6E0008AB41266Ee")

    pool = deployer.deploy(CubePool, feeds, publish_source=True)
    pool.setTradingFee(100)  # 1%

    pool.addCubeToken("BTC", 0)
    pool.addCubeToken("BTC", 1)
    pool.addCubeToken("SNX", 0)
    pool.addCubeToken("SNX", 1)

    print(f"Pool address: {pool.address}")
    print(f"Gas used in deployment: {(balance - deployer.balance()) / 1e18:.4f} ETH")
