// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../interfaces/AggregatorV3Interface.sol";

contract ChainlinkFeedsRegistry is Ownable {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public WETH = address(0);

    address public ethUsdFeed;
    mapping(address => address) public usdFeeds;
    mapping(address => address) public ethFeeds;

    function getPrice(address token) external view returns (uint256) {
        if (usdFeeds[token] != address(0)) {
            return _latestPrice(usdFeeds[token]);
        } else if (ethFeeds[token] != address(0)) {
            uint256 price1 = _latestPrice(ethFeeds[token]);
            uint256 price2 = _latestPrice(ethUsdFeed);
            return price1.mul(price2).div(1e18);
        }
    }

    function _latestPrice(address feed) internal view returns (uint256) {
        require(feed != address(0), "Feed not added");
        (, int256 price, , , ) = AggregatorV3Interface(feed).latestRoundData();
        require(price > 0, "Price should be > 0");
        return uint256(price);
    }

    function setEthUsdFeed(address token, address feed) external onlyOwner {
        // checks price is > 0
        _latestPrice(feed);
        ethUsdFeed = feed;
    }

    function addUsdFeed(address token, address feed) external onlyOwner {
        // checks price is > 0
        _latestPrice(feed);
        usdFeeds[token] = feed;
    }

    function addEthFeed(address token, address feed) external onlyOwner {
        // checks price is > 0
        _latestPrice(feed);
        ethFeeds[token] = feed;
    }
}
