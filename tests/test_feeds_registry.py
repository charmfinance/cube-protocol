from brownie import reverts, ZERO_ADDRESS


def test_feeds_registry(
    a, ChainlinkFeedsRegistry, MockAggregatorV3Interface, MockToken
):
    deployer, alice = a[:2]

    aaausd = deployer.deploy(MockAggregatorV3Interface)
    aaaeth = deployer.deploy(MockAggregatorV3Interface)
    bbbeth = deployer.deploy(MockAggregatorV3Interface)
    cccusd = deployer.deploy(MockAggregatorV3Interface)
    ethusd = deployer.deploy(MockAggregatorV3Interface)

    feeds = deployer.deploy(ChainlinkFeedsRegistry)
    toBytes = lambda s: feeds.stringToBytes32(s)

    AAA = toBytes("AAA")
    BBB = toBytes("BBB")
    CCC = toBytes("CCC")
    DDD = toBytes("DDD")
    ETH = toBytes("ETH")
    USD = toBytes("USD")

    assert feeds.ETH() == ETH
    assert feeds.USD() == USD

    with reverts("Ownable: caller is not the owner"):
        feeds.addUsdFeed(AAA, aaausd, {"from": alice})
    with reverts("Ownable: caller is not the owner"):
        feeds.addEthFeed(AAA, aaaeth, {"from": alice})

    with reverts("Price should be > 0"):
        feeds.addUsdFeed(AAA, aaausd)
    with reverts("Price should be > 0"):
        feeds.addEthFeed(AAA, aaaeth)

    aaausd.setPrice(0.1 * 1e8)
    aaaeth.setPrice(0.0000555 * 1e18)
    bbbeth.setPrice(10 * 1e18)
    cccusd.setPrice(100 * 1e8)
    ethusd.setPrice(2000 * 1e8)

    feeds.addUsdFeed(AAA, aaausd)
    feeds.addEthFeed(BBB, bbbeth)
    feeds.addUsdFeed(CCC, cccusd)
    feeds.addEthFeed(AAA, aaaeth)

    assert feeds.getPrice(AAA) == 0.1 * 1e8
    assert feeds.getPrice(BBB) == 0
    assert feeds.getPrice(CCC) == 100 * 1e8
    assert feeds.getPrice(ETH) == 0

    assert feeds.getPriceFromSymbol("AAA") == 0.1 * 1e8
    assert feeds.getPriceFromSymbol("BBB") == 0
    assert feeds.getPriceFromSymbol("CCC") == 100 * 1e8
    assert feeds.getPriceFromSymbol("ETH") == 0

    feeds.addUsdFeed(ETH, ethusd)

    assert feeds.getPrice(AAA) == 0.1 * 1e8
    assert feeds.getPrice(BBB) == 20000 * 1e8
    assert feeds.getPrice(CCC) == 100 * 1e8
    assert feeds.getPrice(ETH) == 2000 * 1e8

    cccusd.setPrice(120 * 1e8)
    bbbeth.setPrice(11 * 1e18)
    ethusd.setPrice(2200 * 1e8)

    assert feeds.getPrice(BBB) == 24200 * 1e8
    assert feeds.getPrice(CCC) == 120 * 1e8

    cccusd.setPrice(0)
    assert feeds.getPrice(CCC) == 0

    assert feeds.getPrice(DDD) == 0
    assert feeds.getPrice(USD) == 1e8
