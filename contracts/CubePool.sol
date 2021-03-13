// SPDX-License-Identifier: Unlicense

pragma solidity 0.6.12;

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
import "./CubeToken.sol";

/**
 * @title Cube Pool
 * @notice A pool where users can mint cube tokens by depositing ETH and
 * burn them to withdraw ETH.
 */
contract CubePool is Ownable, ReentrancyGuard {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    event DepositOrWithdraw(
        address indexed sender,
        address indexed to,
        CubeToken indexed cubeToken,
        bool isDeposit,
        uint256 quantity,
        uint256 cost
    );
    event UpdatePrice(CubeToken cubeToken, uint256 price);
    event AddCubeToken(CubeToken cubeToken, string spotSymbol, bool inverse);

    struct Params {
        string spotSymbol;
        bool inverse;
        uint256 maxPoolShare;
        uint256 initialPrice;
        uint256 lastPrice;
        uint256 lastUpdated;
        bool depositPaused;
        bool withdrawPaused;
        bool priceUpdatePaused;
        bool added; // always true - used to check existence
    }

    ChainlinkFeedsRegistry public feedRegistry;
    CubeToken public cubeTokenImpl = new CubeToken();

    mapping(CubeToken => Params) public params;
    mapping(string => mapping(bool => CubeToken)) public cubeTokensMap;
    CubeToken[] public cubeTokens;

    mapping(address => bool) public guardians;
    uint256 public tradingFee; // expressed in basis points
    uint256 public maxTvl; // 0 means no limit
    bool public finalized;

    // total value is always equal to sum of totalSupply * price over all cube tokens
    uint256 public totalValue;

    // pool balance is ETH balance of this contract minus trading fees accrued so far
    uint256 public poolBalance;

    /**
     * @param _feedRegistry The `ChainlinkFeedsRegistry` contract that's used
     * to fetch underlying prices from chainlink oracles
     */
    constructor(address _feedRegistry) public {
        feedRegistry = ChainlinkFeedsRegistry(_feedRegistry);

        // initialize with dummy data so that it can't be initialized again
        cubeTokenImpl.initialize(address(0), "", false);
    }

    /**
     * @notice Deposit ETH and mint leveraged tokens
     * @dev ETH has to be sent in when calling this and the corresponding
     * quantity of cube tokens is calculated.
     * @param cubeToken The cube token to mint
     * @param to Address that receives the cube tokens
     * @return cubeTokensOut Quantity of cube tokens that were minted
     */
    function deposit(CubeToken cubeToken, address to) external payable nonReentrant returns (uint256 cubeTokensOut) {
        Params storage _params = params[cubeToken];
        require(_params.added, "Not added");
        require(!_params.depositPaused, "Paused");

        uint256 price = updatePrice(cubeToken);
        uint256 ethIn = subtractFee(msg.value);
        cubeTokensOut = poolBalance > 0 ? ethIn.mul(totalValue).div(price).div(poolBalance) : ethIn;

        poolBalance = poolBalance.add(ethIn);
        totalValue = totalValue.add(cubeTokensOut.mul(price));
        cubeToken.mint(to, cubeTokensOut);

        // don't allow cube token to be minted if its share of the pool is too large
        if (_params.maxPoolShare > 0) {
            uint256 value = cubeToken.totalSupply().mul(price);
            require(value.mul(1e4) <= _params.maxPoolShare.mul(totalValue), "Max pool share exceeded");
        }

        // cap tvl for guarded launch
        if (maxTvl > 0) {
            require(poolBalance <= maxTvl, "Max TVL exceeded");
        }

        emit DepositOrWithdraw(msg.sender, to, cubeToken, true, cubeTokensOut, msg.value);
    }

    /**
     * @notice Withdraw ETH and burn cube tokens
     * @param cubeToken The cube token to burn
     * @param cubeTokensIn Quantity of cube tokens to burn
     * @param to Address that receives the sale amount
     * @return ethOut Amount of ETH returned to recipient
     */
    function withdraw(
        CubeToken cubeToken,
        uint256 cubeTokensIn,
        address to
    ) external nonReentrant returns (uint256 ethOut) {
        Params storage _params = params[cubeToken];
        require(_params.added, "Not added");
        require(!_params.withdrawPaused, "Paused");

        uint256 price = updatePrice(cubeToken);
        ethOut = totalValue > 0 ? price.mul(cubeTokensIn).mul(poolBalance).div(totalValue) : cubeTokensIn;

        poolBalance = poolBalance.sub(ethOut);
        totalValue = totalValue.sub(cubeTokensIn.mul(price));
        cubeToken.burn(msg.sender, cubeTokensIn);

        ethOut = subtractFee(ethOut);
        payable(to).transfer(ethOut);

        emit DepositOrWithdraw(msg.sender, to, cubeToken, false, cubeTokensIn, ethOut);
    }

    /**
     * @notice Update the stored cube token price and total value. It is
     * automatically called when this cube token is minted or burned. However
     * if it has not been traded for a while, it should be called periodically
     * so that the total value does get too far out of sync
     * @param cubeToken Leveraged token whose price is updated
     * @return price Updated unnormalized cube token price
     */
    function updatePrice(CubeToken cubeToken) public returns (uint256) {
        Params storage _params = params[cubeToken];
        require(_params.added, "Not added");

        // don't update if paused
        if (_params.priceUpdatePaused) {
            return _params.lastPrice;
        }

        (uint256 price, uint256 _totalValue) = _getPriceAndTotalValue(cubeToken);
        totalValue = _totalValue;

        _params.lastPrice = price;
        _params.lastUpdated = block.timestamp;

        emit UpdatePrice(cubeToken, price);
        return price;
    }

    function updateAllPrices(uint256 maxStaleTime) public {
        for (uint256 i = 0; i < cubeTokens.length; i = i.add(1)) {
            CubeToken cubeToken = cubeTokens[i];
            if (params[cubeToken].lastUpdated.add(maxStaleTime) <= block.timestamp) {
                updatePrice(cubeToken);
            }
        }
    }

    /**
     * @notice Add a new cube token. Can only be called by owner
     * @param spotSymbol Symbol of underlying token. Used to fetch price from oracle
     * @param inverse Long or short
     * @return address Address of cube token that was added
     */
    function addCubeToken(string memory spotSymbol, bool inverse) external onlyOwner returns (address) {
        require(address(cubeTokensMap[spotSymbol][inverse]) == address(0), "Already added");

        bytes32 salt = keccak256(abi.encodePacked(spotSymbol, inverse));
        address instance = Clones.cloneDeterministic(address(cubeTokenImpl), salt);
        CubeToken cubeToken = CubeToken(instance);

        cubeToken.initialize(address(this), spotSymbol, inverse);

        params[cubeToken] = Params({
            added: true,
            spotSymbol: spotSymbol,
            inverse: inverse,
            maxPoolShare: 0,
            depositPaused: false,
            withdrawPaused: false,
            priceUpdatePaused: false,
            initialPrice: 0,
            lastPrice: 0,
            lastUpdated: 0
        });
        cubeTokensMap[spotSymbol][inverse] = cubeToken;
        cubeTokens.push(cubeToken);

        uint256 initialPrice = getSpotCubed(cubeToken).div(1e18);
        params[cubeToken].initialPrice = initialPrice;
        require(initialPrice > 0, "Price should be > 0");

        updatePrice(cubeToken);
        emit AddCubeToken(cubeToken, spotSymbol, inverse);
        return instance;
    }

    // /**
    //  * @notice Quantity of cube tokens minted or burned when sending in or receiving
    //  * `cost` amount of ETH
    //  * @dev Divide by price and normalize using total value and pool balance
    //  * @param cost Amount of ETH sent in when minting or received when burning
    //  */
    // function getQuantityFromCost(uint256 price, uint256 cost) public view returns (uint256) {
    //     return poolBalance > 0 ? cost.mul(totalValue).div(price).div(poolBalance) : cost;
    // }

    // /**
    //  * @notice Amount of ETH received or sent in when minting or burning `quantity`
    //  * amount of cube tokens
    //  * @dev Multiply by price and normalize using total value and pool balance
    //  * @param quantity Quantity of cube tokens minted or burned
    //  */
    // function getCostFromQuantity(uint256 price, uint256 quantity) public view returns (uint256) {
    //     return totalValue > 0 ? price.mul(quantity).mul(poolBalance).div(totalValue) : quantity;
    // }

    function quote(CubeToken cubeToken, uint256 quantity) public view returns (uint256) {
        Params storage _params = params[cubeToken];
        (uint256 price, uint256 _totalValue) = _getPriceAndTotalValue(cubeToken);
        return _totalValue > 0 ? price.mul(quantity).mul(poolBalance).div(_totalValue) : quantity;
    }

    function getSpotCubed(CubeToken cubeToken) public view returns (uint256) {
        Params storage _params = params[cubeToken];
        uint256 spot = feedRegistry.getPrice(_params.spotSymbol);
        uint256 spot3 = spot.mul(spot).mul(spot);

        // returns price multiplied by 1e48
        return _params.inverse ? uint256(1e72).div(spot3) : spot3.mul(1e24);
    }

    function _getPriceAndTotalValue(CubeToken cubeToken) internal view returns (uint256 price, uint256 _totalValue) {
        Params storage _params = params[cubeToken];
        price = getSpotCubed(cubeToken).div(_params.initialPrice);

        uint256 _totalSupply = cubeToken.totalSupply();
        uint256 valueBefore = _params.lastPrice.mul(_totalSupply);
        uint256 valueAfter = price.mul(_totalSupply);
        _totalValue = totalValue.add(valueAfter).sub(valueBefore);
    }

    function subtractFee(uint256 amount) public view returns (uint256) {
        uint256 fee = amount.mul(tradingFee).div(1e4); // round down fee
        return amount.sub(fee);
    }

    /**
     * @dev Amount of fees accrued so far in terms of ETH. This is the amount
     * that's withdrawable by the owner. The remaining `poolBalance` is the
     * total amount of ETH withdrawable by cube token holders.
     */
    function feeAccrued() public view returns (uint256) {
        return address(this).balance.sub(poolBalance);
    }

    function collectFee() external onlyOwner {
        msg.sender.transfer(feeAccrued());
    }

    /**
     * @notice Update max pool share for token. Expressed in basis points.
     * Setting to 0 means no limit
     */
    function setMaxPoolShare(CubeToken cubeToken, uint256 maxPoolShare) external onlyOwner {
        require(params[cubeToken].added, "Not added");
        require(maxPoolShare < 1e4, "Max pool share should be < 100%");
        params[cubeToken].maxPoolShare = maxPoolShare;
    }

    /**
     * @notice Update TVL cap for a guarded launch. Setting to 0 means no limit
     */
    function setMaxTvl(uint256 _maxTvl) external onlyOwner {
        maxTvl = _maxTvl;
    }

    /**
     * @notice Update trading fee. Expressed in basis points
     */
    function setTradingFee(uint256 _tradingFee) external onlyOwner {
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

    function setPaused(
        CubeToken cubeToken,
        bool depositPaused,
        bool withdrawPaused,
        bool priceUpdatePaused
    ) external {
        require(msg.sender == owner() || guardians[msg.sender], "Must be owner or guardian");
        require(params[cubeToken].added, "Not added");
        params[cubeToken].depositPaused = depositPaused;
        params[cubeToken].withdrawPaused = withdrawPaused;
        params[cubeToken].priceUpdatePaused = priceUpdatePaused;
    }

    function setAllPaused(
        bool depositPaused,
        bool withdrawPaused,
        bool priceUpdatePaused
    ) external {
        require(msg.sender == owner() || guardians[msg.sender], "Must be owner or guardian");
        for (uint256 i = 0; i < cubeTokens.length; i = i.add(1)) {
            CubeToken cubeToken = cubeTokens[i];
            params[cubeToken].depositPaused = depositPaused;
            params[cubeToken].withdrawPaused = withdrawPaused;
            params[cubeToken].priceUpdatePaused = priceUpdatePaused;
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

    function numCubeTokens() external view returns (uint256) {
        return cubeTokens.length;
    }

    function allCubeTokens() external view returns (CubeToken[] memory _cubeTokens) {
        _cubeTokens = new CubeToken[](cubeTokens.length);
        for (uint256 i = 0; i < cubeTokens.length; i = i.add(1)) {
            _cubeTokens[i] = cubeTokens[i];
        }
    }

    function getCubeTokenInfo(CubeToken cubeToken)
        external
        view
        returns (
            string memory name,
            string memory symbol,
            uint256 totalSupply,
            uint256 price,
            uint256 underlyingPrice,
            bool inverse,
            uint256 maxPoolShare,
            uint256 lastPrice,
            uint256 lastUpdated,
            bool depositPaused,
            bool withdrawPaused,
            bool priceUpdatePaused
        )
    {
        name = cubeToken.name();
        symbol = cubeToken.symbol();
        totalSupply = cubeToken.totalSupply();
        price = quote(cubeToken, 1e18);

        Params memory _params = params[cubeToken];
        underlyingPrice = feedRegistry.getPrice(_params.spotSymbol);

        inverse = _params.inverse;
        maxPoolShare = _params.maxPoolShare;
        lastPrice = _params.lastPrice;
        lastUpdated = _params.lastUpdated;
        depositPaused = _params.depositPaused;
        withdrawPaused = _params.withdrawPaused;
        priceUpdatePaused = _params.priceUpdatePaused;
    }
}
