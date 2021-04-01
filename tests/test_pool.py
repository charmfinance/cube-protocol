from brownie import chain, reverts, ZERO_ADDRESS
from collections import defaultdict
import pytest
from pytest import approx


LONG, SHORT = False, True
FEE_INDEX = 6
MAX_POOL_SHARE_INDEX = 7
LAST_PRICE_INDEX = 9
LAST_UPDATED_INDEX = 10


class Sim(object):
    def __init__(self, protocolFee):
        self.protocolFee = protocolFee
        self.quantities = defaultdict(int)
        self.prices = defaultdict(int)
        self.initialPrices = defaultdict(int)
        self.balance = 0
        self.poolBalance = 0
        self.accruedProtocolFees = 0

    # returns eth cost of deposit
    def deposit(self, symbol, quantity):
        return self._trade(symbol, quantity, 1)

    # returns eth amount returned from withdrawal
    def withdraw(self, symbol, quantity):
        return self._trade(symbol, quantity, -1)

    def _trade(self, symbol, quantity, sign):
        cost = quantity * self.price(symbol)
        self.quantities[symbol] += sign * quantity

        fee = 1.0 / 0.99 - 1.0 if sign == 1 else 0.01
        fees = fee * cost * 1e18
        self.balance += sign * cost * 1e18 + fees
        self.poolBalance += sign * cost * 1e18 + (1.0 - self.protocolFee) * fees

        self.accruedProtocolFees += self.protocolFee * fees
        return cost * 1e18 + sign * fees

    def price(self, symbol):
        if self.totalEquity() > 0:
            return (
                self.prices[symbol]
                * self.poolBalance
                / self.initialPrices[symbol]
                / self.totalEquity()
                * 1e18
            )
        else:
            return 1.0

    def totalEquity(self):
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
    cubeTokenImpl = deployer.deploy(CubeToken)
    pool = deployer.deploy(CubePool, feedsRegistry, cubeTokenImpl)

    with reverts("!governance"):
        pool.addCubeToken("BTC", LONG, 0, 0, {"from": alice})

    with reverts("Spot price should be > 0"):
        pool.addCubeToken("BTC", LONG, 0, 0)

    btcusd = deployer.deploy(MockAggregatorV3Interface)
    btcusd.setPrice(50000 * 1e8)
    BTC = feedsRegistry.stringToBytes32("BTC")
    feedsRegistry.addUsdFeed(BTC, btcusd)
    assert feedsRegistry.getPrice(BTC) == 50000 * 1e8

    btcusd.setPrice(0)
    with reverts("Spot price should be > 0"):
        pool.addCubeToken("BTC", LONG, 0, 0)

    # add bull token
    btcusd.setPrice(50000 * 1e8)
    tx = pool.addCubeToken("BTC", LONG, 100, 2500)

    cubebtc = CubeToken.at(tx.return_value)
    assert cubebtc.name() == "3X Long BTC"
    assert cubebtc.symbol() == "cubeBTC"
    assert pool.numCubeTokens() == 1
    assert pool.cubeTokens(0) == cubebtc

    (
        currencyKey,
        inverse,
        depositPaused,
        withdrawPaused,
        updatePaused,
        added,
        depositWithdrawFee,
        maxPoolShare,
        initialSpotPrice,
        lastPrice,
        lastUpdated,
    ) = pool.params(cubebtc)
    assert currencyKey == BTC
    assert inverse == LONG
    assert not depositPaused
    assert not withdrawPaused
    assert not updatePaused
    assert added
    assert depositWithdrawFee == 100
    assert maxPoolShare == 2500
    assert approx(initialSpotPrice) == 50000 * 1e8
    assert lastPrice == 1e18
    assert approx(lastUpdated, abs=3) == chain.time()

    # check event
    (ev,) = tx.events["AddCubeToken"]
    assert ev["cubeToken"] == cubebtc
    assert ev["spotSymbol"] == "BTC"
    assert ev["inverse"] == LONG

    (ev,) = tx.events["Update"]
    assert ev["cubeToken"] == cubebtc
    assert approx(ev["price"]) == 1e18

    # add bear token
    tx = pool.addCubeToken("BTC", SHORT, 200, 5000)

    invbtc = CubeToken.at(tx.return_value)
    assert invbtc.name() == "3X Short BTC"
    assert invbtc.symbol() == "invBTC"
    assert pool.numCubeTokens() == 2
    assert pool.cubeTokens(1) == invbtc

    (
        currencyKey,
        inverse,
        depositPaused,
        withdrawPaused,
        updatePaused,
        added,
        depositWithdrawFee,
        maxPoolShare,
        initialSpotPrice,
        lastPrice,
        lastUpdated,
    ) = pool.params(invbtc)
    assert currencyKey == BTC
    assert inverse == SHORT
    assert not depositPaused
    assert not withdrawPaused
    assert not updatePaused
    assert added
    assert depositWithdrawFee == 200
    assert maxPoolShare == 5000
    assert approx(initialSpotPrice) == 50000 * 1e8
    assert lastPrice == 1e18
    assert approx(lastUpdated, abs=3) == chain.time()

    # check event
    (ev,) = tx.events["AddCubeToken"]
    assert ev["cubeToken"] == invbtc
    assert ev["spotSymbol"] == "BTC"
    assert ev["inverse"] == SHORT

    (ev,) = tx.events["Update"]
    assert ev["cubeToken"] == invbtc
    assert approx(ev["price"]) == 1e18

    assert pool.numCubeTokens() == 2
    assert pool.cubeTokens(0) == cubebtc
    assert pool.cubeTokens(1) == invbtc

    with reverts("Already added"):
        pool.addCubeToken("BTC", LONG, 0, 0)

    assert pool.poolBalance() == 0
    assert pool.totalEquity() == 0


@pytest.mark.parametrize("px1,px2", [(50000, 40000), (1e8, 1e7), (1, 1e1)])
@pytest.mark.parametrize("qty", [1, 1e-5, 10])
@pytest.mark.parametrize("protocolFee", [0, 0.2, 1])
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
    protocolFee,
):
    deployer, alice, bob = a[:3]

    # deploy pool
    feedsRegistry = deployer.deploy(ChainlinkFeedsRegistry)
    cubeTokenImpl = deployer.deploy(CubeToken)
    pool = deployer.deploy(CubePool, feedsRegistry, cubeTokenImpl)

    btcusd = deployer.deploy(MockAggregatorV3Interface)
    btcusd.setPrice(px1 * 1e8)
    BTC = feedsRegistry.stringToBytes32("BTC")
    feedsRegistry.addUsdFeed(BTC, btcusd)

    tx = pool.addCubeToken("BTC", LONG, 100, 0)
    cubebtc = CubeToken.at(tx.return_value)

    tx = pool.addCubeToken("BTC", SHORT, 100, 0)
    invbtc = CubeToken.at(tx.return_value, 0, 0)

    pool.setProtocolFee(protocolFee * 1e4)

    with reverts("Not added"):
        pool.deposit(ZERO_ADDRESS, alice, {"from": bob, "value": 1e18})
    with reverts("Not added"):
        pool.withdraw(ZERO_ADDRESS, 1e18, alice, {"from": bob})

    with reverts("msg.value should be > 0"):
        pool.deposit(cubebtc, alice, {"from": bob})
    with reverts("cubeTokensIn should be > 0"):
        pool.withdraw(cubebtc, 0, alice, {"from": bob})

    with reverts("Zero address"):
        pool.deposit(cubebtc, ZERO_ADDRESS, {"from": bob, "value": 1e18})
    with reverts("Zero address"):
        pool.withdraw(cubebtc, 1e18, ZERO_ADDRESS, {"from": bob})

    assert feedsRegistry.getPrice(BTC) == px1 * 1e8

    sim = Sim(protocolFee)
    sim.prices[cubebtc] = px1 ** 3
    sim.prices[invbtc] = px1 ** -3
    sim.initialPrices[cubebtc] = px1 ** 3
    sim.initialPrices[invbtc] = px1 ** -3

    # check btc bull token price
    assert approx(pool.quote(cubebtc)) == sim.price(cubebtc) * 1e18
    cost = sim.deposit(cubebtc, qty)
    assert approx(pool.quoteDeposit(cubebtc, cost)) == qty * 1e18

    # deposit 1 btc bull token
    bobBalance = bob.balance()
    poolBalance = pool.balance()
    tx = pool.deposit(cubebtc, alice, {"from": bob, "value": cost})
    assert approx(tx.return_value) == qty * 1e18
    assert approx(bobBalance - bob.balance()) == cost
    assert approx(pool.balance() - poolBalance) == cost
    assert approx(cubebtc.balanceOf(alice)) == qty * 1e18
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalEquity()) == sim.totalEquity()
    assert approx(pool.params(cubebtc)[LAST_PRICE_INDEX]) == 1e18
    assert approx(pool.params(cubebtc)[LAST_UPDATED_INDEX], abs=3) == chain.time()
    update_time = chain.time()
    chain.sleep(1)

    # check events
    (ev,) = tx.events["DepositOrWithdraw"]
    assert ev["cubeToken"] == cubebtc
    assert ev["sender"] == bob
    assert ev["recipient"] == alice
    assert ev["isDeposit"]
    assert approx(ev["cubeTokenQuantity"]) == qty * 1e18
    assert approx(ev["ethAmount"]) == cost
    assert approx(ev["protocolFees"]) == protocolFee * cost * 0.01

    assert "Update" not in tx.events

    # pause price updates and change oracle price, which shouldn't be reflected
    # until later
    pool.setPaused(invbtc, False, False, True)
    btcusd.setPrice(px2 * 1e8)
    assert feedsRegistry.getPrice(BTC) == px2 * 1e8
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalEquity()) == sim.totalEquity()

    # check btc bear token price
    assert approx(pool.quote(invbtc)) == sim.price(invbtc) * 1e18
    cost = sim.deposit(invbtc, qty)
    assert approx(pool.quoteDeposit(invbtc, cost)) == qty * 1e18

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
    assert approx(pool.totalEquity()) == sim.totalEquity()
    assert approx(pool.params(invbtc)[LAST_PRICE_INDEX]) == 1e18
    assert (
        approx(pool.params(invbtc)[LAST_UPDATED_INDEX], abs=3)
        == update_time
        < chain.time()
    )

    # check events
    (ev,) = tx.events["DepositOrWithdraw"]
    assert ev["cubeToken"] == invbtc
    assert ev["sender"] == bob
    assert ev["recipient"] == alice
    assert ev["isDeposit"]
    assert approx(ev["cubeTokenQuantity"]) == qty * 1e18
    assert approx(ev["ethAmount"]) == cost
    assert approx(ev["protocolFees"]) == protocolFee * cost * 0.01

    assert "Update" not in tx.events

    # unpause price updates
    pool.setPaused(invbtc, False, False, False)

    # update btc bull price
    tx = pool.update(cubebtc)
    sim.prices[cubebtc] = px2 ** 3
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalEquity()) == sim.totalEquity()

    (ev,) = tx.events["Update"]
    assert ev["cubeToken"] == cubebtc
    assert (
        approx(ev["price"]) == sim.prices[cubebtc] / sim.initialPrices[cubebtc] * 1e18
    )

    # update btc bear price
    tx = pool.update(invbtc)
    sim.prices[invbtc] = px2 ** -3
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalEquity()) == sim.totalEquity()

    (ev,) = tx.events["Update"]
    assert ev["cubeToken"] == invbtc
    assert approx(ev["price"]) == sim.prices[invbtc] / sim.initialPrices[invbtc] * 1e18

    # check btc bull token price
    assert approx(pool.quote(cubebtc)) == sim.price(cubebtc) * 1e18
    cost = sim.deposit(cubebtc, qty)
    assert approx(pool.quoteDeposit(cubebtc, cost)) == qty * 1e18

    # deposit 1 btc bull token
    bobBalance = bob.balance()
    poolBalance = pool.balance()
    tx = pool.deposit(cubebtc, alice, {"from": bob, "value": cost})
    assert approx(tx.return_value) == qty * 1e18
    assert approx(bobBalance - bob.balance()) == cost
    assert approx(pool.balance() - poolBalance) == cost
    assert approx(cubebtc.balanceOf(alice)) == 2 * qty * 1e18
    assert approx(pool.balance()) == sim.balance
    assert approx(pool.poolBalance()) == sim.poolBalance
    assert approx(pool.totalEquity()) == sim.totalEquity()
    assert (
        approx(pool.params(cubebtc)[LAST_PRICE_INDEX])
        == sim.prices[cubebtc] / sim.initialPrices[cubebtc] * 1e18
    )
    assert approx(pool.params(cubebtc)[LAST_UPDATED_INDEX], abs=3) == chain.time()

    # check events
    (ev,) = tx.events["DepositOrWithdraw"]
    assert ev["cubeToken"] == cubebtc
    assert ev["sender"] == bob
    assert ev["recipient"] == alice
    assert ev["isDeposit"]
    assert approx(ev["cubeTokenQuantity"]) == qty * 1e18
    assert approx(ev["ethAmount"]) == cost
    assert approx(ev["protocolFees"]) == protocolFee * cost * 0.01

    assert "Update" not in tx.events

    # check btc bull token price
    assert approx(pool.quote(cubebtc)) == sim.price(cubebtc) * 1e18
    quantity = cubebtc.balanceOf(alice)
    cost = sim.withdraw(cubebtc, quantity / 1e18)
    assert approx(pool.quoteWithdraw(cubebtc, quantity)) == cost

    # withdraw 2 btc bull token
    bobBalance = bob.balance()
    poolBalance = pool.balance()
    tx = pool.withdraw(cubebtc, quantity, bob, {"from": alice})
    assert approx(tx.return_value) == cost
    assert approx(bob.balance() - bobBalance) == cost
    assert approx(poolBalance - pool.balance()) == cost
    assert approx(cubebtc.balanceOf(alice)) == 0
    assert approx(pool.balance()) == sim.balance
    assert (
        approx(pool.poolBalance() / poolBalance) == sim.poolBalance / poolBalance
    )  # divide by prev to fix rounding
    assert approx(pool.totalEquity()) == sim.totalEquity()
    assert (
        approx(pool.params(cubebtc)[LAST_PRICE_INDEX])
        == sim.prices[cubebtc] / sim.initialPrices[cubebtc] * 1e18
    )
    assert approx(pool.params(cubebtc)[LAST_UPDATED_INDEX], abs=3) == chain.time()

    # check events
    (ev,) = tx.events["DepositOrWithdraw"]
    assert ev["cubeToken"] == cubebtc
    assert ev["sender"] == alice
    assert ev["recipient"] == bob
    assert not ev["isDeposit"]
    assert approx(ev["cubeTokenQuantity"]) == quantity
    assert approx(float(ev["ethAmount"])) == cost
    assert approx(float(ev["protocolFees"])) == int(protocolFee * cost / 99.0)

    assert "Update" not in tx.events

    # can't withdraw all
    quantity = invbtc.balanceOf(alice)
    with reverts("Min total equity exceeded"):
        pool.withdraw(invbtc, quantity, bob, {"from": alice})

    # check btc bear token price
    quantity = invbtc.balanceOf(alice)
    px = sim.price(invbtc) * 1e18
    cost = sim.withdraw(invbtc, 0.9 * quantity / 1e18)
    assert approx(pool.quoteWithdraw(invbtc, 0.9 * quantity)) == cost
    assert approx(pool.quote(invbtc)) == px

    # withdraw 1 btc bear token
    bobBalance = bob.balance()
    poolBalance = pool.balance()
    tx = pool.withdraw(invbtc, 0.9 * quantity, bob, {"from": alice})
    assert approx(tx.return_value) == cost
    assert approx(bob.balance() - bobBalance) == cost
    assert approx(poolBalance - pool.balance()) == cost
    assert approx(invbtc.balanceOf(alice)) == 0.1 * quantity
    assert approx(pool.balance()) == sim.balance
    assert (
        approx(pool.poolBalance() / poolBalance, rel=1e-4)
        == sim.poolBalance / poolBalance
    )  # divide by prev to fix rounding
    assert approx(pool.totalEquity(), rel=1e-5) == sim.totalEquity()
    assert (
        approx(pool.params(invbtc)[LAST_PRICE_INDEX])
        == sim.prices[invbtc] / sim.initialPrices[invbtc] * 1e18
    )
    assert approx(pool.params(invbtc)[LAST_UPDATED_INDEX], abs=3) == chain.time()

    # check events
    (ev,) = tx.events["DepositOrWithdraw"]
    assert ev["cubeToken"] == invbtc
    assert ev["sender"] == alice
    assert ev["recipient"] == bob
    assert not ev["isDeposit"]
    assert approx(ev["cubeTokenQuantity"]) == 0.9 * quantity
    assert approx(float(ev["ethAmount"])) == cost
    assert approx(float(ev["protocolFees"])) == int(protocolFee * cost / 99.0)

    assert "Update" not in tx.events


def test_governance_methods(
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
    cubeTokenImpl = deployer.deploy(CubeToken)
    pool = deployer.deploy(CubePool, feedsRegistry, cubeTokenImpl)

    btcusd = deployer.deploy(MockAggregatorV3Interface)
    btcusd.setPrice(50000 * 1e8)
    BTC = feedsRegistry.stringToBytes32("BTC")
    feedsRegistry.addUsdFeed(BTC, btcusd)

    tx = pool.addCubeToken(BTC, LONG, 0, 0)
    cubebtc = CubeToken.at(tx.return_value)

    tx = pool.addCubeToken(BTC, SHORT, 0, 0)
    invbtc = CubeToken.at(tx.return_value)

    # set fee
    with reverts("!governance"):
        pool.setDepositWithdrawFee(cubebtc, 100, {"from": alice})

    assert pool.params(cubebtc)[FEE_INDEX] == 0
    pool.setDepositWithdrawFee(cubebtc, 100)  # 1%
    assert pool.params(cubebtc)[FEE_INDEX] == 100

    pool.setDepositWithdrawFee(cubebtc, 0)
    assert pool.params(cubebtc)[FEE_INDEX] == 0

    pool.setDepositWithdrawFee(cubebtc, 100)  # 1%
    assert pool.params(cubebtc)[FEE_INDEX] == 100

    with reverts("Fee should be < 100%"):
        pool.setDepositWithdrawFee(cubebtc, 1e4)

    pool.setDepositWithdrawFee(invbtc, 100)  # 1%

    # set protocol fee
    with reverts("!governance"):
        pool.setProtocolFee(2000, {"from": alice})

    assert pool.protocolFee() == 0
    pool.setProtocolFee(2000)  # 20%
    assert pool.protocolFee() == 2000

    # set max tvl
    with reverts("!governance"):
        pool.setMaxPoolBalance(1e18, {"from": alice})

    assert pool.maxPoolBalance() == 0
    pool.setMaxPoolBalance(2e18)
    assert pool.maxPoolBalance() == 2e18

    with reverts("Max pool balance exceeded"):
        pool.deposit(cubebtc, alice, {"from": alice, "value": 2.03e18})

    pool.deposit(cubebtc, alice, {"from": alice, "value": 2e18})

    pool.setMaxPoolBalance(0)
    assert pool.maxPoolBalance() == 0

    pool.deposit(cubebtc, alice, {"from": alice, "value": 1e18})

    # set max pool share
    pool.setMaxPoolShare(invbtc, 5000)  # 50%
    assert pool.params(invbtc)[MAX_POOL_SHARE_INDEX] == 5000

    with reverts("Max pool share exceeded"):
        pool.deposit(invbtc, alice, {"from": alice, "value": 3.04e18})

    pool.deposit(invbtc, alice, {"from": alice, "value": 3e18})

    pool.setMaxPoolShare(invbtc, 0)
    assert pool.params(invbtc)[MAX_POOL_SHARE_INDEX] == 0

    pool.deposit(invbtc, alice, {"from": alice, "value": 1e18})

    # collect fees
    assert pool.accruedProtocolFees() == 0.2 * 7e16

    with reverts("!governance"):
        pool.collectProtocolFees({"from": alice})

    balance = deployer.balance()
    pool.collectProtocolFees()
    assert deployer.balance() - balance == 0.2 * 7e16
    assert pool.accruedProtocolFees() == 0

    # pause deposit
    with reverts("!governance and !guardian"):
        pool.setPaused(cubebtc, True, False, False, {"from": alice})

    pool.setPaused(cubebtc, True, False, False)

    with reverts("Paused"):
        pool.deposit(cubebtc, alice, {"from": alice, "value": 1e18})
    pool.deposit(invbtc, alice, {"from": alice, "value": 1e18})

    pool.setPaused(cubebtc, False, False, False)
    pool.deposit(cubebtc, alice, {"from": alice, "value": 1e18})

    # pause withdraw
    with reverts("!governance and !guardian"):
        pool.setPaused(cubebtc, False, True, False, {"from": alice})

    pool.setPaused(cubebtc, False, True, False)

    with reverts("Paused"):
        pool.withdraw(cubebtc, 1e18, alice, {"from": alice})
    pool.withdraw(invbtc, 1e18, alice, {"from": alice})

    pool.setPaused(cubebtc, False, False, False)
    pool.withdraw(cubebtc, 1e18, alice, {"from": alice})

    # pause price set
    with reverts("!governance and !guardian"):
        pool.setPaused(cubebtc, False, False, True, {"from": alice})

    pool.setPaused(cubebtc, False, False, True)

    # doesn't update because paused
    t = pool.params(cubebtc)[LAST_UPDATED_INDEX]
    chain.sleep(1)
    pool.update(cubebtc, {"from": alice})
    assert pool.params(cubebtc)[LAST_UPDATED_INDEX] == t

    # doesn't update because no price change
    t = pool.params(invbtc)[LAST_UPDATED_INDEX]
    chain.sleep(1)
    pool.update(invbtc, {"from": alice})
    assert pool.params(invbtc)[LAST_UPDATED_INDEX] == t

    btcusd.setPrice(60000 * 1e8)
    t = pool.params(invbtc)[LAST_UPDATED_INDEX]
    chain.sleep(1)
    pool.update(invbtc, {"from": alice})
    assert pool.params(invbtc)[LAST_UPDATED_INDEX] > t

    # unpause
    pool.setPaused(cubebtc, False, False, False)

    t = pool.params(cubebtc)[LAST_UPDATED_INDEX]
    chain.sleep(1)
    pool.update(cubebtc, {"from": alice})
    assert pool.params(cubebtc)[LAST_UPDATED_INDEX] > t

    # add guardian
    assert pool.guardian() == ZERO_ADDRESS
    with reverts("!governance"):
        pool.setGuardian(alice, {"from": alice})
    pool.setGuardian(alice)
    assert pool.guardian() == alice

    pool.setPaused(cubebtc, True, True, True, {"from": alice})
    pool.setPaused(cubebtc, False, False, False, {"from": alice})

    balance = pool.poolBalance()
    alice.transfer(pool, 1e18)
    assert pool.poolBalance() - balance == 1e18

    with reverts("!governance"):
        pool.setGovernance(alice, {"from": alice})
    pool.setGovernance(alice)
    assert pool.governance() == deployer

    with reverts("!pendingGovernance"):
        pool.acceptGovernance({"from": bob})
    pool.acceptGovernance({"from": alice})
    assert pool.governance() == alice
