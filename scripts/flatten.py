from brownie import LeveragedTokenPool


def main():
    source = LeveragedTokenPool.get_verification_info()["flattened_source"]

    with open("temp.sol", "w") as f:
        f.write(source)
