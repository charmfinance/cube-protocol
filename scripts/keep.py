from brownie import CubePool, accounts


POOL = "0x01844e3258f2a61149f4ec6be032d2bbb6dc7ccf"

MAX_STALE_TIME = 3600


def main():
    deployer = accounts.load("deployer")
    balance = deployer.balance()

    pool = CubePool.at(POOL)
    pool.updateAllPrices(MAX_STALE_TIME)

    print(f"Gas used: {(balance - deployer.balance()) / 1e18:.4f} ETH")
