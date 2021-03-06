from brownie import reverts, ZERO_ADDRESS
from collections import defaultdict
import pytest
from pytest import approx


LONG, SHORT = 0, 1


class Sim(object):
    def __init__(self):
        self.quantities = defaultdict(int)
        self.squarePrices = defaultdict(int)
        self.balance = 0
        self.poolBalance = 0

    def buy(self, symbol, quantity):
        return self._trade(symbol, quantity, 1) * 1.01

    def sell(self, symbol, quantity):
        return self._trade(symbol, quantity, -1) * 0.99

    def _trade(self, symbol, quantity, sign):
        cost = quantity * self._px(symbol)
        self.quantities[symbol] += sign * quantity
        self.balance += sign * cost * 1e18
        self.balance += cost * 1e16
        self.poolBalance += sign * cost * 1e18
        return cost * 1e18

    def _px(self, symbol):
        if self.totalValue() > 0:
            return self.squarePrices[symbol] * self.poolBalance / self.totalValue() * 1e24
        else:
            return 1.0

    def totalValue(self):
        tv = sum(self.quantities[symbol] * self.squarePrices[symbol] for symbol in self.quantities)
        return tv * 1e42


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
    assert lastSquarePrice == 50000 ** 2 * 1e18

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
    assert lastSquarePrice == 50000 ** -2 * 1e18

    assert pool.numLeveragedTokens() == 2
    assert pool.leveragedTokens(0) == btcbull
    assert pool.leveragedTokens(1) == btcbear
    assert pool.getLeveragedTokens() == [btcbull, btcbear]


@pytest.mark.parametrize("px1,px2", [(50000, 40000), (9e6, 8e6), (10, 20)])
def test_buy_sell(a, ChainlinkFeedsRegistry, LeveragedTokenPool, LeveragedToken, MockToken, MockAggregatorV3Interface, px1, px2):
    deployer, alice, bob = a[:3]

    # deploy pool
    feedsRegistry = deployer.deploy(ChainlinkFeedsRegistry)
    baseToken = deployer.deploy(MockToken, "USD Coin", "USDC", 6)
    pool = deployer.deploy(LeveragedTokenPool, feedsRegistry, baseToken)
    btc = deployer.deploy(MockToken, "Bitcoin", "BTC", 8)

    baseToken.mint(alice, 1e36)
    baseToken.mint(bob, 1e36)
    baseToken.approve(pool, 1e36, {"from": alice})
    baseToken.approve(pool, 1e36, {"from": bob})

    btcusd = deployer.deploy(MockAggregatorV3Interface)
    btcusd.setPrice(px1 * 1e8)
    feedsRegistry.addUsdFeed(btc, btcusd)

    tx = pool.addLeveragedToken(btc, LONG)
    btcbull = LeveragedToken.at(tx.return_value)

    tx = pool.addLeveragedToken(btc, SHORT)
    btcbear = LeveragedToken.at(tx.return_value)

    tx = pool.addLeveragedToken(btc, SHORT)
    tx = pool.addLeveragedToken(btc, SHORT)
    tx = pool.addLeveragedToken(btc, SHORT)
    tx = pool.addLeveragedToken(btc, SHORT)
    tx = pool.addLeveragedToken(btc, SHORT)
    tx = pool.addLeveragedToken(btc, SHORT)
    tx = pool.addLeveragedToken(btc, SHORT)
    tx = pool.addLeveragedToken(btc, SHORT)

    with reverts("Not added"):
        pool.buy(ZERO_ADDRESS, 1, alice, {"from": bob})

    assert feedsRegistry.getPrice(btc) == px1 * 1e8
    # assert pool.getSquarePrices(btc) == (px1 ** 2 * 1e24, px1 ** -2 * 1e24)

    pool.updateTradingFee(100)
    assert pool.tradingFee() == 100

    with reverts("Cost should be > 0"):
        pool.buy(btcbull, 0, alice, {"from": bob})

    sim = Sim()
    sim.squarePrices[btcbull] = px1 ** 2
    sim.squarePrices[btcbear] = px1 ** -2

    # check btc bull token price
    cost = sim.buy(btcbull, 1)
    assert approx(pool.buyQuote(btcbull, 1e18)) == cost

    # buy 1 btc bull token
    bobBalance = baseToken.balanceOf(bob)
    poolBalance = baseToken.balanceOf(pool)
    tx = pool.buy(btcbull, 1e18, alice, {"from": bob})
    assert approx(tx.return_value) == cost
    assert approx(bobBalance - baseToken.balanceOf(bob)) == cost
    assert approx(baseToken.balanceOf(pool) - poolBalance) == cost
    assert approx(btcbull.balanceOf(alice)) == 1e18
    assert approx(baseToken.balanceOf(pool)) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()

    # check btc bear token price
    cost = sim.buy(btcbear, 1e18)
    assert approx(pool.buyQuote(btcbear, 1e36)) == cost

    # buy 1 btc bear token
    bobBalance = baseToken.balanceOf(bob)
    poolBalance = baseToken.balanceOf(pool)
    tx = pool.buy(btcbear, 1e36, alice, {"from": bob})
    assert approx(tx.return_value) == cost
    assert approx(bobBalance - baseToken.balanceOf(bob)) == cost
    assert approx(baseToken.balanceOf(pool) - poolBalance) == cost
    assert approx(btcbear.balanceOf(alice)) == 1e36
    assert approx(baseToken.balanceOf(pool)) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()

    # change oracle price
    btcusd.setPrice(px2 * 1e8)
    assert approx(baseToken.balanceOf(pool)) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()

    # update btc bull price
    pool.updateSquarePrice(btcbull)
    sim.squarePrices[btcbull] = px2 ** 2
    assert approx(baseToken.balanceOf(pool)) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()

    # update btc bear price
    pool.updateSquarePrice(btcbear)
    sim.squarePrices[btcbear] = px2 ** -2
    assert approx(baseToken.balanceOf(pool)) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()

    pool.updateAllSquarePrices()
    assert approx(pool.totalValue()) == sim.totalValue()

    with reverts("Quantity should be > 0"):
        pool.sell(btcbull, 0, bob, {"from": alice})

    # check btc bull token price
    quantity = btcbull.balanceOf(alice)
    cost = sim.sell(btcbull, quantity / 1e18)
    assert approx(pool.sellQuote(btcbull, quantity)) == cost

    # sell 1 btc bull token
    bobBalance = baseToken.balanceOf(bob)
    poolBalance = baseToken.balanceOf(pool)
    tx = pool.sell(btcbull, quantity, bob, {"from": alice})
    assert approx(tx.return_value) == cost
    assert approx(baseToken.balanceOf(bob) - bobBalance) == cost
    assert approx(poolBalance - baseToken.balanceOf(pool)) == cost
    assert approx(btcbull.balanceOf(alice)) == 0
    assert approx(baseToken.balanceOf(pool)) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()


    print(pool.getSquarePrice(btc, SHORT))
    print(quantity)
    print(pool.poolBalance())

    # check btc bear token price
    quantity = btcbear.balanceOf(alice)
    cost = sim.sell(btcbear, quantity / 1e18)
    assert approx(pool.sellQuote(btcbear, quantity)) == cost

    # sell 1 btc bear token
    bobBalance = baseToken.balanceOf(bob)
    poolBalance = baseToken.balanceOf(pool)
    tx = pool.sell(btcbear, quantity, bob, {"from": alice})
    assert approx(tx.return_value) == cost
    assert approx(baseToken.balanceOf(bob) - bobBalance) == cost
    assert approx(poolBalance - baseToken.balanceOf(pool)) == cost
    assert approx(btcbear.balanceOf(alice)) == 0
    assert approx(baseToken.balanceOf(pool)) == sim.balance
    assert approx(pool.poolBalance()) == 0
    assert approx(pool.totalValue()) == 0
    assert approx(btcbear.balanceOf(alice)) == 0
    assert approx(baseToken.balanceOf(pool)) == sim.balance
    assert approx(pool.poolBalance()) == 0
    assert approx(pool.totalValue()) == 0

    pool.updateAllSquarePrices()
    assert approx(pool.totalValue()) == 0

