// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;

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

// TODO
// - test X/eth
// - test admin methods

// - add views
// - getLeveragedTokenCost(..., amount)
// - getLongLeveragedToken(token)

// - add docs
// - add events

// - check syntehtix oracle chekcs

contract LPool is Ownable, ReentrancyGuard {
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
        uint256 priceOffset;
        uint256 lastPrice;
        uint256 lastUpdated;
    }

    IERC20 baseToken;
    ChainlinkFeedsRegistry feedRegistry;
    LToken leveragedTokenImpl;

    mapping(LToken => Params) public params;

    LToken[] public ltokens;
    mapping(address => mapping(Side => LToken)) public leveragedTokensMap;

    uint256 public tradingFee; // expressed in basis points
    uint256 public maxTvl; // 0 means no limit

    uint256 public totalValue;
    uint256 public feesAccrued;
    bool public finalized;

    constructor(address _baseToken, address _feedRegistry) public {
        baseToken = IERC20(_baseToken);
        feedRegistry = ChainlinkFeedsRegistry(_feedRegistry);
        leveragedTokenImpl = new LToken();

        // initialize with dummy data so that no one else can
        leveragedTokenImpl.initialize(address(0), "", "");
    }

    function buy(
        LToken ltoken,
        uint256 quantity,
        address to
    ) external nonReentrant returns (uint256 cost) {
        Params storage _params = params[ltoken];
        require(_params.added, "Not added");
        require(!_params.buyPaused, "Paused");

        uint256 ltPrice = updatePrice(ltoken);

        // calculate number of shares
        cost = quote(ltoken, quantity).add(1);

        // add fees
        uint256 feeAmount = fee(cost);
        feesAccrued = feesAccrued.add(feeAmount);
        cost = cost.add(feeAmount);

        // update total value
        totalValue = totalValue.add(quantity.mul(ltPrice));

        // transfer in payment from sender
        baseToken.transferFrom(msg.sender, address(this), cost);

        // mint shares to recipient
        ltoken.mint(to, quantity);

        // check max pool share
        uint256 maxPoolShare = _params.maxPoolShare;
        if (maxPoolShare > 0) {
            uint256 ltokenValue = ltoken.totalSupply().mul(ltPrice);
            require(ltokenValue.mul(1e4) <= maxPoolShare.mul(totalValue), "Max pool share exceeded");
        }

        // check max tvl
        if (maxTvl > 0) {
            require(poolBalance() <= maxTvl, "Max TVL exceeded");
        }

        return cost;
    }

    function sell(
        LToken ltoken,
        uint256 quantity,
        address to
    ) external nonReentrant returns (uint256 cost) {
        Params storage _params = params[ltoken];
        require(_params.added, "Not added");
        require(!_params.sellPaused, "Paused");

        uint256 ltPrice = updatePrice(ltoken);

        // calculate number of shares
        cost = quote(ltoken, quantity);

        // subtract fees
        uint256 feeAmount = fee(cost);
        feesAccrued = feesAccrued.add(feeAmount);
        cost = cost.sub(feeAmount);

        // update total value
        totalValue = totalValue.sub(quantity.mul(ltPrice));

        // burn shares from sender
        ltoken.burn(msg.sender, quantity);

        // transfer amount out to recipient
        baseToken.transfer(to, cost);
    }

    function updatePrice(LToken ltoken) public returns (uint256 ltPrice) {
        Params storage _params = params[ltoken];
        require(_params.added, "Not added");

        uint256 underlyingPrice = feedRegistry.getPrice(_params.token);

        // returns 36dp
        uint256 square = underlyingPrice.mul(underlyingPrice);
        uint256 squareOrInv = _params.side == Side.Long ? square.mul(1e20) : uint256(1e52).div(square);
        require(squareOrInv > 0, "Price must be > 0");

        uint256 priceOffset = _params.priceOffset;
        if (priceOffset == 0) {
            priceOffset = _params.priceOffset = squareOrInv;
        }
        ltPrice = squareOrInv.mul(1e18).div(priceOffset);

        uint256 _totalSupply = ltoken.totalSupply();
        totalValue = totalValue.sub(_totalSupply.mul(_params.lastPrice)).add(_totalSupply.mul(ltPrice));
        _params.lastPrice = ltPrice;
        _params.lastUpdated = block.timestamp;
    }

    function addLToken(address token, Side side) external onlyOwner returns (address) {
        require(side == Side.Short || side == Side.Long, "Invalid side");
        require(address(leveragedTokensMap[token][side]) == address(0), "Already added");

        bytes32 salt = keccak256(abi.encodePacked(token, side));
        address instance = Clones.cloneDeterministic(address(leveragedTokenImpl), salt);
        LToken ltoken = LToken(instance);

        string memory name =
            string(abi.encodePacked("Charm 2X ", (side == Side.Long ? "Long " : "Short "), ERC20(token).name()));
        string memory symbol =
            string(abi.encodePacked("charm", ERC20(token).symbol(), (side == Side.Long ? "BULL" : "BEAR")));
        ltoken.initialize(address(this), name, symbol);

        params[ltoken] = Params({
            added: true,
            token: token,
            side: side,
            maxPoolShare: 0,
            buyPaused: false,
            sellPaused: false,
            priceOffset: 0,
            lastPrice: 0,
            lastUpdated: 0
        });
        ltokens.push(ltoken);
        leveragedTokensMap[token][side] = ltoken;

        updatePrice(ltoken);
        return instance;
    }

    function ltokensLength() external view returns (uint256) {
        return ltokens.length;
    }

    function quote(LToken ltoken, uint256 shares) public view returns (uint256 cost) {
        Params storage _params = params[ltoken];
        require(_params.added, "Not added");

        uint256 _totalValue = totalValue;
        return _totalValue > 0 ? shares.mul(_params.lastPrice).mul(poolBalance()).div(_totalValue) : shares;
    }

    function fee(uint256 cost) public view returns (uint256) {
        return cost.mul(tradingFee).div(1e4);
    }

    function buyQuote(LToken ltoken, uint256 shares) public view returns (uint256) {
        uint256 cost = quote(ltoken, shares).add(1);
        return cost.add(fee(cost));
    }

    function sellQuote(LToken ltoken, uint256 shares) public view returns (uint256) {
        uint256 cost = quote(ltoken, shares);
        return cost.sub(fee(cost));
    }

    function poolBalance() public view returns (uint256) {
        return baseToken.balanceOf(address(this)).sub(feesAccrued);
    }

    function setBuyPaused(LToken ltoken, bool paused) external onlyOwner {
        require(params[ltoken].added, "Not added");
        params[ltoken].buyPaused = paused;
    }

    function setSellPaused(LToken ltoken, bool paused) external onlyOwner {
        require(params[ltoken].added, "Not added");
        params[ltoken].sellPaused = paused;
    }

    function pauseAll() external onlyOwner {
        for (uint256 i = 0; i < ltokens.length; i = i.add(1)) {
            LToken ltoken = ltokens[i];
            params[ltoken].buyPaused = true;
            params[ltoken].sellPaused = true;
        }
    }

    function updateMaxPoolShare(LToken ltoken, uint256 maxPoolShare) external onlyOwner {
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
        baseToken.transfer(msg.sender, feesAccrued);
        feesAccrued = 0;
    }

    function finalize() external onlyOwner {
        finalized = true;
    }

    function emergencyWithdraw() external onlyOwner {
        require(!finalized, "Finalized");
        uint256 balance = baseToken.balanceOf(address(this));
        baseToken.transfer(msg.sender, balance);
    }
}
