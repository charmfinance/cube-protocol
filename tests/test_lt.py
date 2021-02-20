from brownie import reverts, ZERO_ADDRESS
import pytest


LONG, SHORT = 0, 1


def test_price_feed(a, LeveragedTokenPool, MockAggregatorV3Interface):
    deployer, alice = a[:2]

    aaausd = deployer.deploy(MockAggregatorV3Interface)
    aaaeth = deployer.deploy(MockAggregatorV3Interface)
    bbbeth = deployer.deploy(MockAggregatorV3Interface)
    cccusd = deployer.deploy(MockAggregatorV3Interface)
    ethusd = deployer.deploy(MockAggregatorV3Interface)

    pool = deployer.deploy(LeveragedTokenPool)

    with reverts("Ownable: caller is not the owner"):
        pool.registerFeed("AAA", "USD", aaausd, {"from": alice})
    with reverts("Price should be > 0"):
        pool.registerFeed("AAA", "USD", aaausd)
    with reverts("Base symbol should not be empty"):
        pool.registerFeed("", "USD", aaausd)
    with reverts("Quote symbol should not be empty"):
        pool.registerFeed("BTC", "", aaausd)

    aaausd.setPrice(0.1 * 1e8)
    aaaeth.setPrice(0.0000555 * 1e18)
    bbbeth.setPrice(10 * 1e18)
    cccusd.setPrice(100 * 1e8)
    ethusd.setPrice(2000 * 1e8)

    pool.registerFeed("AAA", "USD", aaausd)
    pool.registerFeed("AAA", "ETH", aaaeth)
    pool.registerFeed("BBB", "ETH", bbbeth)
    pool.registerFeed("CCC", "USD", cccusd)

    assert pool.getUnderlyingPrice("AAA") == 0.1 * 1e18
    assert pool.getUnderlyingPrice("CCC") == 100 * 1e18

    with reverts("Feed not added"):
        pool.getUnderlyingPrice("BBB")

    pool.registerFeed("ETH", "USD", ethusd)

    assert pool.getUnderlyingPrice("AAA") == 0.1 * 1e18
    assert pool.getUnderlyingPrice("BBB") == 20000 * 1e18
    assert pool.getUnderlyingPrice("CCC") == 100 * 1e18
    assert pool.getUnderlyingPrice("ETH") == 2000 * 1e18

    cccusd.setPrice(120 * 1e8)
    bbbeth.setPrice(11 * 1e18)
    ethusd.setPrice(2200 * 1e8)

    assert pool.getUnderlyingPrice("BBB") == 24200 * 1e18
    assert pool.getUnderlyingPrice("CCC") == 120 * 1e18

    cccusd.setPrice(0)
    with reverts("Price should be > 0"):
        pool.getUnderlyingPrice("CCC")

    with reverts("Feed not added"):
        pool.getUnderlyingPrice("DDD")
    with reverts("Feed not added"):
        pool.getUnderlyingPrice("USD")


def test_add_lt(a, LeveragedTokenPool, LeveragedToken, MockToken, MockAggregatorV3Interface):
    deployer, alice = a[:2]

    # deploy pool
    pool = deployer.deploy(LeveragedTokenPool)
    btc = deployer.deploy(MockToken, "Bitcoin", "BTC", 8)

    with reverts("Ownable: caller is not the owner"):
        pool.addLeveragedToken(btc, LONG, {"from": alice})

    with reverts("Feed not added"):
        pool.addLeveragedToken(btc, LONG)

    btcusd = deployer.deploy(MockAggregatorV3Interface)
    btcusd.setPrice(50000 * 1e8)
    pool.registerFeed("BTC", "USD", btcusd)

    btcusd.setPrice(1e30)
    with reverts("Price is too high. Might overflow later"):
        pool.addLeveragedToken(btc, LONG)

    btcusd.setPrice(0)
    with reverts("Price should be > 0"):
        pool.addLeveragedToken(btc, LONG)

    btcusd.setPrice(50000 * 1e8)
    tx = pool.addLeveragedToken(btc, LONG)

    btcbull = LeveragedToken.at(tx.return_value)
    assert btcbull.name() == "Charm 2X Long Bitcoin"
    assert btcbull.symbol() == "charmBTCBULL"
    assert pool.numLeveragedTokens() == 1
    assert pool.leveragedTokens(0) == btcbull

    added, tokenSymbol, side, maxPoolShare, depositPaused, withdrawPaused, lastSquarePrice = pool.params(btcbull)
    assert added
    assert tokenSymbol == "BTC"
    assert side == LONG
    assert maxPoolShare == 0
    assert not depositPaused
    assert not withdrawPaused
    assert lastSquarePrice == 50000 * 50000 * 1e18

    tx = pool.addLeveragedToken(btc, SHORT)

    btcbear = LeveragedToken.at(tx.return_value)
    assert btcbear.name() == "Charm 2X Short Bitcoin"
    assert btcbear.symbol() == "charmBTCBEAR"
    assert pool.numLeveragedTokens() == 2
    assert pool.leveragedTokens(1) == btcbear

    added, tokenSymbol, side, maxPoolShare, depositPaused, withdrawPaused, lastSquarePrice = pool.params(btcbear)
    assert added
    assert tokenSymbol == "BTC"
    assert side == SHORT
    assert maxPoolShare == 0
    assert not depositPaused
    assert not withdrawPaused
    assert lastSquarePrice == 1.0 / 50000 / 50000 * 1e18

    assert pool.numLeveragedTokens() == 2
    assert pool.leveragedTokens(0) == btcbull
    assert pool.leveragedTokens(1) == btcbear
    assert pool.getLeveragedTokens() == [btcbull, btcbear]


def test_buy_sell(a, LeveragedTokenPool, LeveragedToken, MockToken, MockAggregatorV3Interface):
    deployer, alice, bob = a[:3]

    # deploy pool
    pool = deployer.deploy(LeveragedTokenPool)
    btc = deployer.deploy(MockToken, "Bitcoin", "BTC", 8)

    btcusd = deployer.deploy(MockAggregatorV3Interface)
    btcusd.setPrice(50000 * 1e8)
    pool.registerFeed("BTC", "USD", btcusd)

    tx = pool.addLeveragedToken(btc, LONG)
    btcbull = LeveragedToken.at(tx.return_value)

    tx = pool.addLeveragedToken(btc, SHORT)
    btcbear = LeveragedToken.at(tx.return_value)

    with reverts("Not added"):
        pool.buy(ZERO_ADDRESS, 1, alice, {"from": bob})

    assert pool.getUnderlyingPrice("BTC") == 50000 * 1e18
    assert pool.getSquarePrice(btcbull) == 50000 * 50000 * 1e18
    assert pool.getSquarePrice(btcbear) == 1.0 / 50000 / 50000 * 1e18

    pool.updateFee(100)
    assert pool.oneMinusFee() == 9900
    assert pool.getFee() == 100

    with reverts("Amount in should be > 0"):
        pool.buy(btcbull, 1, alice, {"from": bob})

    with reverts("Max slippage exceeded"):
        pool.buy(btcbull, 0.99001 * 1e18, alice, {"value": 1 * 1e18, "from": bob})

    shares = pool.getSharesFromAmount(btcbull, 1 * 1e18)
    assert shares == 0.99 * 1e18

    tx = pool.buy(btcbull, 0.99 * 1e18, alice, {"value": 1 * 1e18, "from": bob})
    assert tx.return_value == 0.99 * 1e18
    assert btcbull.balanceOf(alice) == 0.99 * 1e18
    assert pool.poolBalance() == 0.99 * 1e18
    assert pool.totalValue() == 0.99 * 1e18 * 50000 * 50000 * 1e18

    ###
    shares = pool.getSharesFromAmount(btcbear, 1 * 1e18)
    assert shares == 0.99 * 1e18

    tx = pool.buy(btcbear, 0, alice, {"value": 1 * 1e18, "from": bob})
    assert tx.return_value == 0.99 * 1e18
    assert btcbull.balanceOf(alice) == 0.99 * 1e18
    assert pool.poolBalance() == 0.99 * 1e18
    assert pool.totalValue() == 0.99 * 1e18 * 50000 * 50000 * 1e18

    btcusd.setPrice(40000 * 1e8)
    assert pool.poolBalance() == 0.99 * 1e18
    assert pool.totalValue() == 0.99 * 1e18 * 40000 * 40000 * 1e18

