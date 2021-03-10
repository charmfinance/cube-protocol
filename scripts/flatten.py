from brownie import LViews


def main():
    source = LViews.get_verification_info()["flattened_source"]

    with open("flat.sol", "w") as f:
        f.write(source)
