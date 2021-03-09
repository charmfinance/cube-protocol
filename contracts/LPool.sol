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

/**
 * @title Leveraged Token Pool
 * @notice A pool that lets users buy and sell leveraged tokens
 */
contract LPool is Ownable, ReentrancyGuard {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    event Trade(
        address indexed sender,
        address indexed to,
        IERC20 baseToken,
        LToken lToken,
        bool isBuy,
        uint256 quantity,
        uint256 cost,
        uint256 feeAmount
    );
    event UpdatePrice(LToken lToken, uint256 price);
    event AddLToken(LToken lToken, address underlyingToken, Side side, string name, string symbol);

    enum Side {Long, Short}

    struct Params {
        bool added; // always set to true; used to check existence
        address underlyingToken;
        Side side;
        uint256 maxPoolShare; // expressed in basis points; 0 means no limit
        bool buyPaused;
        bool sellPaused;
        uint256 priceOffset;
        uint256 lastPrice;
        uint256 lastUpdated;
    }

    IERC20 baseToken;
    ChainlinkFeedsRegistry feedRegistry;
    LToken lTokenImpl;

    mapping(LToken => Params) public params;

    LToken[] public lTokens;
    mapping(address => mapping(Side => LToken)) public leveragedTokensMap;

    uint256 public tradingFee; // expressed in basis points
    uint256 public maxTvl; // 0 means no limit

    uint256 public totalValue;
    uint256 public feesAccrued;
    bool public finalized;

    /**
     * @param _baseToken The token held by this contract. Users buy and sell leveraged
     * tokens with `baseToken`
     * @param _feedRegistry The `ChainlinkFeedsRegistry` contract that stores
     * chainlink feed addresses
     */
    constructor(address _baseToken, address _feedRegistry) public {
        baseToken = IERC20(_baseToken);
        feedRegistry = ChainlinkFeedsRegistry(_feedRegistry);
        lTokenImpl = new LToken();

        // initialize with dummy data so that no one else can
        lTokenImpl.initialize(address(0), "", "");
    }

    /**
     * @notice Buy leveraged tokens
     * @param lToken The leveraged token to buy
     * @param quantity The quantity of leveraged tokens to buy
     * @param to The address that receives the leveraged tokens
     */
    function buy(
        LToken lToken,
        uint256 quantity,
        address to
    ) external nonReentrant returns (uint256 cost) {
        Params storage _params = params[lToken];
        require(_params.added, "Not added");
        require(!_params.buyPaused, "Paused");

        uint256 price = updatePrice(lToken);
        cost = quote(lToken, quantity).add(1);

        uint256 feeAmount = fee(cost);
        feesAccrued = feesAccrued.add(feeAmount);
        cost = cost.add(feeAmount);

        totalValue = totalValue.add(quantity.mul(price));
        baseToken.transferFrom(msg.sender, address(this), cost);
        lToken.mint(to, quantity);

        // `maxPoolShare` being 0 means no limit
        uint256 maxPoolShare = _params.maxPoolShare;
        if (maxPoolShare > 0) {
            uint256 lTokenValue = lToken.totalSupply().mul(price);
            require(lTokenValue.mul(1e4) <= maxPoolShare.mul(totalValue), "Max pool share exceeded");
        }

        // `maxTvl` being 0 means no limit
        if (maxTvl > 0) {
            require(poolBalance() <= maxTvl, "Max TVL exceeded");
        }

        emit Trade(msg.sender, to, baseToken, lToken, true, quantity, cost, feeAmount);
        return cost;
    }

    /**
     * @notice Sell leveraged tokens
     * @param lToken The leveraged token to sell
     * @param quantity The quantity of leveraged tokens to sell
     * @param to The address that receives the sale amount
     */
    function sell(
        LToken lToken,
        uint256 quantity,
        address to
    ) external nonReentrant returns (uint256 cost) {
        Params storage _params = params[lToken];
        require(_params.added, "Not added");
        require(!_params.sellPaused, "Paused");

        uint256 price = updatePrice(lToken);
        cost = quote(lToken, quantity);

        uint256 feeAmount = fee(cost);
        feesAccrued = feesAccrued.add(feeAmount);
        cost = cost.sub(feeAmount);

        totalValue = totalValue.sub(quantity.mul(price));
        lToken.burn(msg.sender, quantity);
        baseToken.transfer(to, cost);

        emit Trade(msg.sender, to, baseToken, lToken, false, quantity, cost, feeAmount);
    }

    /**
     * @notice Update the stored leveraged token price and total value. It is
     * automatically called when this leveraged token is bought or sold. However
     * if it has not been traded for a while, it should be called periodically
     * so that the total value does get too far out of sync
     * @param lToken The leveraged token whose price is updated
     */
    function updatePrice(LToken lToken) public returns (uint256 price) {
        Params storage _params = params[lToken];
        require(_params.added, "Not added");

        uint256 underlyingPrice = feedRegistry.getPrice(_params.underlyingToken);
        uint256 square = underlyingPrice.mul(underlyingPrice);

        // invert price for short tokens and convert to 36dp
        uint256 squareOrInv = _params.side == Side.Long ? square.mul(1e20) : uint256(1e52).div(square);
        require(squareOrInv > 0, "Price should be > 0");

        // set priceOffset the first time this method is called for this leveraged token
        uint256 priceOffset = _params.priceOffset;
        if (priceOffset == 0) {
            priceOffset = _params.priceOffset = squareOrInv;
        }

        // divide by the initial price to avoid extremely high or low prices
        // price decimals is now 18dp
        price = squareOrInv.mul(1e18).div(priceOffset);

        uint256 _totalSupply = lToken.totalSupply();
        totalValue = totalValue.sub(_totalSupply.mul(_params.lastPrice)).add(_totalSupply.mul(price));
        _params.lastPrice = price;
        _params.lastUpdated = block.timestamp;

        emit UpdatePrice(lToken, price);
    }

    /**
     * @notice Add a new leveraged token. Can only be called by owner
     * @param underlyingToken The ERC-20 whose price is used
     * @param side Long or short
     */
    function addLToken(address underlyingToken, Side side) external onlyOwner returns (address) {
        require(side == Side.Short || side == Side.Long, "Invalid side");
        require(address(leveragedTokensMap[underlyingToken][side]) == address(0), "Already added");

        bytes32 salt = keccak256(abi.encodePacked(underlyingToken, side));
        address instance = Clones.cloneDeterministic(address(lTokenImpl), salt);
        LToken lToken = LToken(instance);

        string memory name =
            string(
                abi.encodePacked("Charm 2X ", (side == Side.Long ? "Long " : "Short "), ERC20(underlyingToken).name())
            );
        string memory symbol =
            string(abi.encodePacked("charm", ERC20(underlyingToken).symbol(), (side == Side.Long ? "BULL" : "BEAR")));
        lToken.initialize(address(this), name, symbol);

        params[lToken] = Params({
            added: true,
            underlyingToken: underlyingToken,
            side: side,
            maxPoolShare: 0,
            buyPaused: false,
            sellPaused: false,
            priceOffset: 0,
            lastPrice: 0,
            lastUpdated: 0
        });
        lTokens.push(lToken);
        leveragedTokensMap[underlyingToken][side] = lToken;

        updatePrice(lToken);
        emit AddLToken(lToken, underlyingToken, side, name, symbol);
        return instance;
    }

    /**
     * @notice Amount received by selling leveraged tokens
     * @param lToken The leveraged token sold
     * @param quantity The quantity of leveraged tokens sold
     */
    function quote(LToken lToken, uint256 quantity) public view returns (uint256 cost) {
        Params storage _params = params[lToken];
        require(_params.added, "Not added");

        uint256 _totalValue = totalValue;
        return _totalValue > 0 ? quantity.mul(_params.lastPrice).mul(poolBalance()).div(_totalValue) : quantity;
    }

    /**
     * @notice Fee paid to buy or sell leveraged tokens
     * @param cost Amount of `baseToken` paid or received when buying or selling
     */
    function fee(uint256 cost) public view returns (uint256) {
        return cost.mul(tradingFee).div(1e4);
    }

    /**
     * @notice Cost to buy leveraged tokens
     * @param lToken Leveraged token bought
     * @param quantity Quantity of leveraged tokens bought
     */
    function buyQuote(LToken lToken, uint256 quantity) public view returns (uint256) {
        uint256 cost = quote(lToken, quantity).add(1);
        return cost.add(fee(cost));
    }

    /**
     * @notice Amount received by selling leveraged tokens
     * @param lToken Leveraged token sold
     * @param quantity Quantity of leveraged tokens sold
     */
    function sellQuote(LToken lToken, uint256 quantity) public view returns (uint256) {
        uint256 cost = quote(lToken, quantity);
        return cost.sub(fee(cost));
    }

    /**
     * @notice Balance of the pool owned by leveraged token holders
     */
    function poolBalance() public view returns (uint256) {
        return baseToken.balanceOf(address(this)).sub(feesAccrued);
    }

    /**
     * @notice Number of leveraged tokens in the pool
     */
    function numLTokens() external view returns (uint256) {
        return lTokens.length;
    }

    function updateBuyPaused(LToken lToken, bool paused) external onlyOwner {
        require(params[lToken].added, "Not added");
        params[lToken].buyPaused = paused;
    }

    function updateSellPaused(LToken lToken, bool paused) external onlyOwner {
        require(params[lToken].added, "Not added");
        params[lToken].sellPaused = paused;
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
