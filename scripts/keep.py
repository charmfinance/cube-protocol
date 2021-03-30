from brownie import CubePool, accounts
import os


# POOL = "0xdB712E99B24ed9409a8c696Dc321760d4631bF7c"
POOL = "0xd96f154976f4FE8EC168d0dAdd50B68A81DC6dce"

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
