// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./LeveragedToken.sol";
import "../interfaces/AggregatorV3Interface.sol";

// TODO
// - clone lt

// - use token address for feed registry

// - add views
// - getLeveragedTokenCost(..., amount)
// - getLongLeveragedToken(token)

// - add docs
// - add events

// - deposit/withdraw eth

// - check syntehtix oracle chekcs

// - check time since last keep

contract LeveragedTokenPool is Ownable, ReentrancyGuard {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    enum Side {Long, Short}

    struct Params {
        bool added;
        string tokenSymbol;
        Side side;
        uint256 maxPoolShare; // expressed in basis points, 0 means no limit
        bool depositPaused;
        bool withdrawPaused;
        uint256 lastSquarePrice;
    }

    mapping(LeveragedToken => Params) public params;
    LeveragedToken[] public leveragedTokens;

    uint256 public oneMinusFee; // expressed in basis points
    uint256 public maxTvl; // 0 means no limit

    uint256 public totalValue;
    uint256 public poolBalance;
    bool public finalized;

    mapping(string => mapping(string => address)) public feeds;

    constructor() {
        // set fee to 0
        oneMinusFee = 1e4;
    }

    function buy(
        LeveragedToken ltoken,
        uint256 minSharesOut,
        address to
    ) external payable nonReentrant returns (uint256 sharesOut) {
        Params storage _params = params[ltoken];
        require(_params.added, "Not added");
        require(!_params.depositPaused, "Paused");

        uint256 squarePrice = updateSquarePrice(ltoken);

        // calculate number of shares
        uint256 amountIn = _subtractFee(msg.value);
        require(amountIn > 0, "Amount in should be > 0");

        sharesOut = _divPrice(squarePrice, amountIn);
        require(sharesOut >= minSharesOut, "Max slippage exceeded");

        // update base balance
        uint256 _poolBalance = poolBalance.add(amountIn);
        poolBalance = _poolBalance;

        // mint shares to recipient
        ltoken.mint(to, sharesOut);
        totalValue = totalValue.add(sharesOut.mul(squarePrice));

        // check max pool share
        uint256 maxPoolShare = _params.maxPoolShare;
        if (maxPoolShare > 0) {
            uint256 ltokenValue = ltoken.totalSupply().mul(squarePrice);
            require(ltokenValue.mul(1e4) <= maxPoolShare.mul(totalValue), "Max pool share exceeded");
        }

        // check max tvl
        if (maxTvl > 0) {
            require(_poolBalance <= maxTvl, "Max TVL exceeded");
        }
    }

    function sell(
        LeveragedToken ltoken,
        uint256 sharesIn,
        uint256 minAmountOut,
        address payable to
    ) external nonReentrant returns (uint256 amountOut) {
        Params storage _params = params[ltoken];
        require(_params.added, "Not added");
        require(!_params.withdrawPaused, "Paused");
        require(sharesIn > 0, "Shares in should be > 0");

        uint256 squarePrice = updateSquarePrice(ltoken);

        // calculate number of shares
        amountOut = _mulPrice(squarePrice, sharesIn);
        require(amountOut >= minAmountOut, "Max slippage exceeded");

        // burn shares from sender
        ltoken.burn(msg.sender, sharesIn);
        totalValue = totalValue.sub(sharesIn.mul(squarePrice));

        // update base balance
        poolBalance = poolBalance.sub(amountOut);

        // transfer amount out to recipient
        amountOut = _subtractFee(amountOut);
        require(to.send(amountOut), "Transfer failed");
    }

    function updateSquarePrice(LeveragedToken ltoken) public returns (uint256 squarePrice) {
        Params storage _params = params[ltoken];
        require(_params.added, "Not added");

        squarePrice = getSquarePrice(ltoken);
        require(squarePrice > 0, "Square price should be > 0");

        uint256 lastSquarePrice = _params.lastSquarePrice;
        uint256 _totalSupply = ltoken.totalSupply();
        totalValue = totalValue.sub(_totalSupply.mul(lastSquarePrice)).add(_totalSupply.mul(squarePrice));
        _params.lastSquarePrice = squarePrice;
    }

    // needs to be called regularly
    function updateAllSquarePrices() external {
        for (uint256 i = 0; i < leveragedTokens.length; i = i.add(1)) {
            LeveragedToken ltoken = leveragedTokens[i];
            updateSquarePrice(ltoken);
        }
    }

    // if underlying price > around 3e29, this can overflow
    function getSquarePrice(LeveragedToken ltoken) public view returns (uint256) {
        Params storage _params = params[ltoken];
        uint256 underlyingPrice = getUnderlyingPrice(_params.tokenSymbol);
        uint256 squarePrice = underlyingPrice.mul(underlyingPrice);
        return _params.side == Side.Short ? uint256(1e54).div(squarePrice) : squarePrice.div(1e18);
    }

    function getUnderlyingPrice(string memory symbol) public view returns (uint256) {
        address feed = feeds[symbol]["USD"];
        if (feed != address(0)) {
            return _latestPrice(feed).mul(1e10);
        }
        uint256 tokenEthPrice = _latestPrice(feeds[symbol]["ETH"]);
        uint256 ethUsdPrice = _latestPrice(feeds["ETH"]["USD"]);
        return tokenEthPrice.mul(ethUsdPrice).div(1e8);
    }

    function _latestPrice(address feed) internal view returns (uint256) {
        require(feed != address(0), "Feed not added");
        (, int256 price, , , ) = AggregatorV3Interface(feed).latestRoundData();
        require(price > 0, "Price should be > 0");
        return uint256(price);
    }

    function addLeveragedToken(address token, Side side) external onlyOwner returns (address) {
        require(side == Side.Short || side == Side.Long, "Invalid side");

        string memory tokenSymbol = ERC20(token).symbol();
        require(getUnderlyingPrice(tokenSymbol) < 1e26, "Price is too high. Might overflow later");

        string memory name =
            string(abi.encodePacked("Charm 2X ", (side == Side.Long ? "Long " : "Short "), ERC20(token).name()));
        string memory symbol = string(abi.encodePacked("charm", tokenSymbol, (side == Side.Long ? "BULL" : "BEAR")));
        LeveragedToken ltoken = new LeveragedToken(address(this), name, symbol);

        params[ltoken] = Params({
            added: true,
            tokenSymbol: tokenSymbol,
            side: side,
            maxPoolShare: 0,
            depositPaused: false,
            withdrawPaused: false,
            lastSquarePrice: 0
        });
        leveragedTokens.push(ltoken);
        updateSquarePrice(ltoken);
        return address(ltoken);
    }

    function numLeveragedTokens() external view returns (uint256) {
        return leveragedTokens.length;
    }

    function _subtractFee(uint256 amount) internal view returns (uint256) {
        return amount.mul(oneMinusFee).div(1e4);
    }

    function getLeveragedTokens() external view returns (LeveragedToken[] memory ltokens) {
        uint256 n = leveragedTokens.length;
        ltokens = new LeveragedToken[](n);
        for (uint256 i = 0; i < n; i++) {
            ltokens[i] = leveragedTokens[i];
        }
    }

    // move belwo to periphery
    // function getLeveragedTokenPrice(address token, Side side) external view returns (uint256) {
    //     uint256 price = getSquarePrice(ltoken.token(), ltoken.side());
    //     return price.div(totalValue);
    // }

    // function getLeveragedTokenPrices() external view returns (uint256[] prices) {
    //     uint256 n = leveragedTokens.length;
    //     prices = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         LeveragedToken ltoken = leveragedTokens[i];
    //         prices[i] = getLeveragedTokenPrice(ltoken.token(), ltoken.side());
    //     }
    // }

    // function getLeveragedTokenValues() public view returns (uint256 values) {
    //     uint256 n = leveragedTokens.length;
    //     values = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         LeveragedToken ltoken = leveragedTokens[i];
    //         values[i] = getLeveragedTokenPrices(ltoken).mul(ltoken.totalSupply());
    //     }
    // }

    // function getAccountValues(LeveragedToken ltoken, address account) external view returns (uint256 values) {
    //     uint256 n = leveragedTokens.length;
    //     values = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         values[i] = getLeveragedTokenPrices(ltoken).mul(ltoken.balanceOf(account));
    //     }
    // }

    // TODO: splti into 2 methods
    // function getMaxDepositAmounts() external view returns (uint256[] amounts) {
    //     uint256 n = leveragedTokens.length;
    //     amounts = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         uint256 maxAmount1 = maxTvl.sub(getBalance());
    //         uint256 maxAmount2 = maxPoolShare.mul(totalValue).sub(getLeveragedTokenValue(ltoken));
    //         amounts[i] = Math.min(maxAmount1, maxAmount2);
    //     }
    // }

    function getSharesFromAmount(LeveragedToken ltoken, uint256 amount) external view returns (uint256) {
        Params storage _params = params[ltoken];
        require(_params.added, "Not added");
        uint256 squarePrice = _params.lastSquarePrice;

        amount = _subtractFee(amount);
        return _divPrice(squarePrice, amount);
    }

    function getAmountFromShares(LeveragedToken ltoken, uint256 shares) external view returns (uint256) {
        Params storage _params = params[ltoken];
        require(_params.added, "Not added");
        uint256 squarePrice = _params.lastSquarePrice;

        uint256 amount =  _mulPrice(squarePrice, shares);
        return _subtractFee(amount);
    }

    function getFee() external view returns (uint256) {
        return uint256(1e4).sub(oneMinusFee);
    }

    function _divPrice(uint256 squarePrice, uint256 amount) internal view returns (uint256) {
        uint256 _poolBalance = poolBalance;
        return _poolBalance > 0 ? amount.mul(totalValue).div(squarePrice).div(_poolBalance) : amount;
    }

    function _mulPrice(uint256 squarePrice, uint256 shares) internal view returns (uint256) {
        uint256 _totalValue = totalValue;
        return _totalValue > 0 ? shares.mul(squarePrice).mul(poolBalance).div(_totalValue) : 0;
    }

    function registerFeed(
        string memory baseSymbol,
        string memory quoteSymbol,
        address feed
    ) external onlyOwner {
        require(bytes(baseSymbol).length > 0, "Base symbol should not be empty");
        require(bytes(quoteSymbol).length > 0, "Quote symbol should not be empty");
        require(_latestPrice(feed) > 0, "Price should be > 0");
        feeds[baseSymbol][quoteSymbol] = feed;
    }

    function setDepositPaused(LeveragedToken ltoken, bool paused) external onlyOwner {
        require(params[ltoken].added, "Not added");
        params[ltoken].depositPaused = paused;
    }

    function setWithdrawPaused(LeveragedToken ltoken, bool paused) external onlyOwner {
        require(params[ltoken].added, "Not added");
        params[ltoken].withdrawPaused = paused;
    }

    function pauseAll() external onlyOwner {
        for (uint256 i = 0; i < leveragedTokens.length; i = i.add(1)) {
            LeveragedToken ltoken = leveragedTokens[i];
            params[ltoken].depositPaused = true;
            params[ltoken].withdrawPaused = true;
        }
    }

    function updateMaxPoolShare(LeveragedToken ltoken, uint256 maxPoolShare) external onlyOwner {
        require(params[ltoken].added, "Not added");
        require(maxPoolShare < 1e4, "Max pool share should be < 100%");
        params[ltoken].maxPoolShare = maxPoolShare;
    }

    function updateMaxTvl(uint256 _maxTvl) external onlyOwner {
        maxTvl = _maxTvl;
    }

    function updateFee(uint256 _fee) external onlyOwner {
        require(_fee < 1e4, "Deposit fee should be < 100%");
        oneMinusFee = uint(1e4).sub(_fee);
    }

    function collectFee() external onlyOwner {
        uint256 fee = address(this).balance.sub(poolBalance);
        require(msg.sender.send(fee), "Transfer failed");
    }

    function finalize() external onlyOwner {
        finalized = true;
    }

    function emergencyWithdraw() external onlyOwner {
        require(!finalized, "Finalized");

        uint256 balance = address(this).balance;
        require(msg.sender.send(balance), "Transfer failed");
    }
}
