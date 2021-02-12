from brownie import reverts, ZERO_ADDRESS
import pytest


def test_oracle(a, LeveragedTokenPool, MockAggregatorV3Interface, MockToken):
    deployer, alice = a[:2]

    # deploy pool
    pool = deployer.deploy(LeveragedTokenPool)

    # deploy tokens
    btc = deployer.deploy(MockToken, "btc", "btc", 18)
    yfi = deployer.deploy(MockToken, "yfi", "yfi", 18)
    doge = deployer.deploy(MockToken, "doge", "doge", 18)

    # deploy and setup feeds
    ethUsd = deployer.deploy(MockAggregatorV3Interface)
    btcUsd = deployer.deploy(MockAggregatorV3Interface)
    yfiEth = deployer.deploy(MockAggregatorV3Interface)

    ethUsd.setDecimals(8)
    btcUsd.setDecimals(8)
    yfiEth.setDecimals(18)

    ethUsd.setPrice(2000e8)
    btcUsd.setPrice(50000e8)
    yfiEth.setPrice(15e18)

    # can't get price before eth/usd price is set
    with reverts("Feed not added"):
        pool.getPrice(yfi)

    # only owner
    with reverts("Ownable: caller is not the owner"):
        pool.setEthUsdFeed(ethUsd, {"from": alice})
    with reverts("Ownable: caller is not the owner"):
        pool.setUsdFeed(btc, btcUsd, {"from": alice})
    with reverts("Ownable: caller is not the owner"):
        pool.setEthFeed(yfi, yfiEth, {"from": alice})

    # set yfi/eth price
    pool.setEthFeed(yfi, yfiEth, {"from": deployer})
    assert pool.ethFeeds(yfi) == yfiEth

    # can't get yfi price yet because eth/usd feed not set
    with reverts("Feed not added"):
        pool.getPrice(yfi)

    # set eth/usd price
    pool.setEthUsdFeed(ethUsd, {"from": deployer})
    assert pool.ethUsdFeed() == ethUsd

    # set btc/usd price
    pool.setUsdFeed(btc, btcUsd, {"from": deployer})
    assert pool.usdFeeds(btc) == btcUsd

    # can get btc price
    assert pool.getPrice(btc) == 50000e18

    # can get yfi price
    assert pool.getPrice(yfi) == 30000e18

    # can't get doge price as no feed has been set
    with reverts("Feed not added"):
        pool.getPrice(doge)

    # remove btc/usd feed
    pool.setUsdFeed(btc, ZERO_ADDRESS, {"from": deployer})

    # can't get btc price any more
    with reverts("Feed not added"):
        pool.getPrice(btc)
    assert pool.getPrice(yfi) == 30000e18

    # remove yfi/eth feed
    pool.setEthFeed(yfi, ZERO_ADDRESS, {"from": deployer})

    # can't get yfi price any more
    with reverts("Feed not added"):
        pool.getPrice(yfi)

