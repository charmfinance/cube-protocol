from brownie import reverts, ZERO_ADDRESS


def test_feeds_registry(a, ChainlinkFeedsRegistry, MockAggregatorV3Interface, MockToken):
    deployer, alice = a[:2]

    aaa = deployer.deploy(MockToken, "AAA", "AAA", 18)
    bbb = deployer.deploy(MockToken, "BBB", "BBB", 18)
    ccc = deployer.deploy(MockToken, "CCC", "CCC", 18)
    ddd = deployer.deploy(MockToken, "DDD", "DDD", 18)
    eth = deployer.deploy(MockToken, "Ether", "ETH", 18)
    usd = deployer.deploy(MockToken, "USD Coin", "USDC", 6)

    aaausd = deployer.deploy(MockAggregatorV3Interface)
    aaaeth = deployer.deploy(MockAggregatorV3Interface)
    bbbeth = deployer.deploy(MockAggregatorV3Interface)
    cccusd = deployer.deploy(MockAggregatorV3Interface)
    ethusd = deployer.deploy(MockAggregatorV3Interface)

    feeds = deployer.deploy(ChainlinkFeedsRegistry, eth)

    with reverts("Ownable: caller is not the owner"):
        feeds.addUsdFeed(aaa, aaausd, {"from": alice})
    with reverts("Ownable: caller is not the owner"):
        feeds.addEthFeed(aaa, aaaeth, {"from": alice})

    with reverts("Price should be > 0"):
        feeds.addUsdFeed(aaa, aaausd)
    with reverts("Price should be > 0"):
        feeds.addEthFeed(aaa, aaaeth)

    aaausd.setPrice(0.1 * 1e8)
    aaaeth.setPrice(0.0000555 * 1e18)
    bbbeth.setPrice(10 * 1e18)
    cccusd.setPrice(100 * 1e8)
    ethusd.setPrice(2000 * 1e8)

    feeds.addUsdFeed(aaa, aaausd)
    feeds.addEthFeed(bbb, bbbeth)
    feeds.addUsdFeed(ccc, cccusd)
    feeds.addEthFeed(aaa, aaaeth)

    assert feeds.getPrice(aaa) == 0.1 * 1e8
    assert feeds.getPrice(bbb) == 0
    assert feeds.getPrice(ccc) == 100 * 1e8
    assert feeds.getPrice(eth) == 0

    feeds.addUsdFeed(eth, ethusd)

    assert feeds.getPrice(aaa) == 0.1 * 1e8
    assert feeds.getPrice(bbb) == 20000 * 1e8
    assert feeds.getPrice(ccc) == 100 * 1e8
    assert feeds.getPrice(eth) == 2000 * 1e8

    cccusd.setPrice(120 * 1e8)
    bbbeth.setPrice(11 * 1e18)
    ethusd.setPrice(2200 * 1e8)

    assert feeds.getPrice(bbb) == 24200 * 1e8
    assert feeds.getPrice(ccc) == 120 * 1e8

    cccusd.setPrice(0)
    assert feeds.getPrice(ccc) == 0

    assert feeds.getPrice(ddd) == 0
    assert feeds.getPrice(usd) == 0
