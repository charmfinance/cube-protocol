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

// - add views
// - getLeveragedTokenCost(..., amount)
// - getLongLeveragedToken(token)

// - add docs
// - add events

// - deposit/withdraw eth

contract LeveragedTokenPool is Ownable, ReentrancyGuard {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    enum Side {Long, Short}

    struct Params {
        bool added;
        string tokenSymbol;
        Side side;
        uint256 maxPoolShare; // in basis points, 0 means no limit
        bool depositPaused;
        bool withdrawPaused;
        uint256 lastSquarePrice;
    }

    IERC20 public baseToken;

    mapping(LeveragedToken => Params) public params;
    LeveragedToken[] public leveragedTokens;

    uint256 public depositFee; // in basis points
    uint256 public maxTvl; // 0 means no limit

    uint256 public totalValue;
    uint256 public accumulatedFees;
    bool public finalized;

    mapping(string => mapping(string => address)) public feeds;

    constructor(address _baseToken) {
        baseToken = IERC20(_baseToken);
    }

    function deposit(
        LeveragedToken ltoken,
        uint256 amountIn,
        uint256 minSharesOut,
        address to
    ) external nonReentrant returns (uint256 sharesOut) {
        require(params[ltoken].added, "Token not added");
        require(!params[ltoken].depositPaused, "Paused");

        // if amountIn is 0, it means deposit all
        if (amountIn == 0) {
            amountIn = baseToken.balanceOf(msg.sender);
        }

        // transfer amount in from sender
        uint256 balanceBefore = baseToken.balanceOf(address(this));
        baseToken.transferFrom(msg.sender, address(this), amountIn);
        uint256 balanceAfter = baseToken.balanceOf(address(this));
        require(balanceAfter.sub(balanceBefore) == amountIn, "Deflationary tokens not supported");

        // calculate fee
        uint256 fee = amountIn.mul(depositFee).div(1e4);
        accumulatedFees = accumulatedFees.add(fee);

        // calculate number of shares
        uint256 squarePrice = updateSquarePrice(ltoken);
        sharesOut = _calcSharesFromAmount(squarePrice, amountIn.sub(fee));
        require(sharesOut >= minSharesOut, "Max slippage exceeded");

        // mint shares to recipient and update total value
        ltoken.mint(to, sharesOut);
        totalValue = totalValue.add(sharesOut.mul(squarePrice));

        // check max pool share and tvl
        uint256 maxPoolShare = params[ltoken].maxPoolShare;
        if (maxPoolShare > 0) {
            uint256 ltokenValue = ltoken.totalSupply().mul(squarePrice);
            require(ltokenValue.mul(1e4) <= maxPoolShare.mul(totalValue), "Max pool share exceeded");
        }
        if (maxTvl > 0) {
            require(getBalance() <= maxTvl, "Max TVL exceeded");
        }
    }

    function withdraw(
        LeveragedToken ltoken,
        uint256 amountOut,
        uint256 maxSharesIn,
        address to
    ) external nonReentrant returns (uint256 sharesIn) {
        require(params[ltoken].added, "Token not added");
        require(!params[ltoken].withdrawPaused, "Paused");

        uint256 squarePrice = updateSquarePrice(ltoken);

        // if amountOut is 0, it means withdraw all
        if (amountOut == 0) {
            sharesIn = ltoken.balanceOf(msg.sender);
            amountOut = _calcAmountFromShares(squarePrice, sharesIn);
        } else {
            sharesIn = _calcSharesFromAmount(squarePrice, amountOut).add(1);
        }
        require(sharesIn <= maxSharesIn, "Max slippage exceeded");

        // burn shares from sender and update total value
        ltoken.burn(msg.sender, sharesIn);
        totalValue = totalValue.sub(sharesIn.mul(squarePrice));

        // transfer amount out to recipient
        baseToken.transfer(to, amountOut);
    }

    function _calcSharesFromAmount(uint256 squarePrice, uint256 amount) internal view returns (uint256) {
        uint256 balance = getBalance();
        if (balance == 0) {
            return amount;
        }
        return amount.mul(totalValue).div(squarePrice).div(balance);
    }

    function _calcAmountFromShares(uint256 squarePrice, uint256 shares) internal view returns (uint256) {
        return shares.mul(squarePrice).mul(getBalance()).div(totalValue);
    }

    function updateSquarePrice(LeveragedToken ltoken) public returns (uint256 squarePrice) {
        Params storage _params = params[ltoken];
        require(_params.added, "Token not added");

        squarePrice = getSquarePrice(ltoken);
        uint256 lastSquarePrice = _params.lastSquarePrice;

        if (squarePrice > lastSquarePrice) {
            uint256 increase = squarePrice.sub(lastSquarePrice);
            totalValue = totalValue.add(ltoken.totalSupply().mul(increase));
        } else if (squarePrice < lastSquarePrice) {
            uint256 decrease = lastSquarePrice.sub(squarePrice);
            totalValue = totalValue.sub(ltoken.totalSupply().mul(decrease));
        }
        _params.lastSquarePrice = squarePrice;
    }

    // needs to be called regularly
    function keep() external {
        for (uint256 i = 0; i < leveragedTokens.length; i = i.add(1)) {
            LeveragedToken ltoken = leveragedTokens[i];
            updateSquarePrice(ltoken);
        }
    }

    // TODO: check max possible prices
    function getSquarePrice(LeveragedToken ltoken) public view returns (uint256) {
        Params storage _params = params[ltoken];
        uint256 underlyingPrice = getUnderlyingPrice(_params.tokenSymbol);
        uint256 squarePrice = underlyingPrice.mul(underlyingPrice);
        return _params.side == Side.Short ? uint256(1e54).div(squarePrice) : squarePrice.div(1e18);
    }

    // TODO: check gas savings by caching feeds
    function getUnderlyingPrice(string memory symbol) public view returns (uint256) {
        address feed = feeds[symbol]["USD"];
        if (feed != address(0)) {
            return _latestPrice(feed).mul(1e10);
        }
        uint256 price1 = _latestPrice(feeds[symbol]["ETH"]);
        uint256 price2 = _latestPrice(feeds["ETH"]["USD"]);
        return price1.mul(price2).div(1e8);
    }

    function _latestPrice(address feed) internal view returns (uint256) {
        require(feed != address(0), "Feed not added");
        (, int256 price, , , ) = AggregatorV3Interface(feed).latestRoundData();
        require(price > 0, "Price is not > 0");
        return uint256(price);
    }

    function addLeveragedToken(address token, Side side) external onlyOwner returns (address) {
        require(side == Side.Short || side == Side.Long, "Invalid side");

        string memory tokenSymbol = ERC20(token).symbol();
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
        return address(ltoken);
    }

    function getBalance() public view returns (uint256) {
        return baseToken.balanceOf(address(this)).sub(accumulatedFees);
    }

    function numLeveragedTokens() external view returns (uint256) {
        return leveragedTokens.length;
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

    function registerFeed(
        string memory baseSymbol,
        string memory quoteSymbol,
        address feed
    ) external onlyOwner {
        feeds[baseSymbol][quoteSymbol] = feed;
    }

    function setDepositPaused(LeveragedToken ltoken, bool paused) external onlyOwner {
        require(params[ltoken].added, "Token not added");
        params[ltoken].depositPaused = paused;
    }

    function setWithdrawPaused(LeveragedToken ltoken, bool paused) external onlyOwner {
        require(params[ltoken].added, "Token not added");
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
        require(params[ltoken].added, "Token not added");
        require(maxPoolShare < 1e4, "Max pool share must be < 100%");
        params[ltoken].maxPoolShare = maxPoolShare;
    }

    function updateMaxTvl(uint256 _maxTvl) external onlyOwner {
        maxTvl = _maxTvl;
    }

    function updateDepositFee(uint256 _depositFee) external onlyOwner {
        require(_depositFee < 1e4, "Deposit fee must be < 100%");
        depositFee = _depositFee;
    }

    function collectFee() external onlyOwner {
        require(msg.sender.send(accumulatedFees));
        accumulatedFees = 0;
    }

    function finalize() external onlyOwner {
        finalized = true;
    }

    function emergencyWithdraw() external onlyOwner {
        require(!finalized, "Finalized");
        baseToken.transfer(owner(), baseToken.balanceOf(address(this)));
    }
}
