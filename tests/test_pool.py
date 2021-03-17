from brownie import chain, reverts, ZERO_ADDRESS
from collections import defaultdict
import pytest
from pytest import approx


LONG, SHORT = False, True
FEE_INDEX = 2
MAX_POOL_SHARE_INDEX = 3
LAST_PRICE_INDEX = 5
LAST_UPDATED_INDEX = 6


class Sim(object):
    def __init__(self):
        self.quantities = defaultdict(int)
        self.prices = defaultdict(int)
        self.initialPrices = defaultdict(int)
        self.balance = 0
        self.poolBalance = 0
        self.feeAccrued = 0

    def deposit(self, symbol, quantity):
        return self._trade(symbol, quantity, 1) / 0.99

    def withdraw(self, symbol, quantity):
        return self._trade(symbol, quantity, -1) * 0.99

    def _trade(self, symbol, quantity, sign):
        cost = quantity * self.price(symbol)
        self.quantities[symbol] += sign * quantity
        self.balance += sign * cost * 1e18 * 0.99 ** (-sign)
        self.poolBalance += sign * cost * 1e18
        self.feeAccrued += cost * 1e16
        return cost * 1e18

    def price(self, symbol):
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

    with reverts("Spot price should be > 0"):
        pool.addCubeToken("BTC", LONG)

    btcusd = deployer.deploy(MockAggregatorV3Interface)
    btcusd.setPrice(50000 * 1e8)
    BTC = feedsRegistry.stringToBytes32("BTC")
    feedsRegistry.addUsdFeed(BTC, btcusd)
    assert feedsRegistry.getPrice(BTC) == 50000 * 1e8

    btcusd.setPrice(0)
    with reverts("Spot price should be > 0"):
        pool.addCubeToken("BTC", LONG)

    # add bull token
    btcusd.setPrice(50000 * 1e8)
    tx = pool.addCubeToken("BTC", LONG)

    cubebtc = CubeToken.at(tx.return_value)
    assert cubebtc.name() == "Charm 3X Long BTC"
    assert cubebtc.symbol() == "cubeBTC"
    assert pool.numCubeTokens() == 1
    assert pool.cubeTokens(0) == cubebtc

    (
        currencyKey,
        inverse,
        fee,
        maxPoolShare,
        initialSpotPrice,
        lastPrice,
        lastUpdated,
        depositPaused,
        withdrawPaused,
        updatePaused,
        added,
    ) = pool.params(cubebtc)
    assert added
    assert currencyKey == BTC
    assert inverse == LONG
    assert maxPoolShare == 0
    assert not depositPaused
    assert not withdrawPaused
    assert not updatePaused
    assert approx(initialSpotPrice) == 50000 * 1e8
    assert lastPrice == 1e18
    assert approx(lastUpdated, abs=2) == chain.time()

    # check event
    (ev,) = tx.events["AddCubeToken"]
    assert ev["cubeToken"] == cubebtc
    assert ev["spotSymbol"] == "BTC"
    assert ev["inverse"] == LONG

    # add bear token
    tx = pool.addCubeToken("BTC", SHORT)

    invbtc = CubeToken.at(tx.return_value)
    assert invbtc.name() == "Charm 3X Short BTC"
    assert invbtc.symbol() == "invBTC"
    assert pool.numCubeTokens() == 2
    assert pool.cubeTokens(1) == invbtc

    (
        currencyKey,
        inverse,
        fee,
        maxPoolShare,
        initialSpotPrice,
        lastPrice,
        lastUpdated,
        depositPaused,
        withdrawPaused,
        updatePaused,
        added,
    ) = pool.params(invbtc)
    assert added
    assert currencyKey == BTC
    assert inverse == SHORT
    assert maxPoolShare == 0
    assert not depositPaused
    assert not withdrawPaused
    assert not updatePaused
    assert approx(initialSpotPrice) == 50000 * 1e8
    assert lastPrice == 1e18
    assert approx(lastUpdated, abs=2) == chain.time()

    # check event
    (ev,) = tx.events["AddCubeToken"]
    assert ev["cubeToken"] == invbtc
    assert ev["spotSymbol"] == "BTC"
    assert ev["inverse"] == SHORT

    assert pool.numCubeTokens() == 2
    assert pool.cubeTokens(0) == cubebtc
    assert pool.cubeTokens(1) == invbtc

    with reverts("Already added"):
        pool.addCubeToken("BTC", LONG)


@pytest.mark.parametrize("px1,px2", [(50000, 40000), (1e8, 1e7), (1, 1e1)])
@pytest.mark.parametrize("qty", [1, 1e-8, 10])
def test_deposit_and_withdraw(
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
    BTC = feedsRegistry.stringToBytes32("BTC")
    feedsRegistry.addUsdFeed(BTC, btcusd)

    tx = pool.addCubeToken("BTC", LONG)
    cubebtc = CubeToken.at(tx.return_value)

    tx = pool.addCubeToken("BTC", SHORT)
    invbtc = CubeToken.at(tx.return_value)

    with reverts("Not added"):
        pool.deposit(ZERO_ADDRESS, alice, {"from": bob})

    assert feedsRegistry.getPrice(BTC) == px1 * 1e8

    pool.setFee(cubebtc, 100)  # 1%
    pool.setFee(invbtc, 100)  # 1%

    sim = Sim()
    sim.prices[cubebtc] = px1 ** 3
    sim.prices[invbtc] = px1 ** -3
    sim.initialPrices[cubebtc] = px1 ** 3
    sim.initialPrices[invbtc] = px1 ** -3

    # check btc bull token price
    cost = sim.deposit(cubebtc, qty)
    assert approx(pool.quoteDeposit(cubebtc, cost)) == qty * 1e18
    assert approx(pool.quote(cubebtc)) == sim.price(cubebtc) * 1e18

    # deposit 1 btc bull token
    bobBalance = bob.balance()
    poolBalance = pool.balance()
    tx = pool.deposit(cubebtc, alice, {"from": bob, "value": cost})
    assert approx(tx.return_value) == qty * 1e18
    assert approx(bobBalance - bob.balance()) == cost
    assert approx(pool.balance() - poolBalance) == cost
    assert approx(cubebtc.balanceOf(alice)) == qty * 1e18
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance(), rel=1e-3) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()
    assert approx(pool.params(cubebtc)[LAST_PRICE_INDEX]) == 1e18
    assert approx(pool.params(cubebtc)[LAST_UPDATED_INDEX], abs=2) == chain.time()
    update_time = chain.time()
    chain.sleep(1)

    # check events
    (ev,) = tx.events["DepositOrWithdraw"]
    assert ev["cubeToken"] == cubebtc
    assert ev["sender"] == bob
    assert ev["to"] == alice
    assert ev["isDeposit"]
    assert approx(ev["quantity"]) == qty * 1e18
    assert approx(ev["ethAmount"]) == cost

    (ev,) = tx.events["Update"]
    assert ev["cubeToken"] == cubebtc
    assert (
        approx(ev["price"]) == sim.prices[cubebtc] / sim.initialPrices[cubebtc] * 1e18
    )

    # pause price updates and change oracle price, which shouldn't be reflected
    # until later
    pool.setPaused(invbtc, False, False, True)
    btcusd.setPrice(px2 * 1e8)
    assert feedsRegistry.getPrice(BTC) == px2 * 1e8
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()

    # check btc bear token price
    cost = sim.deposit(invbtc, qty)
    assert approx(pool.quoteDeposit(invbtc, cost)) == qty * 1e18
    assert approx(pool.quote(invbtc)) == sim.price(invbtc) * 1e18

    # deposit 1 btc bear token
    bobBalance = bob.balance()
    poolBalance = pool.balance()
    tx = pool.deposit(invbtc, alice, {"from": bob, "value": cost})
    assert approx(tx.return_value) == qty * 1e18
    assert approx(bobBalance - bob.balance()) == cost
    assert approx(pool.balance() - poolBalance) == cost
    assert approx(invbtc.balanceOf(alice)) == qty * 1e18
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()
    assert approx(pool.params(invbtc)[LAST_PRICE_INDEX]) == 1e18
    assert (
        approx(pool.params(invbtc)[LAST_UPDATED_INDEX], abs=2)
        == update_time
        < chain.time()
    )

    # check events
    (ev,) = tx.events["DepositOrWithdraw"]
    assert ev["cubeToken"] == invbtc
    assert ev["sender"] == bob
    assert ev["to"] == alice
    assert ev["isDeposit"]
    assert approx(ev["quantity"]) == qty * 1e18
    assert approx(ev["ethAmount"]) == cost

    assert "Update" not in tx.events

    # (ev,) = tx.events["Update"]
    # assert ev["cubeToken"] == invbtc
    # assert approx(ev["price"]) == sim.prices[invbtc] / sim.initialPrices[invbtc] * 1e18

    # unpause price updates
    pool.setPaused(invbtc, False, False, False)

    # update btc bull price
    pool.update(cubebtc)
    sim.prices[cubebtc] = px2 ** 3
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()

    # update btc bear price
    pool.update(invbtc)
    sim.prices[invbtc] = px2 ** -3
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()

    # check btc bull token price
    cost = sim.deposit(cubebtc, qty)
    assert approx(pool.quoteDeposit(cubebtc, cost)) == qty * 1e18
    assert approx(pool.quote(cubebtc)) == sim.price(cubebtc) * 1e18

    # deposit 1 btc bull token
    bobBalance = bob.balance()
    poolBalance = pool.balance()
    tx = pool.deposit(cubebtc, alice, {"from": bob, "value": cost})
    assert approx(tx.return_value) == qty * 1e18
    assert approx(bobBalance - bob.balance()) == cost
    assert approx(pool.balance() - poolBalance) == cost
    assert approx(cubebtc.balanceOf(alice)) == 2 * qty * 1e18
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance(), rel=1e-3) == sim.poolBalance
    assert approx(pool.totalValue()) == sim.totalValue()
    assert (
        approx(pool.params(cubebtc)[LAST_PRICE_INDEX])
        == sim.prices[cubebtc] / sim.initialPrices[cubebtc] * 1e18
    )
    assert approx(pool.params(cubebtc)[LAST_UPDATED_INDEX], abs=2) == chain.time()

    # check events
    (ev,) = tx.events["DepositOrWithdraw"]
    assert ev["cubeToken"] == cubebtc
    assert ev["sender"] == bob
    assert ev["to"] == alice
    assert ev["isDeposit"]
    assert approx(ev["quantity"]) == qty * 1e18
    assert approx(ev["ethAmount"]) == cost

    (ev,) = tx.events["Update"]
    assert ev["cubeToken"] == cubebtc
    assert (
        approx(ev["price"]) == sim.prices[cubebtc] / sim.initialPrices[cubebtc] * 1e18
    )

    # check btc bull token price
    quantity = cubebtc.balanceOf(alice)
    cost = sim.withdraw(cubebtc, quantity / 1e18)
    assert approx(pool.quoteWithdraw(cubebtc, quantity), rel=1e-4) == cost
    assert approx(pool.quote(cubebtc)) == sim.price(cubebtc) * 1e18

    # withdraw 2 btc bull token
    bobBalance = bob.balance()
    poolBalance = pool.balance()
    tx = pool.withdraw(cubebtc, quantity, bob, {"from": alice})
    assert approx(tx.return_value, rel=1e-4) == cost
    assert approx(bob.balance() - bobBalance, rel=1e-4) == cost
    assert approx(poolBalance - pool.balance(), rel=1e-4) == cost
    assert approx(cubebtc.balanceOf(alice)) == 0
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance(), rel=1e-4) == sim.poolBalance
    assert approx(pool.totalValue(), rel=1e-3) == sim.totalValue()
    assert (
        approx(pool.params(cubebtc)[LAST_PRICE_INDEX])
        == sim.prices[cubebtc] / sim.initialPrices[cubebtc] * 1e18
    )
    assert approx(pool.params(cubebtc)[LAST_UPDATED_INDEX], abs=2) == chain.time()

    # check events
    (ev,) = tx.events["DepositOrWithdraw"]
    assert ev["cubeToken"] == cubebtc
    assert ev["sender"] == alice
    assert ev["to"] == bob
    assert not ev["isDeposit"]
    assert approx(ev["quantity"]) == quantity
    assert approx(ev["ethAmount"], rel=1e-4) == cost

    (ev,) = tx.events["Update"]
    assert ev["cubeToken"] == cubebtc
    assert (
        approx(ev["price"]) == sim.prices[cubebtc] / sim.initialPrices[cubebtc] * 1e18
    )

    # check btc bear token price
    quantity = invbtc.balanceOf(alice)
    px = sim.price(invbtc) * 1e18
    cost = sim.withdraw(invbtc, quantity / 1e18)
    assert approx(pool.quoteWithdraw(invbtc, quantity), rel=1e-4) == cost
    assert approx(pool.quote(invbtc), rel=1e-4) == px

    # withdraw 1 btc bear token
    bobBalance = bob.balance()
    poolBalance = pool.balance()
    tx = pool.withdraw(invbtc, quantity, bob, {"from": alice})
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
    assert approx(pool.params(invbtc)[LAST_UPDATED_INDEX], abs=2) == chain.time()

    # check events
    (ev,) = tx.events["DepositOrWithdraw"]
    assert ev["cubeToken"] == invbtc
    assert ev["sender"] == alice
    assert ev["to"] == bob
    assert not ev["isDeposit"]
    assert approx(ev["quantity"]) == quantity
    assert approx(ev["ethAmount"], rel=1e-4) == cost
    (ev,) = tx.events["Update"]
    assert ev["cubeToken"] == invbtc
    assert approx(ev["price"]) == sim.prices[invbtc] / sim.initialPrices[invbtc] * 1e18

    # deposit 0 does nothing
    assert pool.deposit(cubebtc, alice, {"from": bob}).return_value == 0

    # withdraw 0 does nothing
    assert pool.withdraw(cubebtc, 0, bob, {"from": alice}).return_value == 0


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
    BTC = feedsRegistry.stringToBytes32("BTC")
    feedsRegistry.addUsdFeed(BTC, btcusd)

    tx = pool.addCubeToken(BTC, LONG)
    cubebtc = CubeToken.at(tx.return_value)

    tx = pool.addCubeToken(BTC, SHORT)
    invbtc = CubeToken.at(tx.return_value)

    # set fee
    with reverts("Ownable: caller is not the owner"):
        pool.setFee(cubebtc, 100, {"from": alice})

    pool.setFee(cubebtc, 100)  # 1%
    assert pool.params(cubebtc)[FEE_INDEX] == 100

    pool.setFee(cubebtc, 0)
    assert pool.params(cubebtc)[FEE_INDEX] == 0

    pool.setFee(cubebtc, 100)  # 1%
    assert pool.params(cubebtc)[FEE_INDEX] == 100

    with reverts("Fee should be < 100%"):
        pool.setFee(cubebtc, 1e4)

    pool.setFee(invbtc, 100)  # 1%

    # set max tvl
    with reverts("Ownable: caller is not the owner"):
        pool.setMaxTvl(1e18, {"from": alice})

    pool.setMaxTvl(2e18)
    assert pool.maxTvl() == 2e18

    with reverts("Max TVL exceeded"):
        pool.deposit(cubebtc, alice, {"from": alice, "value": 2.03e18})

    pool.deposit(cubebtc, alice, {"from": alice, "value": 2e18})

    pool.setMaxTvl(0)
    assert pool.maxTvl() == 0

    pool.deposit(cubebtc, alice, {"from": alice, "value": 1e18})

    # set max pool share
    pool.setMaxPoolShare(invbtc, 5000)  # 50%
    assert pool.params(cubebtc)[MAX_POOL_SHARE_INDEX] == 0
    assert pool.params(invbtc)[MAX_POOL_SHARE_INDEX] == 5000

    with reverts("Max pool share exceeded"):
        pool.deposit(invbtc, alice, {"from": alice, "value": 3.04e18})

    pool.deposit(invbtc, alice, {"from": alice, "value": 3e18})

    pool.setMaxPoolShare(invbtc, 0)
    assert pool.params(invbtc)[MAX_POOL_SHARE_INDEX] == 0

    pool.deposit(invbtc, alice, {"from": alice, "value": 1e18})

    # collect fee
    assert pool.feeAccrued() == 7e16

    with reverts("Ownable: caller is not the owner"):
        pool.collectFee({"from": alice})

    balance = deployer.balance()
    pool.collectFee()
    assert deployer.balance() - balance == 7e16
    assert pool.feeAccrued() == 0

    # pause deposit
    with reverts("Must be owner or guardian"):
        pool.setPaused(cubebtc, True, False, False, {"from": alice})

    pool.setPaused(cubebtc, True, False, False)

    with reverts("Paused"):
        pool.deposit(cubebtc, alice, {"from": alice, "value": 1e18})
    pool.deposit(invbtc, alice, {"from": alice, "value": 1e18})

    pool.setPaused(cubebtc, False, False, False)
    pool.deposit(cubebtc, alice, {"from": alice, "value": 1e18})

    # pause withdraw
    with reverts("Must be owner or guardian"):
        pool.setPaused(cubebtc, False, True, False, {"from": alice})

    pool.setPaused(cubebtc, False, True, False)

    with reverts("Paused"):
        pool.withdraw(cubebtc, 1e18, alice, {"from": alice})
    pool.withdraw(invbtc, 1e18, alice, {"from": alice})

    pool.setPaused(cubebtc, False, False, False)
    pool.withdraw(cubebtc, 1e18, alice, {"from": alice})

    # pause price set
    with reverts("Must be owner or guardian"):
        pool.setPaused(cubebtc, False, False, True, {"from": alice})

    pool.setPaused(cubebtc, False, False, True)

    t = pool.params(cubebtc)[LAST_UPDATED_INDEX]
    chain.sleep(1)
    pool.update(cubebtc, {"from": alice})
    assert pool.params(cubebtc)[LAST_UPDATED_INDEX] == t

    t = pool.params(invbtc)[LAST_UPDATED_INDEX]
    chain.sleep(1)
    pool.update(invbtc, {"from": alice})
    assert pool.params(invbtc)[LAST_UPDATED_INDEX] > t

    pool.setPaused(cubebtc, False, False, False)

    t = pool.params(cubebtc)[LAST_UPDATED_INDEX]
    chain.sleep(1)
    pool.update(cubebtc, {"from": alice})
    assert pool.params(cubebtc)[LAST_UPDATED_INDEX] > t

    # add guardian
    assert pool.guardian() == ZERO_ADDRESS
    with reverts("Ownable: caller is not the owner"):
        pool.setGuardian(alice, {"from": alice})
    pool.setGuardian(alice)
    assert pool.guardian() == alice

    pool.setPaused(cubebtc, True, True, True, {"from": alice})
    pool.setPaused(cubebtc, False, False, False, {"from": alice})
