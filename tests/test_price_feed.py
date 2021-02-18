from brownie import reverts, ZERO_ADDRESS
import pytest


def test_price_feed(a, PriceFeed, MockAggregatorV3Interface):
    deployer, alice = a[:2]
    ethusd = deployer.deploy(MockAggregatorV3Interface)
    charmusd = deployer.deploy(MockAggregatorV3Interface)
    charmeth = deployer.deploy(MockAggregatorV3Interface)
    yfieth = deployer.deploy(MockAggregatorV3Interface)
    btcusd = deployer.deploy(MockAggregatorV3Interface)
    ethusd.setPrice()

    priceFeed = deployer.deploy(PriceFeed)
    priceFeed.registerFeed("YFI", "USD", agg)
    priceFeed.registerFeed("ETH", "USD", agg)
    priceFeed.registerFeed("A", "USD", agg)
    priceFeed.registerFeed("B", "USD", agg)
    priceFeed.getPrice("YFI")
    priceFeed.getPrice("B")
    priceFeed.getPrice("D")



