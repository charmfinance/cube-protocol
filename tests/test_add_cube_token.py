from brownie import chain, reverts, ZERO_ADDRESS
import pytest
from pytest import approx


LONG, SHORT = False, True


def test_cannot_add_if_not_gov(poolEmpty, alice):
    with reverts("!governance"):
        poolEmpty.addCubeToken("BTC", LONG, 150, 100, 2500, {"from": alice})


def test_cannot_add_if_price_zero(poolEmpty, gov, btcusd):
    btcusd.setPrice(0)
    with reverts("Spot price should be > 0"):
        poolEmpty.addCubeToken("BTC", LONG, 150, 100, 2500, {"from": gov})


def test_add(poolEmpty, gov, feedsRegistry, CubeToken):
    # add cubeBTC
    tx = poolEmpty.addCubeToken("BTC", LONG, 150, 100, 2500)
    cubebtc = CubeToken.at(tx.return_value)
    assert cubebtc.name() == "3X Long BTC"
    assert cubebtc.symbol() == "cubeBTC"
    assert poolEmpty.numCubeTokens() == 1
    assert poolEmpty.cubeTokens(0) == cubebtc

    # check event
    (ev,) = tx.events["AddCubeToken"]
    assert ev["cubeToken"] == cubebtc
    assert ev["spotSymbol"] == "BTC"
    assert not ev["inverse"]

    # add invBTC
    tx = poolEmpty.addCubeToken("BTC", SHORT, 150, 100, 2500)
    cubebtc = CubeToken.at(tx.return_value)
    assert cubebtc.name() == "3X Short BTC"
    assert cubebtc.symbol() == "invBTC"
    assert poolEmpty.numCubeTokens() == 2
    assert poolEmpty.cubeTokens(1) == cubebtc

    # check event
    (ev,) = tx.events["AddCubeToken"]
    assert ev["cubeToken"] == cubebtc
    assert ev["spotSymbol"] == "BTC"
    assert ev["inverse"]


def test_cannot_add_again(poolEmpty, gov):
    poolEmpty.addCubeToken("BTC", LONG, 150, 100, 2500)
    with reverts("Already added"):
        poolEmpty.addCubeToken("BTC", LONG, 150, 100, 2500)


def test_params(poolEmpty, gov, feedsRegistry):
    # add two cube tokens
    t = chain.time()
    poolEmpty.addCubeToken("BTC", LONG, 150, 100, 2500)
    poolEmpty.addCubeToken("BTC", SHORT, 150, 100, 2500)

    # fast-forward time
    chain.sleep(3600)

    # check params
    for i in range(2):
        (
            currencyKey,
            inverse,
            depositPaused,
            withdrawPaused,
            updatePaused,
            added,
            depositWithdrawFee,
            maxFundingFee,
            maxPoolShare,
            initialSpotPrice,
            lastPrice,
            lastUpdated,
        ) = poolEmpty.params(poolEmpty.cubeTokens(i))
        assert currencyKey == feedsRegistry.stringToBytes32("BTC")
        assert inverse == [LONG, SHORT][i]
        assert not depositPaused
        assert not withdrawPaused
        assert not updatePaused
        assert added
        assert depositWithdrawFee == 150
        assert maxFundingFee == 100
        assert maxPoolShare == 2500
        assert approx(initialSpotPrice) == 50000 * 1e8
        assert lastPrice == 1e18
        assert approx(lastUpdated, abs=10) == t

