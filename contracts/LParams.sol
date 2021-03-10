// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./ChainlinkFeedsRegistry.sol";
import "./LToken.sol";
import "../interfaces/AggregatorV3Interface.sol";

/**
 * @title Leveraged Token Pool
 * @notice A pool that lets users buy and sell leveraged tokens
 */
contract LParams is Ownable {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    enum Side {Long, Short}

    struct Params {
        bool added; // always set to true; used to check existence
        address underlyingToken;
        Side side;
        uint256 maxPoolShare; // expressed in basis points; 0 means no limit
        bool buyPaused;
        bool sellPaused;
        bool priceUpdatePaused;
        uint256 priceOffset;
        uint256 lastPrice;
        uint256 lastUpdated;
    }

    mapping(LToken => Params) public params;
    LToken[] public allLTokens;

    uint256 public tradingFee; // expressed in basis points
    uint256 public maxTvl; // 0 means no limit

    function numLTokens() external view returns (uint256) {
        return allLTokens.length;
    }

    function _addParams(LToken lToken, Params memory _params) internal {
        require(!params[lToken].added, "Already added");
        params[lToken] = _params;
        allLTokens.push(lToken);
    }

    function updateBuyPaused(LToken lToken, bool paused) external onlyOwner {
        require(params[lToken].added, "Not added");
        params[lToken].buyPaused = paused;
    }

    function updateSellPaused(LToken lToken, bool paused) external onlyOwner {
        require(params[lToken].added, "Not added");
        params[lToken].sellPaused = paused;
    }

    function updatePriceUpdatePaused(LToken lToken, bool paused) external onlyOwner {
        require(params[lToken].added, "Not added");
        params[lToken].priceUpdatePaused = paused;
    }

    function pauseTrading() external onlyOwner {
        for (uint256 i = 0; i < allLTokens.length; i = i.add(1)) {
            LToken lToken = allLTokens[i];
            params[lToken].buyPaused = true;
            params[lToken].sellPaused = true;
        }
    }

    function updateMaxPoolShare(LToken lToken, uint256 maxPoolShare) external onlyOwner {
        require(params[lToken].added, "Not added");
        require(maxPoolShare < 1e4, "Max pool share should be < 100%");
        params[lToken].maxPoolShare = maxPoolShare;
    }

    function updateMaxTvl(uint256 _maxTvl) external onlyOwner {
        maxTvl = _maxTvl;
    }

    function updateTradingFee(uint256 _tradingFee) external onlyOwner {
        require(_tradingFee < 1e4, "Trading fee should be < 100%");
        tradingFee = _tradingFee;
    }
}
