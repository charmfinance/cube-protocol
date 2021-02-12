// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./mocks/MockAggregatorV3Interface.sol";

contract Oracle is Ownable {
    using SafeMath for uint256;

    // eth/usd price feed
    AggregatorV3Interface public ethUsdFeed;

    // mapping from token to token/eth price feed
    mapping(address => AggregatorV3Interface) public ethFeeds;

    // mapping from token to token/usd price feed
    mapping(address => AggregatorV3Interface) public usdFeeds;

    function getTokenPrice(address token) public view returns (uint256) {
        // check if token/usd feed exists
        AggregatorV3Interface feed = usdFeeds[token];
        if (address(feed) != address(0)) {

            // chainlink usd feeds use 8 decimal places, so convert to 18 decimal places
            return _latestPrice(feed).mul(1e10);
        }

        // otherwise try to use token/eth price and multiply by eth/usd price
        uint256 price1 = _latestPrice(ethFeeds[token]);
        uint256 price2 = _latestPrice(ethUsdFeed);

        // chainlink usd feeds use 8 decimal places, so convert to 18 decimal places
        return price1.mul(price2).div(1e8);
    }

    function _latestPrice(AggregatorV3Interface feed) internal view returns (uint256) {
        require(address(feed) != address(0), "Feed not added");
        (, int256 price, , , ) = feed.latestRoundData();
        require(price > 0, "Price is not > 0");
        return uint256(price);
    }

    function setEthUsdFeed(AggregatorV3Interface feed) external onlyOwner {
        ethUsdFeed = feed;
    }

    function setEthFeed(address token, AggregatorV3Interface feed) external onlyOwner {
        ethFeeds[token] = feed;
    }

    function setUsdFeed(address token, AggregatorV3Interface feed) external onlyOwner {
        usdFeeds[token] = feed;
    }
}
