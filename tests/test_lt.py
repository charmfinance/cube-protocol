from brownie import reverts, ZERO_ADDRESS
from pytest import approx


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
    assert pool.getSquarePrice(btcbull) == 50000 ** 2 * 1e18
    assert pool.getSquarePrice(btcbear) == 50000 ** -2 * 1e18

    pool.updateFee(100)
    assert pool.oneMinusFee() == 9900
    assert pool.getFee() == 100

    with reverts("Amount in should be > 0"):
        pool.buy(btcbull, 1, alice, {"from": bob})

    with reverts("Max slippage exceeded"):
        pool.buy(btcbull, 0.99001 * 1e18, alice, {"value": 1 * 1e18, "from": bob})

    # buy 1 btc bull token
    amountIn1 = 1 / 0.99 * 1e18
    expectedOut1 = 1 * 1e18
    expectedTv1 = 50000 ** 2 * expectedOut1 * 1e18
    assert approx(pool.getSharesFromAmount(btcbull, amountIn1)) == expectedOut1

    tx = pool.buy(btcbull, 1 * 1e18, alice, {"value": amountIn1, "from": bob})
    assert approx(tx.return_value) == expectedOut1
    assert approx(btcbull.balanceOf(alice)) == expectedOut1
    assert approx(pool.poolBalance()) == amountIn1 * 0.99
    assert approx(pool.totalValue()) == expectedTv1

    # buy 1 btc bear token
    amountIn2 = 1 / 0.99 * 1e18
    expectedOut2 = 50000 ** 2 * expectedTv1 / 1e18
    expectedTv2 = 50000 ** -2 * expectedOut2 * 1e18
    assert approx(pool.getSharesFromAmount(btcbear, amountIn2)) == expectedOut2

    tx = pool.buy(btcbear, 0, alice, {"value": amountIn2, "from": bob})
    assert approx(tx.return_value) == expectedOut2
    assert approx(btcbear.balanceOf(alice)) == expectedOut2
    assert approx(pool.poolBalance()) == (amountIn1 + amountIn2) * 0.99
    assert approx(pool.totalValue()) == expectedTv1 + expectedTv2

    # price changes
    btcusd.setPrice(40000 * 1e8)
    assert approx(pool.poolBalance()) == (amountIn1 + amountIn2) * 0.99  # doesn't change
    assert approx(pool.totalValue()) == 50000 ** 2 * expectedOut1 * 1e18 + 50000 ** -2 * expectedOut2 * 1e18

    pool.updateSquarePrice(btcbull)
    assert approx(pool.poolBalance()) == (amountIn1 + amountIn2) * 0.99  # doesn't change
    assert approx(pool.totalValue()) == 40000 ** 2 * expectedOut1 * 1e18 + 50000 ** -2 * expectedOut2 * 1e18

    pool.updateSquarePrice(btcbear)
    assert approx(pool.poolBalance()) == (amountIn1 + amountIn2) * 0.99  # doesn't change
    assert approx(pool.totalValue()) == 40000 ** 2 * expectedOut1 * 1e18 + 40000 ** -2 * expectedOut2 * 1e18

    # sell 1 btc bull token
    tv = 40000 ** 2 * expectedOut1 + 40000 ** -2 * expectedOut2
    pb = (amountIn1 + amountIn2) * 0.99
    sharesIn3 = 1 * 1e18
    expectedOut3 = 0.99 * 40000 ** 2 * pb / tv * 1e18
    expectedTv3 = 40000 ** -2 * expectedOut3 * 1e18
    assert approx(pool.getAmountFromShares(btcbull, sharesIn3)) == expectedOut3

    bobBalance = bob.balance()
    tx = pool.sell(btcbull, sharesIn3, 0, bob, {"from": alice})
    assert approx(tx.return_value) == expectedOut3
    assert approx(btcbull.balanceOf(alice), abs=100) == 0
    assert approx(pool.poolBalance()) == (amountIn1 + amountIn2) * 0.99 - expectedOut3 / 0.99
    assert approx(pool.totalValue()) == expectedTv1 + expectedTv2 - expectedTv3
    


