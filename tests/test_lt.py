from brownie import reverts, ZERO_ADDRESS
import pytest





def test_add_lt(a, LeveragedTokenPool, LeveragedToken, MockToken, MockAggregatorV3Interface):
    deployer, alice = a[:2]

    # deploy pool
    usdc = deployer.deploy(MockToken, "usdc", "usdc", 6)
    pool = deployer.deploy(LeveragedTokenPool, usdc)
    assert pool.baseToken() == usdc

    weth = deployer.deploy(MockToken, "Wrapped Ether", "WETH", 18)
    tx = pool.addLeveragedToken(weth, 0, {"from": deployer})

    ethbull = LeveragedToken.at(tx.return_value)
    assert ethbull.name() == "Charm 2X Long Wrapped Ether"
    assert ethbull.symbol() == "charmWETHBULL"
    assert pool.numLeveragedTokens() == 1
    assert pool.leveragedTokens(0) == ethbull

    added, tokenSymbol, side, maxPoolShare, depositPaused, withdrawPaused, lastSquarePrice = pool.params(ethbull)
    assert added
    assert tokenSymbol == "WETH"
    assert side == 0
    assert maxPoolShare == 0
    assert not depositPaused
    assert not withdrawPaused
    assert lastSquarePrice == 0

    tx = pool.addLeveragedToken(weth, 1, {"from": deployer})

    ethbear = LeveragedToken.at(tx.return_value)
    assert ethbear.name() == "Charm 2X Short Wrapped Ether"
    assert ethbear.symbol() == "charmWETHBEAR"
    assert pool.numLeveragedTokens() == 2
    assert pool.leveragedTokens(1) == ethbear

    added, tokenSymbol, side, maxPoolShare, depositPaused, withdrawPaused, lastSquarePrice = pool.params(ethbear)
    assert added
    assert tokenSymbol == "WETH"
    assert side == 1
    assert maxPoolShare == 0
    assert not depositPaused
    assert not withdrawPaused
    assert lastSquarePrice == 0





def test_oracle(a, LeveragedTokenPool, MockAggregatorV3Interface, MockToken):
    return
    deployer, alice = a[:2]

    # deploy pool
    baseToken = deployer.deploy(MockToken, "usdc", "usdc", 6)
    pool = deployer.deploy(LeveragedTokenPool, baseToken)

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

