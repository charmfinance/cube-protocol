from brownie import chain, reverts, ZERO_ADDRESS
import pytest
from pytest import approx


LONG, SHORT = False, True

FEE_INDEX = 6
MAX_POOL_SHARE_INDEX = 8
LAST_PRICE_INDEX = 10
LAST_UPDATED_INDEX = 11


# needed to reset eth balances between tests
@pytest.fixture(scope="function", autouse=True)
def isolate(fn_isolation):
    pass


def test_cannot_deposit_before_add(poolEmpty, gov, alice, CubeToken):
    with reverts("Not added"):
        poolEmpty.deposit(gov.deploy(CubeToken), alice, {"value": "1 ether"})


def test_cannot_withdraw_before_add(poolEmpty, gov, alice, CubeToken):
    with reverts("Not added"):
        poolEmpty.withdraw(gov.deploy(CubeToken), "1 ether", alice)


def test_cannot_deposit_if_msg_value_zero(pool, alice, cubebtc):
    with reverts("msg.value should be > 0"):
        pool.deposit(cubebtc, alice)


def test_cannot_withdraw_if_amount_zero(pool, alice, cubebtc):
    with reverts("cubeTokensIn should be > 0"):
        pool.withdraw(cubebtc, 0, alice)


def test_cannot_deposit_if_recipient_zero(pool, alice, cubebtc):
    with reverts("Zero address"):
        pool.deposit(cubebtc, ZERO_ADDRESS, {"from": alice, "value": "1 ether"})


def test_cannot_withdraw_if_recipient_zero(pool, alice, cubebtc):
    with reverts("Zero address"):
        pool.withdraw(cubebtc, "1 ether", ZERO_ADDRESS, {"from": alice})


def test_cannot_deposit_more_than_balance(pool, alice, cubebtc):
    # balance is 100 eth
    assert alice.balance() == "100 ether"

    # cannot deposit 101 eth
    with pytest.raises(ValueError) as excinfo:
        pool.deposit(cubebtc, alice, {"from": alice, "value": "101 ether"})
    assert "sender doesn't have enough funds to send tx." in str(excinfo.value)

    # can deposit 99 eth
    pool.deposit(cubebtc, alice, {"from": alice, "value": "99 ether"})


def test_cannot_withdraw_more_than_balance(pool, alice, cubebtc):
    # deposit 1 eth
    pool.deposit(cubebtc, alice, {"from": alice, "value": "1 ether"})
    assert approx(cubebtc.balanceOf(alice)) == "0.985 ether"

    # cannot withdraw 0.986
    with reverts("SafeMath: subtraction overflow"):
        pool.withdraw(cubebtc, "0.986 ether", alice, {"from": alice})

    # can withdraw 0.984
    pool.withdraw(cubebtc, "0.984 ether", alice, {"from": alice})


def test_deposit(pool, alice, bob, cubebtc, invbtc):
    # do random deposits before
    pool.deposit(cubebtc, alice, {"from": bob, "value": "1 ether"})
    pool.deposit(invbtc, alice, {"from": bob, "value": "2 ether"})

    # get balances
    aliceCubes = cubebtc.balanceOf(alice)
    bobEth = bob.balance()
    poolEth = pool.balance()

    # get amount quoted
    quoted = pool.quoteDeposit(cubebtc, "3 ether")

    # deposit 3 eth
    tx = pool.deposit(cubebtc, alice, {"from": bob, "value": "3 ether"})

    # check matches quote
    assert approx(tx.return_value) == approx(cubebtc.balanceOf(alice) - aliceCubes) == quoted

    # check balances
    assert bobEth - bob.balance() == pool.balance() - poolEth == "3 ether"

    # check event
    (ev,) = tx.events["DepositOrWithdraw"]
    assert ev["cubeToken"] == cubebtc
    assert ev["sender"] == bob
    assert ev["recipient"] == alice
    assert ev["isDeposit"]
    assert approx(ev["cubeTokenQuantity"]) == quoted
    assert approx(ev["ethAmount"]) == "3 ether"

    # protocol fees are 20% of deposit fees which are 1.5% of eth amount
    assert approx(ev["protocolFees"]) == 3e18 * 0.015 * 0.2


def test_withdraw(pool, alice, bob, cubebtc, invbtc):
    # do random deposits before
    pool.deposit(cubebtc, alice, {"from": bob, "value": "5 ether"})
    pool.deposit(invbtc, alice, {"from": bob, "value": "6 ether"})

    # get balances
    aliceCubes = cubebtc.balanceOf(alice)
    bobEth = bob.balance()
    poolEth = pool.balance()

    # get amount quoted
    quoted = pool.quoteWithdraw(cubebtc, "3 ether")

    # withdraw 3 cube tokens
    tx = pool.withdraw(cubebtc, "3 ether", bob, {"from": alice})

    # check matches quote
    assert approx(tx.return_value) == approx(bob.balance() - bobEth) == quoted

    # check cube token balance
    assert approx(aliceCubes - cubebtc.balanceOf(alice)) == "3 ether"

    # check event
    (ev,) = tx.events["DepositOrWithdraw"]
    assert ev["cubeToken"] == cubebtc
    assert ev["sender"] == alice
    assert ev["recipient"] == bob
    assert not ev["isDeposit"]
    assert approx(ev["cubeTokenQuantity"]) == "3 ether"
    assert approx(ev["ethAmount"]) == quoted

    # protocol fees are 20% of withdraw fees which are 1.5% of eth amount
    total = quoted + ev["protocolFees"] / 0.2
    assert approx(ev["protocolFees"]) == total * 0.015 * 0.2


def test_invariants(pool, alice, cubebtc, invbtc, btcusd):
    def assert_total_equity():
        price1 = pool.params(cubebtc)[LAST_PRICE_INDEX]
        price2 = pool.params(invbtc)[LAST_PRICE_INDEX]
        assert pool.totalEquity() == price1 * cubebtc.totalSupply() + price2 * invbtc.totalSupply()

    def assert_pool_balance():
        assert pool.poolBalance() == pool.balance() - pool.accruedProtocolFees()

    pool.deposit(cubebtc, alice, {"from": alice, "value": "5 ether"})
    pool.deposit(invbtc, alice, {"from": alice, "value": "6 ether"})
    assert_total_equity()
    assert_pool_balance()

    pool.withdraw(cubebtc, "2 ether", alice, {"from": alice})
    pool.withdraw(invbtc, "1 ether", alice, {"from": alice})
    assert_total_equity()
    assert_pool_balance()

    btcusd.setPrice(60000 * 1e8)
    pool.update(cubebtc, {"from": alice})
    assert_total_equity()
    assert_pool_balance()

    pool.update(invbtc, {"from": alice})
    assert_total_equity()
    assert_pool_balance()


def test_price_move(pool, alice, cubebtc, invbtc, btcusd):
    pool.deposit(cubebtc, alice, {"from": alice, "value": "5 ether"})
    pool.deposit(invbtc, alice, {"from": alice, "value": "15 ether"})

    pool.update(cubebtc, {"from": alice})
    pool.update(invbtc, {"from": alice})

    px1 = pool.params(cubebtc)[LAST_PRICE_INDEX]
    px2 = pool.params(invbtc)[LAST_PRICE_INDEX]

    btcusd.setPrice(60000 * 1e8)
    pool.update(cubebtc, {"from": alice})
    pool.update(invbtc, {"from": alice})

    assert approx(pool.params(cubebtc)[LAST_PRICE_INDEX], rel=0.001) == px1 * 1.2 ** 3
    assert approx(pool.params(invbtc)[LAST_PRICE_INDEX], rel=0.001) == px1 / 1.2 ** 3


def test_funding(pool, alice, cubebtc, invbtc):
    pool.deposit(cubebtc, alice, {"from": alice, "value": "5 ether"})
    pool.deposit(invbtc, alice, {"from": alice, "value": "15 ether"})

    pool.update(cubebtc, {"from": alice})
    pool.update(invbtc, {"from": alice})

    px1 = pool.params(cubebtc)[LAST_PRICE_INDEX]
    px2 = pool.params(invbtc)[LAST_PRICE_INDEX]

    # fast-forward 2 days
    chain.sleep(2 * 24 * 60 * 60)
    pool.update(cubebtc, {"from": alice})
    pool.update(invbtc, {"from": alice})

    assert approx(pool.params(cubebtc)[LAST_PRICE_INDEX], rel=0.001) == px1 * (1.0 - 2 * 0.01 * 0.25)
    assert approx(pool.params(invbtc)[LAST_PRICE_INDEX], rel=0.001) == px1 * (1.0 - 2 * 0.01 * 0.75)
