from brownie import chain, reverts, ZERO_ADDRESS
from collections import defaultdict
import pytest
from pytest import approx


LONG, SHORT = 0, 1


class Sim(object):
    def __init__(self):
        self.quantities = defaultdict(int)
        self.prices = defaultdict(int)
        self.initialPrices = defaultdict(int)
        self.balance = 0
        self.poolBalance = 0
        self.feesAccrued = 0

    def buy(self, symbol, quantity):
        return self._trade(symbol, quantity, 1) * 1.01

    def sell(self, symbol, quantity):
        return self._trade(symbol, quantity, -1) * 0.99

    def _trade(self, symbol, quantity, sign):
        cost = quantity * self.px(symbol)
        self.quantities[symbol] += sign * quantity
        self.balance += sign * cost * 1e18
        self.balance += cost * 1e16
        self.poolBalance += sign * cost * 1e18
        self.feesAccrued += cost * 1e16
        return cost * 1e18

    def px(self, symbol):
        if self.totalValue() > 0:
            return (
                self.prices[symbol]
                * self.poolBalance
                / self.initialPrices[symbol]
                / self.totalValue()
                * 1e18
            )
        else:
            return 1.0

    def totalValue(self):
        tv = sum(
            self.quantities[symbol] * self.prices[symbol] / self.initialPrices[symbol]
            for symbol in self.quantities
        )
        return tv * 1e36


def test_add_lt(
    a,
    LPool,
    LToken,
    ChainlinkFeedsRegistry,
    MockToken,
    MockAggregatorV3Interface,
):
    deployer, alice = a[:2]

    # deploy pool
    usdc = deployer.deploy(MockToken, "USD Coin", "USDC", 6)
    btc = deployer.deploy(MockToken, "Bitcoin", "BTC", 8)
    weth = deployer.deploy(MockToken, "Wrapped Ether", "ETH", 18)

    feedsRegistry = deployer.deploy(ChainlinkFeedsRegistry, weth)
    pool = deployer.deploy(LPool, usdc, feedsRegistry)

    with reverts("Ownable: caller is not the owner"):
        pool.addLToken(btc, LONG, {"from": alice})

    with reverts("Price should be > 0"):
        pool.addLToken(btc, LONG)

    btcusd = deployer.deploy(MockAggregatorV3Interface)
    btcusd.setPrice(50000 * 1e8)
    feedsRegistry.addUsdFeed(btc, btcusd)
    assert feedsRegistry.getPrice(btc) == 50000 * 1e8

    btcusd.setPrice(0)
    with reverts("Price should be > 0"):
        pool.addLToken(btc, LONG)

    # add bull token
    btcusd.setPrice(50000 * 1e8)
    tx = pool.addLToken(btc, LONG)

    cubebtc = LToken.at(tx.return_value)
    assert cubebtc.name() == "BTC Cube Token"
    assert cubebtc.symbol() == "cubeBTC"
    assert pool.numLTokens() == 1
    assert pool.lTokens(0) == cubebtc

    (
        added,
        token,
        side,
        maxPoolShare,
        depositPaused,
        withdrawPaused,
        priceUpdatePaused,
        priceOffset,
        lastPrice,
        lastUpdated,
    ) = pool.params(cubebtc)
    assert added
    assert token == btc
    assert side == LONG
    assert maxPoolShare == 0
    assert not depositPaused
    assert not withdrawPaused
    assert not priceUpdatePaused
    assert approx(priceOffset) == 50000 ** 3 * 1e30
    assert lastPrice == 1e18
    assert approx(lastUpdated, abs=1) == chain.time()

    # check event
    (ev,) = tx.events["AddLToken"]
    assert ev["lToken"] == cubebtc
    assert ev["underlyingToken"] == btc
    assert ev["side"] == LONG
    assert ev["name"] == "BTC Cube Token"
    assert ev["symbol"] == "cubeBTC"

    # add bear token
    tx = pool.addLToken(btc, SHORT)

    invbtc = LToken.at(tx.return_value)
    assert invbtc.name() == "BTC Inverse Cube Token"
    assert invbtc.symbol() == "invBTC"
    assert pool.numLTokens() == 2
    assert pool.lTokens(1) == invbtc

    (
        added,
        token,
        side,
        maxPoolShare,
        depositPaused,
        withdrawPaused,
        priceUpdatePaused,
        priceOffset,
        lastPrice,
        lastUpdated,
    ) = pool.params(invbtc)
    assert added
    assert token == btc
    assert side == SHORT
    assert maxPoolShare == 0
    assert not depositPaused
    assert not withdrawPaused
    assert not priceUpdatePaused
    assert approx(priceOffset) == 50000 ** -3 * 1e30
    assert lastPrice == 1e18
    assert approx(lastUpdated, abs=1) == chain.time()

    # check event
    (ev,) = tx.events["AddLToken"]
    assert ev["lToken"] == invbtc
    assert ev["underlyingToken"] == btc
    assert ev["side"] == SHORT
    assert ev["name"] == "BTC Inverse Cube Token"
    assert ev["symbol"] == "invBTC"

    assert pool.numLTokens() == 2
    assert pool.lTokens(0) == cubebtc
    assert pool.lTokens(1) == invbtc

    with reverts("Already added"):
        pool.addLToken(btc, LONG)


@pytest.mark.parametrize("px1,px2", [(50000, 40000), (1e8, 1e7), (1, 1e1)])
@pytest.mark.parametrize("qty", [1, 1e-8, 1e8])
def test_buy_and_sell(
    a,
    LPool,
    LToken,
    ChainlinkFeedsRegistry,
    MockToken,
    MockAggregatorV3Interface,
    px1,
    px2,
    qty,
):
    deployer, alice, bob = a[:3]

    # deploy pool
    usdc = deployer.deploy(MockToken, "USD Coin", "USDC", 6)
    btc = deployer.deploy(MockToken, "Bitcoin", "BTC", 8)
    weth = deployer.deploy(MockToken, "Wrapped Ether", "ETH", 18)

    feedsRegistry = deployer.deploy(ChainlinkFeedsRegistry, weth)
    pool = deployer.deploy(LPool, usdc, feedsRegistry)

    usdc.mint(alice, 1e36)
    usdc.mint(bob, 1e36)
    usdc.approve(pool, 1e36, {"from": alice})
    usdc.approve(pool, 1e36, {"from": bob})

    btcusd = deployer.deploy(MockAggregatorV3Interface)
    btcusd.setPrice(px1 * 1e8)
    feedsRegistry.addUsdFeed(btc, btcusd)

    tx = pool.addLToken(btc, LONG)
    cubebtc = LToken.at(tx.return_value)

    tx = pool.addLToken(btc, SHORT)
    invbtc = LToken.at(tx.return_value)

    with reverts("Not added"):
        pool.buy(ZERO_ADDRESS, 1, 1, alice, {"from": bob})

    assert feedsRegistry.getPrice(btc) == px1 * 1e8

    pool.updateTradingFee(100)  # 1%

    sim = Sim()
    sim.prices[cubebtc] = px1 ** 3
    sim.prices[invbtc] = px1 ** -3
    sim.initialPrices[cubebtc] = px1 ** 3
    sim.initialPrices[invbtc] = px1 ** -3

    # check btc bull token price
    cost = sim.buy(cubebtc, qty)

    with reverts("Max slippage exceeded"):
        pool.buy(cubebtc, qty * 1e18, cost * 0.99, alice, {"from": bob})

    # buy 1 btc bull token
    bobBalance = usdc.balanceOf(bob)
    poolBalance = usdc.balanceOf(pool)
    tx = pool.buy(cubebtc, qty * 1e18, cost * 1.01, alice, {"from": bob})
    assert approx(tx.return_value) == cost
    assert approx(bobBalance - usdc.balanceOf(bob)) == cost
    assert approx(usdc.balanceOf(pool) - poolBalance) == cost
    assert approx(cubebtc.balanceOf(alice)) == qty * 1e18
    assert approx(usdc.balanceOf(pool)) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()
    assert approx(pool.params(cubebtc)[8]) == 1e18
    assert approx(pool.params(cubebtc)[9], abs=1) == chain.time()

    # check events
    (ev,) = tx.events["Trade"]
    assert ev["sender"] == bob
    assert ev["to"] == alice
    assert ev["baseToken"] == usdc
    assert ev["lToken"] == cubebtc
    assert ev["isBuy"]
    assert approx(ev["quantity"]) == qty * 1e18
    assert approx(ev["cost"]) == cost
    assert approx(ev["feeAmount"]) == cost / 101
    (ev,) = tx.events["UpdatePrice"]
    assert ev["lToken"] == cubebtc
    assert (
        approx(ev["price"]) == sim.prices[cubebtc] / sim.initialPrices[cubebtc] * 1e18
    )

    # check btc bear token price
    cost = sim.buy(invbtc, qty)

    with reverts("Max slippage exceeded"):
        pool.buy(invbtc, qty * 1e18, cost * 0.99, alice, {"from": bob})

    # buy 1 btc bear token
    bobBalance = usdc.balanceOf(bob)
    poolBalance = usdc.balanceOf(pool)
    tx = pool.buy(invbtc, qty * 1e18, cost * 1.01, alice, {"from": bob})
    assert approx(tx.return_value) == cost
    assert approx(bobBalance - usdc.balanceOf(bob)) == cost
    assert approx(usdc.balanceOf(pool) - poolBalance) == cost
    assert approx(invbtc.balanceOf(alice)) == qty * 1e18
    assert approx(usdc.balanceOf(pool)) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()
    assert approx(pool.params(invbtc)[8]) == 1e18
    assert approx(pool.params(invbtc)[9], abs=1) == chain.time()

    # check events
    (ev,) = tx.events["Trade"]
    assert ev["sender"] == bob
    assert ev["to"] == alice
    assert ev["baseToken"] == usdc
    assert ev["lToken"] == invbtc
    assert ev["isBuy"]
    assert approx(ev["quantity"]) == qty * 1e18
    assert approx(ev["cost"]) == cost
    assert approx(ev["feeAmount"]) == cost / 101
    (ev,) = tx.events["UpdatePrice"]
    assert ev["lToken"] == invbtc
    assert (
        approx(ev["price"]) == sim.prices[invbtc] / sim.initialPrices[invbtc] * 1e18
    )

    # change oracle price
    btcusd.setPrice(px2 * 1e8)
    assert feedsRegistry.getPrice(btc) == px2 * 1e8
    assert approx(usdc.balanceOf(pool)) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()

    # update btc bull price
    pool.updatePrice(cubebtc)
    sim.prices[cubebtc] = px2 ** 3
    assert approx(usdc.balanceOf(pool)) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()

    # update btc bear price
    pool.updatePrice(invbtc)
    sim.prices[invbtc] = px2 ** -3
    assert approx(usdc.balanceOf(pool)) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()

    # check btc bull token price
    quantity = cubebtc.balanceOf(alice)
    cost = sim.sell(cubebtc, quantity / 1e18)

    with reverts("Max slippage exceeded"):
        pool.buy(cubebtc, quantity, cost * 1.01, alice, {"from": bob})

    # sell 1 btc bull token
    bobBalance = usdc.balanceOf(bob)
    poolBalance = usdc.balanceOf(pool)
    tx = pool.sell(cubebtc, quantity, cost * 0.99, bob, {"from": alice})
    assert approx(tx.return_value, rel=1e-4) == cost
    assert approx(usdc.balanceOf(bob) - bobBalance, rel=1e-4) == cost
    assert approx(poolBalance - usdc.balanceOf(pool), rel=1e-4) == cost
    assert approx(cubebtc.balanceOf(alice)) == 0
    assert approx(usdc.balanceOf(pool)) == sim.balance
    assert approx(pool.poolBalance(), rel=1e-4) == sim.poolBalance
    assert approx(pool.totalValue(), rel=1e-4) == sim.totalValue()
    assert (
        approx(pool.params(cubebtc)[8])
        == sim.prices[cubebtc] / sim.initialPrices[cubebtc] * 1e18
    )
    assert approx(pool.params(cubebtc)[9], abs=1) == chain.time()

    # check events
    (ev,) = tx.events["Trade"]
    assert ev["sender"] == alice
    assert ev["to"] == bob
    assert ev["baseToken"] == usdc
    assert ev["lToken"] == cubebtc
    assert not ev["isBuy"]
    assert approx(ev["quantity"]) == quantity
    assert approx(ev["cost"], rel=1e-4) == cost
    assert approx(ev["feeAmount"], rel=1e-4, abs=1) == cost / 99
    (ev,) = tx.events["UpdatePrice"]
    assert ev["lToken"] == cubebtc
    assert (
        approx(ev["price"]) == sim.prices[cubebtc] / sim.initialPrices[cubebtc] * 1e18
    )

    # check btc bear token price
    quantity = invbtc.balanceOf(alice)
    cost = sim.sell(invbtc, quantity / 1e18)

    with reverts("Max slippage exceeded"):
        pool.buy(invbtc, quantity, cost * 1.01, alice, {"from": bob})

    # sell 1 btc bear token
    bobBalance = usdc.balanceOf(bob)
    poolBalance = usdc.balanceOf(pool)
    tx = pool.sell(invbtc, quantity, cost * 0.99, bob, {"from": alice})
    assert approx(tx.return_value, rel=1e-4) == cost
    assert approx(usdc.balanceOf(bob) - bobBalance, rel=1e-4) == cost
    assert approx(poolBalance - usdc.balanceOf(pool), rel=1e-4) == cost
    assert approx(invbtc.balanceOf(alice)) == 0
    assert approx(usdc.balanceOf(pool)) == sim.balance
    assert approx(pool.poolBalance()) == 0
    assert approx(pool.totalValue()) == 0
    assert (
        approx(pool.params(invbtc)[8])
        == sim.prices[invbtc] / sim.initialPrices[invbtc] * 1e18
    )
    assert approx(pool.params(invbtc)[9], abs=1) == chain.time()

    # check events
    (ev,) = tx.events["Trade"]
    assert ev["sender"] == alice
    assert ev["to"] == bob
    assert ev["baseToken"] == usdc
    assert ev["lToken"] == invbtc
    assert not ev["isBuy"]
    assert approx(ev["quantity"]) == quantity
    assert approx(ev["cost"], rel=1e-4) == cost
    assert approx(ev["feeAmount"], rel=1e-4, abs=1) == cost / 99
    (ev,) = tx.events["UpdatePrice"]
    assert ev["lToken"] == invbtc
    assert (
        approx(ev["price"]) == sim.prices[invbtc] / sim.initialPrices[invbtc] * 1e18
    )

    # buying 0 does nothing. it costs 1 because of rounding up
    assert pool.buy(cubebtc, 0, 1, alice, {"from": bob}).return_value == 1

    # selling 0 does nothing
    assert pool.sell(cubebtc, 0, 0, bob, {"from": alice}).return_value == 0


def test_owner_methods(
    a,
    LPool,
    LToken,
    ChainlinkFeedsRegistry,
    MockToken,
    MockAggregatorV3Interface,
):
    deployer, alice, bob = a[:3]

    # deploy pool
    usdc = deployer.deploy(MockToken, "USD Coin", "USDC", 6)
    btc = deployer.deploy(MockToken, "Bitcoin", "BTC", 8)
    weth = deployer.deploy(MockToken, "Wrapped Ether", "ETH", 18)

    feedsRegistry = deployer.deploy(ChainlinkFeedsRegistry, weth)
    pool = deployer.deploy(LPool, usdc, feedsRegistry)

    usdc.mint(alice, 1e36)
    usdc.mint(bob, 1e36)
    usdc.approve(pool, 1e36, {"from": alice})
    usdc.approve(pool, 1e36, {"from": bob})

    btcusd = deployer.deploy(MockAggregatorV3Interface)
    btcusd.setPrice(50000 * 1e8)
    feedsRegistry.addUsdFeed(btc, btcusd)

    tx = pool.addLToken(btc, LONG)
    cubebtc = LToken.at(tx.return_value)

    tx = pool.addLToken(btc, SHORT)
    invbtc = LToken.at(tx.return_value)

    # update trading fee
    with reverts("Ownable: caller is not the owner"):
        pool.updateTradingFee(100, {"from": alice})

    pool.updateTradingFee(100)  # 1%
    assert pool.tradingFee() == 100

    pool.updateTradingFee(0)
    assert pool.tradingFee() == 0

    pool.updateTradingFee(100)  # 1%
    assert pool.tradingFee() == 100

    with reverts("Trading fee should be < 100%"):
        pool.updateTradingFee(1e4)

    # update max tvl
    with reverts("Ownable: caller is not the owner"):
        pool.updateMaxTvl(1e18, {"from": alice})

    pool.updateMaxTvl(2e18)
    assert pool.maxTvl() == 2e18

    with reverts("Max TVL exceeded"):
        pool.buy(cubebtc, 2e18, 1e36, alice, {"from": alice})

    pool.buy(cubebtc, 1e18, 1e36, alice, {"from": alice})

    pool.updateMaxTvl(0)
    assert pool.maxTvl() == 0

    pool.buy(cubebtc, 1e18, 1e36, alice, {"from": alice})

    # update max pool share
    pool.updateMaxPoolShare(invbtc, 5000)  # 50%
    assert pool.params(cubebtc)[3] == 0
    assert pool.params(invbtc)[3] == 5000

    with reverts("Max pool share exceeded"):
        pool.buy(invbtc, 2.1e18, 1e36, alice, {"from": alice})

    pool.buy(invbtc, 2e18, 1e36, alice, {"from": alice})

    pool.updateMaxPoolShare(invbtc, 0)
    assert pool.params(invbtc)[3] == 0

    pool.buy(invbtc, 1e18, 1e36, alice, {"from": alice})

    # collect fee
    assert pool.feesAccrued() == 5e16

    with reverts("Ownable: caller is not the owner"):
        pool.collectFee({"from": alice})

    balance = usdc.balanceOf(deployer)
    pool.collectFee()
    assert usdc.balanceOf(deployer) - balance == 5e16
    assert pool.feesAccrued() == 0

    # pause buy
    with reverts("Must be owner or guardian"):
        pool.updateBuyPaused(cubebtc, True, {"from": alice})

    pool.updateBuyPaused(cubebtc, True)

    with reverts("Paused"):
        pool.buy(cubebtc, 1e18, 1e36, alice, {"from": alice})
    pool.buy(invbtc, 1e18, 1e36, alice, {"from": alice})

    pool.updateBuyPaused(cubebtc, False)
    pool.buy(cubebtc, 1e18, 1e36, alice, {"from": alice})

    # pause sell
    with reverts("Must be owner or guardian"):
        pool.updateSellPaused(cubebtc, True, {"from": alice})

    pool.updateSellPaused(cubebtc, True)

    with reverts("Paused"):
        pool.sell(cubebtc, 1e18, 0, alice, {"from": alice})
    pool.sell(invbtc, 1e18, 0, alice, {"from": alice})

    pool.updateSellPaused(cubebtc, False)
    pool.sell(cubebtc, 1e18, 0, alice, {"from": alice})

    # pause price update
    with reverts("Must be owner or guardian"):
        pool.updatePriceUpdatePaused(cubebtc, True, {"from": alice})

    pool.updatePriceUpdatePaused(cubebtc, True)

    t = pool.params(cubebtc)[9]
    chain.sleep(1)
    pool.updatePrice(cubebtc, {"from": alice})
    assert pool.params(cubebtc)[9] == t

    t = pool.params(invbtc)[9]
    chain.sleep(1)
    pool.updatePrice(invbtc, {"from": alice})
    assert pool.params(invbtc)[9] > t

    pool.updatePriceUpdatePaused(cubebtc, False)

    t = pool.params(cubebtc)[9]
    chain.sleep(1)
    pool.updatePrice(cubebtc, {"from": alice})
    assert pool.params(cubebtc)[9] > t

    # add guardian
    assert not pool.guardians(alice)
    with reverts("Ownable: caller is not the owner"):
        pool.addGuardian(alice, {"from": alice})
    pool.addGuardian(alice)
    assert pool.guardians(alice)

    pool.updateBuyPaused(cubebtc, True, {"from": alice})
    pool.updateBuyPaused(cubebtc, False, {"from": alice})

    pool.updateSellPaused(cubebtc, True, {"from": alice})
    pool.updateSellPaused(cubebtc, False, {"from": alice})

    pool.updatePriceUpdatePaused(cubebtc, True, {"from": alice})
    pool.updatePriceUpdatePaused(cubebtc, False, {"from": alice})

    # remove guardian
    with reverts("Must be owner or the guardian itself"):
        pool.removeGuardian(alice, {"from": bob})
    pool.removeGuardian(alice, {"from": alice})
    assert not pool.guardians(alice)

    pool.addGuardian(alice)
    assert pool.guardians(alice)
    pool.removeGuardian(alice)
    assert not pool.guardians(alice)
