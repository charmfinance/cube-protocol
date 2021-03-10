// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/AggregatorV3Interface.sol";
import "./ChainlinkFeedsRegistry.sol";
import "./LParams.sol";
import "./LToken.sol";

// TODO
// - test X/eth
// - test admin methods

/**
 * @title Leveraged Token Pool
 * @notice A pool that lets users buy and sell leveraged tokens
 */
contract LPool is Ownable, ReentrancyGuard, LParams {
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

    IERC20 baseToken;
    ChainlinkFeedsRegistry feedRegistry;
    LToken lTokenImpl;

    mapping(address => mapping(Side => LToken)) public leveragedTokensMap;

    uint256 public totalValue;
    uint256 public feesAccrued;
    bool public finalized;

    /**
     * @param _baseToken The token held by this contract. Users buy and sell leveraged
     * tokens with `baseToken`
     * @param _feedRegistry The `ChainlinkFeedsRegistry` contract that stores
     * chainlink feed addresses
     */
    constructor(address _baseToken, address _feedRegistry) {
        baseToken = IERC20(_baseToken);
        feedRegistry = ChainlinkFeedsRegistry(_feedRegistry);
        lTokenImpl = new LToken();

        // initialize with dummy data so that it can't be initialized again
        lTokenImpl.initialize(address(0), "", "");
    }

    /**
     * @notice Buy leveraged tokens
     * @param lToken The leveraged token to buy
     * @param quantity The quantity of leveraged tokens to buy
     * @param maxCost Revert if more than this amount is paid
     * @param to The address that receives the leveraged tokens
     * @return cost The amount of base tokens paid
     */
    function buy(
        LToken lToken,
        uint256 quantity,
        uint256 maxCost,
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
        require(cost <= maxCost, "Max slippage exceeded");

        totalValue = totalValue.add(quantity.mul(price));
        _safeTransferFromSenderToThis(cost);
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
     * @param minCost Revert if less than this amount is returned
     * @param to The address that receives the sale amount
     * @return cost The amount of base tokens returned
     */
    function sell(
        LToken lToken,
        uint256 quantity,
        uint256 minCost,
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
        require(cost >= minCost, "Max slippage exceeded");

        totalValue = totalValue.sub(quantity.mul(price));
        lToken.burn(msg.sender, quantity);
        baseToken.safeTransfer(to, cost);

        emit Trade(msg.sender, to, baseToken, lToken, false, quantity, cost, feeAmount);
    }

    /**
     * @notice Update the stored leveraged token price and total value. It is
     * automatically called when this leveraged token is bought or sold. However
     * if it has not been traded for a while, it should be called periodically
     * so that the total value does get too far out of sync
     * @param lToken Leveraged token whose price is updated
     * @return price Updated unnormalized leveraged token price
     */
    function updatePrice(LToken lToken) public returns (uint256 price) {
        Params storage _params = params[lToken];
        require(_params.added, "Not added");

        if (_params.priceUpdatePaused) {
            return _params.lastPrice;
        }

        uint256 underlyingPrice = feedRegistry.getPrice(_params.underlyingToken);
        uint256 square = underlyingPrice.mul(underlyingPrice);

        // invert price for short tokens and convert to 54dp
        uint256 squareOrInv = _params.side == Side.Long ? square.mul(1e38) : uint256(1e70).div(square);
        require(squareOrInv > 0, "Price should be > 0");

        // set priceOffset the first time this method is called for this leveraged token
        uint256 priceOffset = _params.priceOffset;
        if (priceOffset == 0) {
            priceOffset = _params.priceOffset = squareOrInv.div(1e18);
        }

        // divide by the initial price to avoid extremely high or low prices
        // price decimals is now 18dp
        price = squareOrInv.div(priceOffset);

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
     * @return address Address of leveraged token that was added
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

        _addParams(
            lToken,
            Params({
                added: true,
                underlyingToken: underlyingToken,
                side: side,
                maxPoolShare: 0,
                buyPaused: false,
                sellPaused: false,
                priceUpdatePaused: false,
                priceOffset: 0,
                lastPrice: 0,
                lastUpdated: 0
            })
        );
        leveragedTokensMap[underlyingToken][side] = lToken;

        updatePrice(lToken);
        emit AddLToken(lToken, underlyingToken, side, name, symbol);
        return instance;
    }

    /**
     * @notice Amount received by selling leveraged tokens
     * @param lToken The leveraged token sold
     * @param quantity Quantity of leveraged tokens sold
     */
    function quote(LToken lToken, uint256 quantity) public view returns (uint256 cost) {
        Params storage _params = params[lToken];
        require(_params.added, "Not added");

        uint256 _totalValue = totalValue;
        return _totalValue > 0 ? quantity.mul(_params.lastPrice).mul(poolBalance()).div(_totalValue) : quantity;
    }

    function fee(uint256 cost) public view returns (uint256) {
        return cost.mul(tradingFee).div(1e4);
    }

    function poolBalance() public view returns (uint256) {
        // subtract fees so that we only count the balance backing the leveraged tokens
        return baseToken.balanceOf(address(this)).sub(feesAccrued);
    }

    function collectFee() external onlyOwner {
        baseToken.safeTransfer(msg.sender, feesAccrued);
        feesAccrued = 0;
    }

    function finalize() external onlyOwner {
        finalized = true;
    }

    function emergencyWithdraw() external onlyOwner {
        require(!finalized, "Finalized");
        uint256 balance = baseToken.balanceOf(address(this));
        baseToken.safeTransfer(msg.sender, balance);
    }

    function _safeTransferFromSenderToThis(uint256 amount) internal {
        IERC20 _baseToken = baseToken;
        uint256 balanceBefore = _baseToken.balanceOf(address(this));
        _baseToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = _baseToken.balanceOf(address(this));
        require(balanceAfter == balanceBefore.add(amount), "Deflationary tokens not supported");
    }
}
