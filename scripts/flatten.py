from brownie import CubeViews


def main():
    source = CubeViews.get_verification_info()["flattened_source"]

    with open("flat.sol", "w") as f:
        f.write(source)
