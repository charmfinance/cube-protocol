from brownie import chain, reverts, ZERO_ADDRESS
from collections import defaultdict
import pytest
from pytest import approx


LONG, SHORT = 0, 1
LAST_PRICE_INDEX = 4
LAST_UPDATED_INDEX = 5


class Sim(object):
    def __init__(self):
        self.quantities = defaultdict(int)
        self.prices = defaultdict(int)
        self.initialPrices = defaultdict(int)
        self.balance = 0
        self.poolBalance = 0
        self.feeAccrued = 0

    def mint(self, symbol, quantity):
        return self._trade(symbol, quantity, 1) / 0.99

    def burn(self, symbol, quantity):
        return self._trade(symbol, quantity, -1) * 0.99

    def _trade(self, symbol, quantity, sign):
        cost = quantity * self.px(symbol)
        self.quantities[symbol] += sign * quantity
        self.balance += sign * cost * 1e18 * 0.99 ** (-sign)
        self.poolBalance += sign * cost * 1e18
        self.feeAccrued += cost * 1e16
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
    CubePool,
    CubeToken,
    ChainlinkFeedsRegistry,
    MockToken,
    MockAggregatorV3Interface,
):
    deployer, alice = a[:2]

    # deploy pool
    feedsRegistry = deployer.deploy(ChainlinkFeedsRegistry)
    pool = deployer.deploy(CubePool, feedsRegistry)

    with reverts("Ownable: caller is not the owner"):
        pool.addCubeToken("BTC", LONG, {"from": alice})

    with reverts("Price should be > 0"):
        pool.addCubeToken("BTC", LONG)

    btcusd = deployer.deploy(MockAggregatorV3Interface)
    btcusd.setPrice(50000 * 1e8)
    feedsRegistry.addUsdFeed("BTC", btcusd)
    assert feedsRegistry.getPrice("BTC") == 50000 * 1e8

    btcusd.setPrice(0)
    with reverts("Price should be > 0"):
        pool.addCubeToken("BTC", LONG)

    # add bull token
    btcusd.setPrice(50000 * 1e8)
    tx = pool.addCubeToken("BTC", LONG)

    cubebtc = CubeToken.at(tx.return_value)
    assert cubebtc.name() == "BTC Cube Token"
    assert cubebtc.symbol() == "cubeBTC"
    assert pool.numCubeTokens() == 1
    assert pool.cubeTokens(0) == cubebtc

    (
        token,
        side,
        maxPoolShare,
        initialPrice,
        lastPrice,
        lastUpdated,
        depositPaused,
        withdrawPaused,
        priceUpdatePaused,
        added,
    ) = pool.params(cubebtc)
    assert added
    assert token == "BTC"
    assert side == LONG
    assert maxPoolShare == 0
    assert not depositPaused
    assert not withdrawPaused
    assert not priceUpdatePaused
    assert approx(initialPrice) == 50000 ** 3 * 1e30
    assert lastPrice == 1e18
    assert approx(lastUpdated, abs=1) == chain.time()

    # check event
    (ev,) = tx.events["AddCubeToken"]
    assert ev["cubeToken"] == cubebtc
    assert ev["underlyingSymbol"] == "BTC"
    assert ev["side"] == LONG

    # add bear token
    tx = pool.addCubeToken("BTC", SHORT)

    invbtc = CubeToken.at(tx.return_value)
    assert invbtc.name() == "BTC Inverse Cube Token"
    assert invbtc.symbol() == "invBTC"
    assert pool.numCubeTokens() == 2
    assert pool.cubeTokens(1) == invbtc

    (
        token,
        side,
        maxPoolShare,
        initialPrice,
        lastPrice,
        lastUpdated,
        depositPaused,
        withdrawPaused,
        priceUpdatePaused,
        added,
    ) = pool.params(invbtc)
    assert added
    assert token == "BTC"
    assert side == SHORT
    assert maxPoolShare == 0
    assert not depositPaused
    assert not withdrawPaused
    assert not priceUpdatePaused
    assert approx(initialPrice) == 50000 ** -3 * 1e30
    assert lastPrice == 1e18
    assert approx(lastUpdated, abs=1) == chain.time()

    # check event
    (ev,) = tx.events["AddCubeToken"]
    assert ev["cubeToken"] == invbtc
    assert ev["underlyingSymbol"] == "BTC"
    assert ev["side"] == SHORT

    assert pool.numCubeTokens() == 2
    assert pool.cubeTokens(0) == cubebtc
    assert pool.cubeTokens(1) == invbtc

    with reverts("Already added"):
        pool.addCubeToken("BTC", LONG)


@pytest.mark.parametrize("px1,px2", [(50000, 40000), (1e8, 1e7), (1, 1e1)])
@pytest.mark.parametrize("qty", [1, 1e-8, 10])
def test_mint_and_burn(
    a,
    CubePool,
    CubeToken,
    ChainlinkFeedsRegistry,
    MockToken,
    MockAggregatorV3Interface,
    px1,
    px2,
    qty,
):
    deployer, alice, bob = a[:3]

    # deploy pool
    feedsRegistry = deployer.deploy(ChainlinkFeedsRegistry)
    pool = deployer.deploy(CubePool, feedsRegistry)

    btcusd = deployer.deploy(MockAggregatorV3Interface)
    btcusd.setPrice(px1 * 1e8)
    feedsRegistry.addUsdFeed("BTC", btcusd)

    tx = pool.addCubeToken("BTC", LONG)
    cubebtc = CubeToken.at(tx.return_value)

    tx = pool.addCubeToken("BTC", SHORT)
    invbtc = CubeToken.at(tx.return_value)

    with reverts("Not added"):
        pool.mint(ZERO_ADDRESS, alice, {"from": bob})

    assert feedsRegistry.getPrice("BTC") == px1 * 1e8

    pool.updateTradingFee(100)  # 1%

    sim = Sim()
    sim.prices[cubebtc] = px1 ** 3
    sim.prices[invbtc] = px1 ** -3
    sim.initialPrices[cubebtc] = px1 ** 3
    sim.initialPrices[invbtc] = px1 ** -3

    # check btc bull token price
    cost = sim.mint(cubebtc, qty)

    # mint 1 btc bull token
    bobBalance = bob.balance()
    poolBalance = pool.balance()
    tx = pool.mint(cubebtc, alice, {"from": bob, "value": cost})
    assert approx(tx.return_value) == qty * 1e18
    assert approx(bobBalance - bob.balance()) == cost
    assert approx(pool.balance() - poolBalance) == cost
    assert approx(cubebtc.balanceOf(alice)) == qty * 1e18
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance(), rel=1e-3) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()
    assert approx(pool.params(cubebtc)[LAST_PRICE_INDEX]) == 1e18
    assert approx(pool.params(cubebtc)[LAST_UPDATED_INDEX], abs=1) == chain.time()

    # check events
    (ev,) = tx.events["MintOrBurn"]
    assert ev["sender"] == bob
    assert ev["to"] == alice
    assert ev["cubeToken"] == cubebtc
    assert ev["isMint"]
    assert approx(ev["quantity"]) == qty * 1e18
    assert approx(ev["cost"]) == cost
    (ev,) = tx.events["UpdatePrice"]
    assert ev["cubeToken"] == cubebtc
    assert (
        approx(ev["price"]) == sim.prices[cubebtc] / sim.initialPrices[cubebtc] * 1e18
    )

    # check btc bear token price
    cost = sim.mint(invbtc, qty)

    # mint 1 btc bear token
    bobBalance = bob.balance()
    poolBalance = pool.balance()
    tx = pool.mint(invbtc, alice, {"from": bob, "value": cost})
    assert approx(tx.return_value) == qty * 1e18
    assert approx(bobBalance - bob.balance()) == cost
    assert approx(pool.balance() - poolBalance) == cost
    assert approx(invbtc.balanceOf(alice)) == qty * 1e18
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()
    assert approx(pool.params(invbtc)[LAST_PRICE_INDEX]) == 1e18
    assert approx(pool.params(invbtc)[LAST_UPDATED_INDEX], abs=1) == chain.time()

    # check events
    (ev,) = tx.events["MintOrBurn"]
    assert ev["sender"] == bob
    assert ev["to"] == alice
    assert ev["cubeToken"] == invbtc
    assert ev["isMint"]
    assert approx(ev["quantity"]) == qty * 1e18
    assert approx(ev["cost"]) == cost
    (ev,) = tx.events["UpdatePrice"]
    assert ev["cubeToken"] == invbtc
    assert approx(ev["price"]) == sim.prices[invbtc] / sim.initialPrices[invbtc] * 1e18

    # change oracle price
    btcusd.setPrice(px2 * 1e8)
    assert feedsRegistry.getPrice("BTC") == px2 * 1e8
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()

    # update btc bull price
    pool.updatePrice(cubebtc)
    sim.prices[cubebtc] = px2 ** 3
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()

    # update btc bear price
    pool.updatePrice(invbtc)
    sim.prices[invbtc] = px2 ** -3
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()

    # check btc bull token price
    quantity = cubebtc.balanceOf(alice)
    cost = sim.burn(cubebtc, quantity / 1e18)

    # burn 1 btc bull token
    bobBalance = bob.balance()
    poolBalance = pool.balance()
    tx = pool.burn(cubebtc, quantity, bob, {"from": alice})
    assert approx(tx.return_value, rel=1e-4) == cost
    assert approx(bob.balance() - bobBalance, rel=1e-4) == cost
    assert approx(poolBalance - pool.balance(), rel=1e-4) == cost
    assert approx(cubebtc.balanceOf(alice)) == 0
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance(), rel=1e-4) == sim.poolBalance
    assert approx(pool.totalValue(), rel=1e-4) == sim.totalValue()
    assert (
        approx(pool.params(cubebtc)[LAST_PRICE_INDEX])
        == sim.prices[cubebtc] / sim.initialPrices[cubebtc] * 1e18
    )
    assert approx(pool.params(cubebtc)[LAST_UPDATED_INDEX], abs=1) == chain.time()

    # check events
    (ev,) = tx.events["MintOrBurn"]
    assert ev["sender"] == alice
    assert ev["to"] == bob
    assert ev["cubeToken"] == cubebtc
    assert not ev["isMint"]
    assert approx(ev["quantity"]) == quantity
    assert approx(ev["cost"], rel=1e-4) == cost

    (ev,) = tx.events["UpdatePrice"]
    assert ev["cubeToken"] == cubebtc
    assert (
        approx(ev["price"]) == sim.prices[cubebtc] / sim.initialPrices[cubebtc] * 1e18
    )

    # check btc bear token price
    quantity = invbtc.balanceOf(alice)
    cost = sim.burn(invbtc, quantity / 1e18)

    # burn 1 btc bear token
    bobBalance = bob.balance()
    poolBalance = pool.balance()
    tx = pool.burn(invbtc, quantity, bob, {"from": alice})
    assert approx(tx.return_value, rel=1e-4) == cost
    assert approx(bob.balance() - bobBalance, rel=1e-4) == cost
    assert approx(poolBalance - pool.balance(), rel=1e-4) == cost
    assert approx(invbtc.balanceOf(alice)) == 0
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance()) == 0
    assert approx(pool.totalValue()) == 0
    assert (
        approx(pool.params(invbtc)[LAST_PRICE_INDEX])
        == sim.prices[invbtc] / sim.initialPrices[invbtc] * 1e18
    )
    assert approx(pool.params(invbtc)[LAST_UPDATED_INDEX], abs=1) == chain.time()

    # check events
    (ev,) = tx.events["MintOrBurn"]
    assert ev["sender"] == alice
    assert ev["to"] == bob
    assert ev["cubeToken"] == invbtc
    assert not ev["isMint"]
    assert approx(ev["quantity"]) == quantity
    assert approx(ev["cost"], rel=1e-4) == cost
    (ev,) = tx.events["UpdatePrice"]
    assert ev["cubeToken"] == invbtc
    assert approx(ev["price"]) == sim.prices[invbtc] / sim.initialPrices[invbtc] * 1e18

    # mint 0 does nothing
    assert pool.mint(cubebtc, alice, {"from": bob}).return_value == 0

    # burn 0 does nothing
    assert pool.burn(cubebtc, 0, bob, {"from": alice}).return_value == 0


def test_owner_methods(
    a,
    CubePool,
    CubeToken,
    ChainlinkFeedsRegistry,
    MockToken,
    MockAggregatorV3Interface,
):
    deployer, alice, bob = a[:3]

    # deploy pool
    feedsRegistry = deployer.deploy(ChainlinkFeedsRegistry)
    pool = deployer.deploy(CubePool, feedsRegistry)

    btcusd = deployer.deploy(MockAggregatorV3Interface)
    btcusd.setPrice(50000 * 1e8)
    feedsRegistry.addUsdFeed("BTC", btcusd)

    tx = pool.addCubeToken("BTC", LONG)
    cubebtc = CubeToken.at(tx.return_value)

    tx = pool.addCubeToken("BTC", SHORT)
    invbtc = CubeToken.at(tx.return_value)

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
        pool.mint(cubebtc, alice, {"from": alice, "value": 2.03e18})

    pool.mint(cubebtc, alice, {"from": alice, "value": 2e18})

    pool.updateMaxTvl(0)
    assert pool.maxTvl() == 0

    pool.mint(cubebtc, alice, {"from": alice, "value": 1e18})

    # update max pool share
    pool.updateMaxPoolShare(invbtc, 5000)  # 50%
    assert pool.params(cubebtc)[3] == 0
    assert pool.params(invbtc)[3] == 5000

    with reverts("Max pool share exceeded"):
        pool.mint(invbtc, alice, {"from": alice, "value": 3.04e18})

    pool.mint(invbtc, alice, {"from": alice, "value": 3e18})

    pool.updateMaxPoolShare(invbtc, 0)
    assert pool.params(invbtc)[3] == 0

    pool.mint(invbtc, alice, {"from": alice, "value": 1e18})

    # collect fee
    assert pool.feeAccrued() == 7e16

    with reverts("Ownable: caller is not the owner"):
        pool.collectFee({"from": alice})

    balance = deployer.balance()
    pool.collectFee()
    assert deployer.balance() - balance == 7e16
    assert pool.feeAccrued() == 0

    # pause mint
    with reverts("Must be owner or guardian"):
        pool.updateMintPaused(cubebtc, True, {"from": alice})

    pool.updateMintPaused(cubebtc, True)

    with reverts("Paused"):
        pool.mint(cubebtc, alice, {"from": alice, "value": 1e18})
    pool.mint(invbtc, alice, {"from": alice, "value": 1e18})

    pool.updateMintPaused(cubebtc, False)
    pool.mint(cubebtc, alice, {"from": alice, "value": 1e18})

    # pause burn
    with reverts("Must be owner or guardian"):
        pool.updateBurnPaused(cubebtc, True, {"from": alice})

    pool.updateBurnPaused(cubebtc, True)

    with reverts("Paused"):
        pool.burn(cubebtc, 1e18, alice, {"from": alice})
    pool.burn(invbtc, 1e18, alice, {"from": alice})

    pool.updateBurnPaused(cubebtc, False)
    pool.burn(cubebtc, 1e18, alice, {"from": alice})

    # pause price update
    with reverts("Must be owner or guardian"):
        pool.updatePriceUpdatePaused(cubebtc, True, {"from": alice})

    pool.updatePriceUpdatePaused(cubebtc, True)

    t = pool.params(cubebtc)[LAST_UPDATED_INDEX]
    chain.sleep(1)
    pool.updatePrice(cubebtc, {"from": alice})
    assert pool.params(cubebtc)[LAST_UPDATED_INDEX] == t

    t = pool.params(invbtc)[LAST_UPDATED_INDEX]
    chain.sleep(1)
    pool.updatePrice(invbtc, {"from": alice})
    assert pool.params(invbtc)[LAST_UPDATED_INDEX] > t

    pool.updatePriceUpdatePaused(cubebtc, False)

    t = pool.params(cubebtc)[LAST_UPDATED_INDEX]
    chain.sleep(1)
    pool.updatePrice(cubebtc, {"from": alice})
    assert pool.params(cubebtc)[LAST_UPDATED_INDEX] > t

    # add guardian
    assert not pool.guardians(alice)
    with reverts("Ownable: caller is not the owner"):
        pool.addGuardian(alice, {"from": alice})
    pool.addGuardian(alice)
    assert pool.guardians(alice)

    pool.updateMintPaused(cubebtc, True, {"from": alice})
    pool.updateMintPaused(cubebtc, False, {"from": alice})

    pool.updateBurnPaused(cubebtc, True, {"from": alice})
    pool.updateBurnPaused(cubebtc, False, {"from": alice})

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
