// SPDX-License-Identifier: Unlicense

// Adapted from https://github.com/yearn/ycredit.finance/blob/master/contracts/ChainLinkFeedsRegistry.sol

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../interfaces/AggregatorV3Interface.sol";

/**
 * @title Chainlink Feeds Registry
 * @notice Get price in usd from an ERC20 token address
 * @dev Contains a registry of chainlink feeds. If a token/usd feed exists, just use that. Otherwise try to get prices from token/eth and eth/usd feeds.
 */
contract ChainlinkFeedsRegistry is Ownable {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    mapping(string => address) public usdFeeds;
    mapping(string => address) public ethFeeds;

    /**
     * @notice Get price in usd multiplied by 1e8
     * @param token ERC20 token whose price we want
     */
    function getPrice(string memory token) external view returns (uint256) {
        if (usdFeeds[token] != address(0)) {
            return _latestPrice(usdFeeds[token]);
        } else if (ethFeeds[token] != address(0) && usdFeeds["ETH"] != address(0)) {
            uint256 price1 = _latestPrice(ethFeeds[token]);
            uint256 price2 = _latestPrice(usdFeeds["ETH"]);

            // chainlink usd feeds are multiplied by 1e8 and eth feeds by 1e18 so need to divide by 1e18
            return price1.mul(price2).div(1e18);
        }
    }

    function _latestPrice(address feed) internal view returns (uint256) {
        if (feed == address(0)) {
            return 0;
        }
        (, int256 price, , , ) = AggregatorV3Interface(feed).latestRoundData();
        return uint256(price);
    }

    /**
     * @notice Add token/usd chainlink feed to registry
     * @param token ERC20 token for which feed is being added
     */
    function addUsdFeed(string memory token, address feed) external onlyOwner {
        require(_latestPrice(feed) > 0, "Price should be > 0");
        usdFeeds[token] = feed;
    }

    /**
     * @notice Add token/eth chainlink feed to registry
     * @param token ERC20 token for which feed is being added
     */
    function addEthFeed(string memory token, address feed) external onlyOwner {
        require(_latestPrice(feed) > 0, "Price should be > 0");
        ethFeeds[token] = feed;
    }
}
