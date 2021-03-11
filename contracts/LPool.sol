// SPDX-License-Identifier: Unlicense

pragma solidity 0.6.11;

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
import "./LToken.sol";

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
        LToken lToken,
        bool isBuy,
        uint256 quantity,
        uint256 cost
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
        bool priceUpdatePaused;
        uint256 initialPrice;
        uint256 lastPrice;
        uint256 lastUpdated;
    }

    ChainlinkFeedsRegistry feedRegistry;
    LToken lTokenImpl;

    mapping(LToken => Params) public params;
    mapping(address => mapping(Side => LToken)) public leveragedTokensMap;
    LToken[] public lTokens;

    mapping(address => bool) public guardians;
    uint256 public tradingFee; // expressed in basis points
    uint256 public maxTvl; // 0 means no limit
    bool public finalized;

    uint256 public totalValue;
    uint256 public poolBalance;

    /**
     * @param _feedRegistry The `ChainlinkFeedsRegistry` contract that stores
     * chainlink feed addresses
     */
    constructor(address _feedRegistry) public {
        feedRegistry = ChainlinkFeedsRegistry(_feedRegistry);
        lTokenImpl = new LToken();

        // initialize with dummy data so that it can't be initialized again
        lTokenImpl.initialize(address(0), "", "");
    }

    /**
     * @notice Buy leveraged tokens
     * @param lToken The leveraged token to buy
     * @param to The address that receives the leveraged tokens
     * @return cubeTokensOut The amount of base tokens paid
     */
    function buy(
        LToken lToken,
        address to
    ) external payable nonReentrant returns (uint256 cubeTokensOut) {
        Params storage _params = params[lToken];
        require(_params.added, "Not added");
        require(!_params.buyPaused, "Paused");

        uint256 price = updatePrice(lToken);
        uint256 ethIn = subtractFee(msg.value);
        cubeTokensOut = getQuantityFromCost(lToken, ethIn);

        poolBalance = poolBalance.add(ethIn);
        totalValue = totalValue.add(cubeTokensOut.mul(price));
        lToken.mint(to, cubeTokensOut);

        // `maxPoolShare` being 0 means no limit
        uint256 maxPoolShare = _params.maxPoolShare;
        if (maxPoolShare > 0) {
            uint256 lTokenValue = lToken.totalSupply().mul(price);
            require(lTokenValue.mul(1e4) <= maxPoolShare.mul(totalValue), "Max pool share exceeded");
        }

        // `maxTvl` being 0 means no limit
        if (maxTvl > 0) {
            require(poolBalance <= maxTvl, "Max TVL exceeded");
        }

        emit Trade(msg.sender, to, lToken, true, cubeTokensOut, msg.value);
    }

    /**
     * @notice Sell leveraged tokens
     * @param lToken The leveraged token to sell
     * @param cubeTokensIn The quantity of leveraged tokens to sell
     * @param to The address that receives the sale amount
     * @return ethOut The amount of base tokens returned
     */
    function sell(
        LToken lToken,
        uint256 cubeTokensIn,
        address to
    ) external nonReentrant returns (uint256 ethOut) {
        Params storage _params = params[lToken];
        require(_params.added, "Not added");
        require(!_params.sellPaused, "Paused");

        uint256 price = updatePrice(lToken);
        ethOut = getCostFromQuantity(lToken, cubeTokensIn);

        poolBalance = poolBalance.sub(ethOut);
        totalValue = totalValue.sub(cubeTokensIn.mul(price));
        lToken.burn(msg.sender, cubeTokensIn);

        ethOut = subtractFee(ethOut);
        payable(to).transfer(ethOut);

        emit Trade(msg.sender, to, lToken, false, cubeTokensIn, ethOut);
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

        uint256 spot = feedRegistry.getPrice(_params.underlyingToken);
        uint256 cube = spot.mul(spot).mul(spot);

        // invert price for short tokens and convert to 48dp
        uint256 cubeOrInv = _params.side == Side.Long ? cube.mul(1e24) : uint256(1e72).div(cube);
        require(cubeOrInv > 0, "Price should be > 0");

        // set initialPrice the first time this method is called for this leveraged token
        uint256 initialPrice = _params.initialPrice;
        if (initialPrice == 0) {
            initialPrice = _params.initialPrice = cubeOrInv.div(1e18);
        }

        // divide by the initial price to avoid extremely high or low prices
        // price decimals is now 18dp
        price = cubeOrInv.div(initialPrice);

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
                abi.encodePacked(ERC20(underlyingToken).symbol(), (side == Side.Long ? " Cube Token" : " Inverse Cube Token"))
            );
        string memory symbol =
            string(abi.encodePacked((side == Side.Long ? "cube" : "inv"), ERC20(underlyingToken).symbol()));
        lToken.initialize(address(this), name, symbol);

        params[lToken] = Params({
            added: true,
            underlyingToken: underlyingToken,
            side: side,
            maxPoolShare: 0,
            buyPaused: false,
            sellPaused: false,
            priceUpdatePaused: false,
            initialPrice: 0,
            lastPrice: 0,
            lastUpdated: 0
        });
        leveragedTokensMap[underlyingToken][side] = lToken;
        lTokens.push(lToken);

        updatePrice(lToken);
        emit AddLToken(lToken, underlyingToken, side, name, symbol);
        return instance;
    }

    /**
     * @notice Amount received by selling leveraged tokens
     * @param lToken The leveraged token sold
     * @param cost Quantity of leveraged tokens sold
     */
    function getQuantityFromCost(LToken lToken, uint256 cost) public view returns (uint256) {
        Params storage _params = params[lToken];
        require(_params.added, "Not added");

        uint256 _poolBalance = poolBalance;
        return _poolBalance > 0 ? cost.mul(totalValue).div(_params.lastPrice).div(_poolBalance) : cost;
    }

    /**
     * @notice Amount received by selling leveraged tokens
     * @param lToken The leveraged token sold
     * @param quantity Quantity of leveraged tokens sold
     */
    function getCostFromQuantity(LToken lToken, uint256 quantity) public view returns (uint256) {
        Params storage _params = params[lToken];
        require(_params.added, "Not added");

        uint256 _totalValue = totalValue;
        return _totalValue > 0 ? quantity.mul(_params.lastPrice).mul(poolBalance).div(_totalValue) : quantity;
    }

    function subtractFee(uint256 cost) public view returns (uint256) {
        return cost.sub(cost.mul(tradingFee).div(1e4));
    }

    function numLTokens() external view returns (uint256) {
        return lTokens.length;
    }

    function feesAccrued() public view returns (uint256) {
        return address(this).balance.sub(poolBalance);
    }

    function collectFee() external onlyOwner {
        msg.sender.transfer(feesAccrued());
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

    function addGuardian(address guardian) external onlyOwner {
        require(!guardians[guardian], "Already a guardian");
        guardians[guardian] = true;
    }

    function removeGuardian(address guardian) external {
        require(msg.sender == owner() || msg.sender == guardian, "Must be owner or the guardian itself");
        require(guardians[guardian], "Not a guardian");
        guardians[guardian] = false;
    }

    function updateBuyPaused(LToken lToken, bool paused) external {
        require(msg.sender == owner() || guardians[msg.sender], "Must be owner or guardian");
        require(params[lToken].added, "Not added");
        params[lToken].buyPaused = paused;
    }

    function updateSellPaused(LToken lToken, bool paused) external {
        require(msg.sender == owner() || guardians[msg.sender], "Must be owner or guardian");
        require(params[lToken].added, "Not added");
        params[lToken].sellPaused = paused;
    }

    function updatePriceUpdatePaused(LToken lToken, bool paused) external {
        require(msg.sender == owner() || guardians[msg.sender], "Must be owner or guardian");
        require(params[lToken].added, "Not added");
        params[lToken].priceUpdatePaused = paused;
    }

    function updateAllPaused(
        bool buyPaused,
        bool sellPaused,
        bool priceUpdatePaused
    ) external {
        require(msg.sender == owner() || guardians[msg.sender], "Must be owner or guardian");
        for (uint256 i = 0; i < lTokens.length; i = i.add(1)) {
            LToken lToken = lTokens[i];
            params[lToken].buyPaused = buyPaused;
            params[lToken].sellPaused = sellPaused;
            params[lToken].priceUpdatePaused = priceUpdatePaused;
        }
    }

    function finalize() external onlyOwner {
        finalized = true;
    }

    function emergencyWithdraw() external {
        require(msg.sender == owner() || guardians[msg.sender], "Must be owner or guardian");
        require(!finalized, "Finalized");
        payable(owner()).transfer(address(this).balance);
    }
}
