// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./ChainlinkFeedsRegistry.sol";
import "./LeveragedToken.sol";
import "../interfaces/AggregatorV3Interface.sol";

// TODO
// - clone lt

// - test X/eth

// - max total value overflow

// - add views
// - getLeveragedTokenCost(..., amount)
// - getLongLeveragedToken(token)

// - add docs
// - add events

// - check syntehtix oracle chekcs

contract LeveragedTokenPool is Ownable, ReentrancyGuard {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    enum Side {Long, Short}

    struct Params {
        bool added;
        address token;
        Side side;
        uint256 maxPoolShare; // expressed in basis points, 0 means no limit
        bool buyPaused;
        bool sellPaused;
        uint256 lastSquarePrice;
    }

    ChainlinkFeedsRegistry feedRegistry;
    IERC20 baseToken;

    mapping(LeveragedToken => Params) public params;

    LeveragedToken[] public leveragedTokens;
    mapping(address => mapping(Side => LeveragedToken)) public leveragedTokensMap;

    uint256 public tradingFee; // expressed in basis points
    uint256 public maxTvl; // 0 means no limit

    uint256 public totalValue;
    uint256 public feesAccrued;
    bool public finalized;

    constructor(address _feedRegistry, address _baseToken) {
        feedRegistry = ChainlinkFeedsRegistry(_feedRegistry);
        baseToken = IERC20(_baseToken);
    }

    function buy(
        LeveragedToken ltoken,
        uint256 quantity,
        address to
    ) external nonReentrant returns (uint256 cost) {
        Params storage _params = params[ltoken];
        require(_params.added, "Not added");
        require(!_params.buyPaused, "Paused");

        uint256 squarePrice = updateSquarePrice(ltoken);

        // calculate number of shares
        cost = quote(ltoken, quantity);
        require(cost > 0, "Cost should be > 0");

        // add fees
        uint256 feeAmount = fee(cost);
        feesAccrued = feesAccrued.add(feeAmount);
        cost = cost.add(feeAmount);

        // transfer in payment from sender
        baseToken.transferFrom(msg.sender, address(this), cost);
        
        // mint shares to recipient
        ltoken.mint(to, quantity);

        // update total value
        totalValue = totalValue.add(quantity.mul(squarePrice));

        // check max pool share
        uint256 maxPoolShare = _params.maxPoolShare;
        if (maxPoolShare > 0) {
            uint256 ltokenValue = ltoken.totalSupply().mul(squarePrice);
            require(ltokenValue.mul(1e4) <= maxPoolShare.mul(totalValue), "Max pool share exceeded");
        }

        // check max tvl
        if (maxTvl > 0) {
            require(poolBalance() <= maxTvl, "Max TVL exceeded");
        }

        return cost;
    }

    function sell(
        LeveragedToken ltoken,
        uint256 quantity,
        address to
    ) external nonReentrant returns (uint256 cost) {
        Params storage _params = params[ltoken];
        require(_params.added, "Not added");
        require(!_params.sellPaused, "Paused");
        require(quantity > 0, "Quantity should be > 0");

        uint256 squarePrice = updateSquarePrice(ltoken);

        // calculate number of shares
        cost = quote(ltoken, quantity);

        // burn shares from sender
        ltoken.burn(msg.sender, quantity);

        // update total value
        totalValue = totalValue.sub(quantity.mul(squarePrice));

        // subtract fees
        uint256 feeAmount = fee(cost);
        feesAccrued = feesAccrued.add(feeAmount);
        cost = cost.sub(feeAmount);

        // transfer amount out to recipient
        baseToken.transfer(to, cost);
    }

    function updateSquarePrice(LeveragedToken ltoken) public returns (uint256 squarePrice) {
        Params storage _params = params[ltoken];
        require(_params.added, "Not added");

        squarePrice = getSquarePrice(_params.token, _params.side);
        uint256 lastSquarePrice = _params.lastSquarePrice;
        uint256 _totalSupply = ltoken.totalSupply();
        totalValue = totalValue.sub(_totalSupply.mul(lastSquarePrice)).add(_totalSupply.mul(squarePrice));
        _params.lastSquarePrice = squarePrice;
    }

    // needs to be called regularly
    function updateAllSquarePrices() external {
        uint256 _totalValue;
        for (uint256 i = 0; i < leveragedTokens.length; i = i.add(1)) {
            LeveragedToken ltoken = leveragedTokens[i];
            Params storage _params = params[ltoken];

            uint256 squarePrice = getSquarePrice(_params.token, _params.side);
            _totalValue = _totalValue.add(ltoken.totalSupply().mul(squarePrice));
            _params.lastSquarePrice = squarePrice;
        }

        // save gas by only updating totalValue at the end
        totalValue = _totalValue;
    }

    // returns 24dp
    function getSquarePrice(address token, Side side) public view returns (uint256 squarePrice) {
        uint256 price = feedRegistry.getPrice(token);
        if (side == Side.Long) {
            squarePrice = price.mul(price).mul(1e8);
        } else {
            squarePrice = uint256(1e40).div(price).div(price);
        }
        require(squarePrice > 0, "Square price should be > 0");
    }

    function addLeveragedToken(address token, Side side) external onlyOwner returns (address) {
        require(side == Side.Short || side == Side.Long, "Invalid side");

        require(feedRegistry.getPrice(token) > 0, "Price must be > 0");
        require(feedRegistry.getPrice(token) < 1e26, "Price is too high. Might overflow later");

        string memory tokenSymbol = ERC20(token).symbol();
        string memory name =
            string(abi.encodePacked("Charm 2X ", (side == Side.Long ? "Long " : "Short "), ERC20(token).name()));
        string memory symbol = string(abi.encodePacked("charm", tokenSymbol, (side == Side.Long ? "BULL" : "BEAR")));
        LeveragedToken ltoken = new LeveragedToken(address(this), name, symbol);

        params[ltoken] = Params({
            added: true,
            token: token,
            side: side,
            maxPoolShare: 0,
            buyPaused: false,
            sellPaused: false,
            lastSquarePrice: 0
        });
        leveragedTokens.push(ltoken);
        leveragedTokensMap[token][side] = ltoken;

        updateSquarePrice(ltoken);
        return address(ltoken);
    }

    function numLeveragedTokens() external view returns (uint256) {
        return leveragedTokens.length;
    }

    function quote(LeveragedToken ltoken, uint256 shares) public view returns (uint256 cost) {
        Params storage _params = params[ltoken];
        require(_params.added, "Not added");
        uint256 squarePrice = _params.lastSquarePrice;
        uint256 _totalValue = totalValue;
        return _totalValue > 0 ? shares.mul(squarePrice).mul(poolBalance()).div(_totalValue) : shares;
    }

    function fee(uint256 cost) public view returns (uint256) {
        return cost.mul(tradingFee).div(1e4);
    }

    function buyQuote(LeveragedToken ltoken, uint256 shares) public view returns (uint256) {
        uint256 cost = quote(ltoken, shares);
        return cost.add(fee(cost));
    }

    function sellQuote(LeveragedToken ltoken, uint256 shares) public view returns (uint256) {
        uint256 cost = quote(ltoken, shares);
        return cost.sub(fee(cost));
    }

    function poolBalance() public view returns (uint256) {
        return baseToken.balanceOf(address(this)).sub(feesAccrued);
    }

    function setDepositPaused(LeveragedToken ltoken, bool paused) external onlyOwner {
        require(params[ltoken].added, "Not added");
        params[ltoken].buyPaused = paused;
    }

    function setWithdrawPaused(LeveragedToken ltoken, bool paused) external onlyOwner {
        require(params[ltoken].added, "Not added");
        params[ltoken].sellPaused = paused;
    }

    function pauseAll() external onlyOwner {
        for (uint256 i = 0; i < leveragedTokens.length; i = i.add(1)) {
            LeveragedToken ltoken = leveragedTokens[i];
            params[ltoken].buyPaused = true;
            params[ltoken].sellPaused = true;
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

    function updateTradingFee(uint256 _tradingFee) external onlyOwner {
        require(_tradingFee < 1e4, "Trading fee should be < 100%");
        tradingFee = _tradingFee;
    }

    function collectFee() external onlyOwner {
        require(msg.sender.send(feesAccrued), "Transfer failed");
        feesAccrued = 0;
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
