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
 * @notice  Stores Chainlink feed addresses and provides getPrice() method to
 *          get the current price of a given token in USD
 * @dev     If a feed in USD exists, just use that. Otherwise multiply ETH/USD
 *          price with the price in ETH. For the price of USD, just return 1.
 */
contract ChainlinkFeedsRegistry is Ownable {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    event AddFeed(bytes32 indexed currencyKey, string baseSymbol, string quoteSymbol, address feed);

    // stringToBytes32("ETH")
    bytes32 public constant ETH = 0x4554480000000000000000000000000000000000000000000000000000000000;

    // stringToBytes32("USD")
    bytes32 public constant USD = 0x5553440000000000000000000000000000000000000000000000000000000000;

    mapping(bytes32 => address) public usdFeeds;
    mapping(bytes32 => address) public ethFeeds;

    /**
     * @notice Get price in USD multiplied by 1e8. Returns 0 if no feed found.
     * @param currencyKey Token symbol converted to bytes32
     */
    function getPrice(bytes32 currencyKey) public view returns (uint256) {
        address usdFeed = usdFeeds[currencyKey];
        if (usdFeed != address(0)) {
            // USD feeds are already scaled by 1e8 so don't need to scale again
            return _latestPrice(usdFeed);
        }

        address ethFeed = ethFeeds[currencyKey];
        address ethUsdFeed = usdFeeds[ETH];
        if (ethFeed != address(0) && ethUsdFeed != address(0)) {
            uint256 price1 = _latestPrice(ethFeed);
            uint256 price2 = _latestPrice(ethUsdFeed);

            // USD feeds are scaled by 1e8 and ETH feeds by 1e18 so need to
            // divide by 1e18
            return price1.mul(price2).div(1e18);
        } else if (currencyKey == USD) {
            // For USD just return a price of 1
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
     * @notice Add `symbol`/USD Chainlink feed to registry. Use a value of 0x0
     * for `feed` to remove it from registry.
     */
    function addUsdFeed(string memory symbol, address feed) external onlyOwner {
        require(_latestPrice(feed) > 0, "Price should be > 0");
        bytes32 currencyKey = stringToBytes32(symbol);
        usdFeeds[currencyKey] = feed;
        emit AddFeed(currencyKey, symbol, "USD", feed);
    }

    /**
     * @notice Add `symbol`/ETH Chainlink feed to registry. Use a value of 0x0
     * for `feed` to remove it from registry.
     */
    function addEthFeed(string memory symbol, address feed) external onlyOwner {
        require(_latestPrice(feed) > 0, "Price should be > 0");
        bytes32 currencyKey = stringToBytes32(symbol);
        ethFeeds[currencyKey] = feed;
        emit AddFeed(currencyKey, symbol, "ETH", feed);
    }

    function getPriceFromSymbol(string memory symbol) external view returns (uint256) {
        return getPrice(stringToBytes32(symbol));
    }

    function stringToBytes32(string memory s) public pure returns (bytes32 result) {
        bytes memory b = bytes(s);
        if (b.length == 0) {
            return 0x0;
        }
        assembly {
            result := mload(add(s, 32))
        }
    }
}
