from brownie import (
    accounts,
    CubePoolMulticall,
)
from brownie.network.gas.strategies import GasNowScalingStrategy


def main():
    deployer = accounts.load("deployer")
    balance = deployer.balance()

    gas_strategy = GasNowScalingStrategy()

    multicall = deployer.deploy(
        CubePoolMulticall, publish_source=True, gas_price=gas_strategy
    )

    print(f"Multicall address: {multicall.address}")
    print(f"Gas used in deployment: {(balance - deployer.balance()) / 1e18:.4f} ETH")
