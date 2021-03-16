from brownie import CubePool, accounts
import os


POOL = "0x0986002aD44fAC6e564c85C63b77F4457bA273Cd"

MAX_STALE_TIME = 3600


def getAccount(account, pw):
    from web3.auto import w3

    with open(account, "r") as f:
        return accounts.add(w3.eth.account.decrypt(f.read(), pw))


def main():
    keeper = getAccount(os.environ["KEEPER_ACCOUNT"], os.environ["KEEPER_PW"])
    # keeper = accounts.load(input("Brownie account: "))

    balance = keeper.balance()

    pool = CubePool.at(POOL)
    pool.updateAll(MAX_STALE_TIME, {"from": keeper})

    print(f"Gas used: {(balance - keeper.balance()) / 1e18:.4f} ETH")
