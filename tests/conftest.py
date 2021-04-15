import pytest


LONG, SHORT = False, True


@pytest.fixture
def gov(accounts):
    yield accounts[0]


@pytest.fixture
def alice(accounts):
    yield accounts[1]


@pytest.fixture
def bob(accounts):
    yield accounts[2]


@pytest.fixture
def btcusd(gov, MockAggregatorV3Interface):
    feed = gov.deploy(MockAggregatorV3Interface)
    feed.setPrice(50000 * 1e8)
    yield feed


@pytest.fixture
def feedsRegistry(gov, ChainlinkFeedsRegistry):
    yield gov.deploy(ChainlinkFeedsRegistry)


@pytest.fixture
def poolEmpty(gov, feedsRegistry, CubeToken, CubePool, btcusd):
    key = feedsRegistry.stringToBytes32("BTC")
    feedsRegistry.addUsdFeed(key, btcusd)

    cubeTokenImpl = gov.deploy(CubeToken)
    yield gov.deploy(CubePool, feedsRegistry, cubeTokenImpl)


@pytest.fixture
def pool(poolEmpty):
    poolEmpty.setProtocolFee(2000)
    poolEmpty.addCubeToken("BTC", LONG, 150, 100, 0)
    poolEmpty.addCubeToken("BTC", SHORT, 150, 100, 0)
    yield poolEmpty


@pytest.fixture
def cubebtc(pool, CubeToken):
    yield CubeToken.at(pool.cubeTokens(0))


@pytest.fixture
def invbtc(pool, CubeToken):
    yield CubeToken.at(pool.cubeTokens(1))


@pytest.fixture(params=[cubebtc, invbtc])
def cubeToken(request):
    yield request.param

