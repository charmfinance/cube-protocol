from brownie import CubePool


def main():
    source = CubePool.get_verification_info()["flattened_source"]

    with open("flat.sol", "w") as f:
        f.write(source)
