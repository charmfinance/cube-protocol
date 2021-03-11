from brownie import (
    accounts,
    ChainlinkFeedsRegistry,
    CubePool,
    CubeViews,
    MockToken,
)


# weth = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"  # mainnet


def main():
    deployer = accounts.load("deployer")
    balance = deployer.balance()

    weth = deployer.deploy(MockToken, "Wrapped Ether", "WETH", 18)
    wbtc = deployer.deploy(MockToken, "Wrapped Bitcoin", "WBTC", 8)
    snx = deployer.deploy(MockToken, "Synthetix Network Token", "SNX", 18)

    feeds = deployer.deploy(ChainlinkFeedsRegistry, weth, publish_source=True)
    feeds.addUsdFeed(weth, "0x8A753747A1Fa494EC906cE90E9f37563A8AF630e")  # eth
    feeds.addEthFeed(wbtc, "0x2431452A0010a43878bF198e170F6319Af6d27F4")  # btc
    feeds.addUsdFeed(snx, "0xE96C4407597CD507002dF88ff6E0008AB41266Ee")  # snx

    pool = deployer.deploy(CubePool, weth, feeds, publish_source=True)

    pool.addLToken(wbtc, 0)
    pool.addLToken(wbtc, 1)
    pool.addLToken(snx, 0)
    pool.addLToken(snx, 1)

    views = deployer.deploy(CubeViews, publish_source=True)

    print(f"Pool address: {pool.address}")
    print(f"Views address: {views.address}")

    print(f"Gas used in deployment: {(balance - deployer.balance()) / 1e18:.4f} ETH")
