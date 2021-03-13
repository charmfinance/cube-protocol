from brownie import CubePool, accounts


POOL = "0xcf1c5cc80a54631e12ee171d3230f863d84fb4d1"

MAX_STALE_TIME = 3600


def main():
    deployer = accounts.load("deployer")
    balance = deployer.balance()

    pool = CubePool.at(POOL)
    pool.updateAllPrices(MAX_STALE_TIME, {"from": deployer})

    print(f"Gas used: {(balance - deployer.balance()) / 1e18:.4f} ETH")
