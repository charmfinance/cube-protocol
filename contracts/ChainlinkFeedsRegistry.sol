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
 * @title   Chainlink Feeds Registry
 * @notice  Get price in usd from an ERC20 token address
 * @dev     Contains a registry of chainlink feeds. If a TOKEN/USD feed exists,
 *          just use that. Otherwise multiply prices from TOKEN/ETH and ETH/USD
 *          feeds. For USD, just return 1.
 */
contract ChainlinkFeedsRegistry is Ownable {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    event AddFeed(bytes32 indexed currencyKey, bool isEth, address feed);

    // stringToBytes32("ETH")
    bytes32 public constant ETH = 0x4554480000000000000000000000000000000000000000000000000000000000;

    // stringToBytes32("USD")
    bytes32 public constant USD = 0x5553440000000000000000000000000000000000000000000000000000000000;

    mapping(bytes32 => address) public usdFeeds;
    mapping(bytes32 => address) public ethFeeds;

    /**
     * @notice Get price in usd multiplied by 1e8
     * @param currencyKey ERC20 token whose price we want
     */
    function getPrice(bytes32 currencyKey) public view returns (uint256) {
        address tokenUsd = usdFeeds[currencyKey];
        if (tokenUsd != address(0)) {
            // USD feeds are already scaled by 1e8 so can just return price
            return _latestPrice(usdFeeds[currencyKey]);
        }

        address tokenEth = ethFeeds[currencyKey];
        address ethUsd = usdFeeds[ETH];
        if (tokenEth != address(0) && ethUsd != address(0)) {
            uint256 price1 = _latestPrice(tokenEth);
            uint256 price2 = _latestPrice(ethUsd);

            // USD feeds are scale by 1e8 and ETH feeds by 1e18 so need to
            // divide by 1e18
            return price1.mul(price2).div(1e18);
        } else if (currencyKey == USD) {
            return 1e8;
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
     * @notice Add TOKEN/USD chainlink feed to registry
     * @param symbol ERC20 token symbol for which feed is being added
     */
    function addUsdFeed(string memory symbol, address feed) external onlyOwner {
        require(_latestPrice(feed) > 0, "Price should be > 0");
        bytes32 currencyKey = stringToBytes32(symbol);
        usdFeeds[currencyKey] = feed;
        emit AddFeed(currencyKey, false, feed);
    }

    /**
     * @notice Add TOKEN/ETH chainlink feed to registry
     * @param symbol ERC20 token symbol for which feed is being added
     */
    function addEthFeed(string memory symbol, address feed) external onlyOwner {
        require(_latestPrice(feed) > 0, "Price should be > 0");
        bytes32 currencyKey = stringToBytes32(symbol);
        ethFeeds[currencyKey] = feed;
        emit AddFeed(currencyKey, true, feed);
    }

    function getPriceFromSymbol(string memory symbol) external view returns (uint256) {
        return getPrice(stringToBytes32(symbol));
    }

    function stringToBytes32(string memory source) public pure returns (bytes32 result) {
        bytes memory b = bytes(source);
        if (b.length == 0) {
            return 0x0;
        }

        assembly {
            result := mload(add(source, 32))
        }
    }
}
