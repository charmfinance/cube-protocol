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
 * @title   Cube Pool
 * @notice  Parimutuel pool where users can deposit ETH to mint cube tokens
 *          and burn them to withdraw ETH. The cube token represents a share of
 *          the pool and the share percentage is adjusted by the pool
 *          continuously as the price of the underlying asset changes.
 *          Cube tokens such as cubeBTC approximately track BTC price ^ 3,
 *          while inverse cube tokens such as invBTC approximately track
 *          1 / BTC price ^ 3.
 */
contract CubePool is Ownable, ReentrancyGuard {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    event DepositOrWithdraw(
        CubeToken indexed cubeToken,
        address indexed sender,
        address indexed to,
        bool isDeposit,
        uint256 quantity,
        uint256 ethAmount,
        uint256 feeAmount
    );

    event Update(CubeToken cubeToken, uint256 price);

    event AddCubeToken(
        CubeToken cubeToken,
        string spotSymbol,
        bool inverse,
        bytes32 currencyKey,
        uint256 initialSpotPrice
    );

    struct Params {
        bytes32 currencyKey;
        bool inverse;
        bool depositPaused;
        bool withdrawPaused;
        bool updatePaused;
        bool added; // always true
        uint256 fee;
        uint256 maxPoolShare;
        uint256 initialSpotPrice;
        uint256 lastPrice;
        uint256 lastUpdated;
    }

    ChainlinkFeedsRegistry public immutable feedRegistry;
    CubeToken public cubeTokenImpl = new CubeToken();

    mapping(CubeToken => Params) public params;
    CubeToken[] public cubeTokens;

    // underlying symbol => inverse => cube token
    mapping(string => mapping(bool => CubeToken)) public cubeTokensMap;

    address public guardian;
    uint256 public maxTvl;
    bool public finalized;

    uint256 public totalValue;
    uint256 public poolBalance;

    /**
     * @param _feedRegistry The feed registry contract for
     * fetching spot prices from Chainlink oracles
     */
    constructor(address _feedRegistry) public {
        feedRegistry = ChainlinkFeedsRegistry(_feedRegistry);

        // Initialize with dummy data so that it can't be initialized again
        cubeTokenImpl.initialize(address(0), "", false);
    }

    /**
     * @notice Deposit ETH to mint cube tokens
     * @dev Quantity of cube tokens minted is calculated from the amount of ETH
     * attached with transaction
     * @param cubeToken Which cube token to mint
     * @param to Address that receives the cube tokens
     * @return cubeTokensOut Quantity of cube tokens that were minted
     */
    function deposit(CubeToken cubeToken, address to) external payable nonReentrant returns (uint256 cubeTokensOut) {
        Params storage _params = params[cubeToken];
        require(_params.added, "Not added");
        require(!_params.depositPaused, "Paused");

        (uint256 price, uint256 _totalValue) = _priceAndTotalValue(cubeToken);
        _updatePrice(cubeToken, price);

        uint256 feeAmount = _fee(msg.value, _params.fee);
        uint256 ethIn = msg.value.sub(feeAmount);

        // normalize price so that total value of all cube tokens equals pool balance
        cubeTokensOut = _divPrice(ethIn, price, _totalValue);
        poolBalance = poolBalance.add(ethIn);
        totalValue = _totalValue.add(cubeTokensOut.mul(price));
        cubeToken.mint(to, cubeTokensOut);

        if (_params.maxPoolShare > 0) {
            uint256 value = cubeToken.totalSupply().mul(price);
            require(value.mul(1e4) <= _params.maxPoolShare.mul(totalValue), "Max pool share exceeded");
        }

        if (maxTvl > 0) {
            require(poolBalance <= maxTvl, "Max TVL exceeded");
        }

        emit DepositOrWithdraw(cubeToken, msg.sender, to, true, cubeTokensOut, msg.value, feeAmount);
    }

    /**
     * @notice Burn cube tokens to withdraw ETH
     * @param cubeToken Which cube token to burn
     * @param cubeTokensIn Quantity of cube tokens to burn
     * @param to Address that receives the withdrawn ETH
     * @return ethOut Amount of ETH withdrawn
     */
    function withdraw(
        CubeToken cubeToken,
        uint256 cubeTokensIn,
        address to
    ) external nonReentrant returns (uint256 ethOut) {
        Params storage _params = params[cubeToken];
        require(_params.added, "Not added");
        require(!_params.withdrawPaused, "Paused");

        (uint256 price, uint256 _totalValue) = _priceAndTotalValue(cubeToken);
        _updatePrice(cubeToken, price);

        // normalize price so that total value of all cube tokens equals pool balance
        ethOut = _mulPrice(cubeTokensIn, price, _totalValue);
        poolBalance = poolBalance.sub(ethOut);
        totalValue = _totalValue.sub(cubeTokensIn.mul(price));
        cubeToken.burn(msg.sender, cubeTokensIn);

        uint256 feeAmount = _fee(ethOut, _params.fee);
        ethOut = ethOut.sub(feeAmount);
        payable(to).transfer(ethOut);

        emit DepositOrWithdraw(cubeToken, msg.sender, to, false, cubeTokensIn, ethOut, feeAmount);
    }

    /**
     * @notice Update the stored cube token price and total value. This is
     * automatically called when the cube token is minted or burned. However
     * if it has not been traded for a while, it should be called periodically
     * so that the total value does get too far out of sync
     */
    function update(CubeToken cubeToken) public {
        Params storage _params = params[cubeToken];
        require(_params.added, "Not added");

        if (!_params.updatePaused) {
            (uint256 price, uint256 _totalValue) = _priceAndTotalValue(cubeToken);
            _updatePrice(cubeToken, price);
            totalValue = _totalValue;
        }
    }

    function _updatePrice(CubeToken cubeToken, uint256 price) internal {
        Params storage _params = params[cubeToken];
        if (!_params.updatePaused) {
            _params.lastPrice = price;
            _params.lastUpdated = block.timestamp;
            emit Update(cubeToken, price);
        }
    }

    /**
     * @notice Update all cube tokens which haven't been update in the last
     * `maxStaleTime` seconds
     */
    function updateAll(uint256 maxStaleTime) public {
        for (uint256 i = 0; i < cubeTokens.length; i = i.add(1)) {
            CubeToken cubeToken = cubeTokens[i];
            if (params[cubeToken].lastUpdated.add(maxStaleTime) <= block.timestamp) {
                update(cubeToken);
            }
        }
    }

    /**
     * @notice Add a new cube token. Can only be called by owner
     * @param spotSymbol Symbol of underlying token. Used to fetch price from oracle
     * @param inverse True means 3x short token. False means 3x long token.
     * @return address Address of cube token that was added
     */
    function addCubeToken(string memory spotSymbol, bool inverse) external onlyOwner returns (address) {
        require(address(cubeTokensMap[spotSymbol][inverse]) == address(0), "Already added");

        bytes32 salt = keccak256(abi.encodePacked(spotSymbol, inverse));
        address instance = Clones.cloneDeterministic(address(cubeTokenImpl), salt);
        CubeToken cubeToken = CubeToken(instance);
        cubeToken.initialize(address(this), spotSymbol, inverse);

        bytes32 currencyKey = feedRegistry.stringToBytes32(spotSymbol);
        params[cubeToken] = Params({
            currencyKey: currencyKey,
            inverse: inverse,
            depositPaused: false,
            withdrawPaused: false,
            updatePaused: false,
            added: true,
            fee: 0,
            maxPoolShare: 0,
            initialSpotPrice: 0,
            lastPrice: 0,
            lastUpdated: 0
        });
        cubeTokensMap[spotSymbol][inverse] = cubeToken;
        cubeTokens.push(cubeToken);

        uint256 spot = feedRegistry.getPrice(currencyKey);
        require(spot > 0, "Spot price should be > 0");

        params[cubeToken].initialSpotPrice = spot;
        update(cubeToken);

        emit AddCubeToken(cubeToken, spotSymbol, inverse, currencyKey, spot);
        return instance;
    }

    /**
     * @notice Calculate price of a cube token in ETH, multiplied by 1e18
     * excluding fees. Note that this price applies to both depositing and
     * withdrawing.
     */
    function quote(CubeToken cubeToken) public view returns (uint256) {
        (uint256 price, uint256 _totalValue) = _priceAndTotalValue(cubeToken);
        return _totalValue > 0 ? price.mul(1e18).mul(poolBalance).div(_totalValue) : 1e18;
    }

    /**
     * @notice Calculate amount of cube tokens received by depositing `ethIn`
     * ETH.
     */
    function quoteDeposit(CubeToken cubeToken, uint256 ethIn) external view returns (uint256) {
        ethIn = ethIn.sub(_fee(ethIn, params[cubeToken].fee));
        (uint256 price, uint256 _totalValue) = _priceAndTotalValue(cubeToken);
        return _divPrice(ethIn, price, _totalValue);
    }

    /**
     * @notice Calculate ETH withdrawn when burning `cubeTokensIn` cube tokens.
     */
    function quoteWithdraw(CubeToken cubeToken, uint256 cubeTokensIn) external view returns (uint256) {
        (uint256 price, uint256 _totalValue) = _priceAndTotalValue(cubeToken);
        uint256 ethOut = _mulPrice(cubeTokensIn, price, _totalValue);
        return ethOut.sub(_fee(ethOut, params[cubeToken].fee));
    }

    function numCubeTokens() external view returns (uint256) {
        return cubeTokens.length;
    }

    /**
     * @dev Calculate price and total value from latest oracle price
     */
    function _priceAndTotalValue(CubeToken cubeToken) internal view returns (uint256 price, uint256 _totalValue) {
        Params storage _params = params[cubeToken];
        if (_params.updatePaused) {
            return (_params.lastPrice, totalValue);
        }

        uint256 spot = feedRegistry.getPrice(_params.currencyKey);

        // Normalize by the spot price at the time the cube token was added.
        // This helps the price not be too large or small which could cause
        // rounding issues
        spot = spot.mul(1e6).div(_params.initialSpotPrice);

        // Set `price` to spot^3 or 1/spot^3. Its value is multiplied by 1e24
        if (_params.inverse) {
            price = uint256(1e36).div(spot).div(spot).div(spot);
        } else {
            price = spot.mul(spot).mul(spot);
        }

        // Update total value to reflect new price. Total value is the sum of
        // total supply x price over all cube tokens. Therefore, when the price
        // of a cube token with total supply T changes from P1 to P2, the total
        // value needs to be increased by T x (P2 - P1)
        uint256 _totalSupply = cubeToken.totalSupply();
        uint256 valueBefore = _params.lastPrice.mul(_totalSupply);
        uint256 valueAfter = price.mul(_totalSupply);
        _totalValue = totalValue.add(valueAfter).sub(valueBefore);
    }

    /// @dev Multiply quantity by price and normalize to get ETH cost
    function _mulPrice(
        uint256 quantity,
        uint256 price,
        uint256 _totalValue
    ) internal view returns (uint256) {
        return _totalValue > 0 ? price.mul(quantity).mul(poolBalance).div(_totalValue) : quantity;
    }

    /// @dev Divide ETH amount by price and normalize to get quantity
    function _divPrice(
        uint256 amount,
        uint256 price,
        uint256 _totalValue
    ) internal view returns (uint256) {
        return poolBalance > 0 ? amount.mul(_totalValue).div(price).div(poolBalance) : amount;
    }

    /// @dev Multiply by fee, rounded down
    function _fee(uint256 amount, uint256 fee) internal pure returns (uint256) {
        return amount.mul(fee).div(1e4);
    }

    /**
     * @notice Amount of fees accrued so far from deposits and withdrawals.
     * @dev `poolBalance` is the amount of ETH withdrawable by cube token
     * holders and so the fees are the remaining amount of ETH in the contract.
     */
    function feeAccrued() public view returns (uint256) {
        return address(this).balance.sub(poolBalance);
    }

    function collectFee() external onlyOwner {
        msg.sender.transfer(feeAccrued());
    }

    /**
     * @notice Set deposit and withdraw fee. Expressed in basis points, for
     * example a value of 100 means a 1% fee.
     */
    function setFee(CubeToken cubeToken, uint256 fee) external onlyOwner {
        require(params[cubeToken].added, "Not added");
        require(fee < 1e4, "Fee should be < 100%");
        params[cubeToken].fee = fee;
    }

    /**
     * @notice Set max pool share for a cube token. Expressed in basis points.
     * A value of 0 means no limit. This protects users from buying cube tokens
     * with limited upside, as well as protecting the whole pool from the
     * volatility of a single asset.
     */
    function setMaxPoolShare(CubeToken cubeToken, uint256 maxPoolShare) external onlyOwner {
        require(params[cubeToken].added, "Not added");
        require(maxPoolShare < 1e4, "Max pool share should be < 100%");
        params[cubeToken].maxPoolShare = maxPoolShare;
    }

    /**
     * @notice Set TVL cap for a guarded launch. A value of 0 means no limit
     */
    function setMaxTvl(uint256 _maxTvl) external onlyOwner {
        maxTvl = _maxTvl;
    }

    /**
     * @notice Set guardian. This is a trusted account which has the powers
     * to pause and unpause trading and to emergency withdraw. These
     * protections are needed for example to protect funds if there is an
     * oracle mispricing.
     */
    function setGuardian(address _guardian) external onlyOwner {
        guardian = _guardian;
    }

    /**
     * @notice Pause or unpause deposits withdrawals and price updates
     */
    function setPaused(
        CubeToken cubeToken,
        bool depositPaused,
        bool withdrawPaused,
        bool updatePaused
    ) external {
        require(msg.sender == owner() || msg.sender == guardian, "Must be owner or guardian");
        require(params[cubeToken].added, "Not added");
        params[cubeToken].depositPaused = depositPaused;
        params[cubeToken].withdrawPaused = withdrawPaused;
        params[cubeToken].updatePaused = updatePaused;
    }

    /**
     * @notice Pause or unpause for all cube tokens
     */
    function setAllPaused(
        bool depositPaused,
        bool withdrawPaused,
        bool updatePaused
    ) external {
        require(msg.sender == owner() || msg.sender == guardian, "Must be owner or guardian");
        for (uint256 i = 0; i < cubeTokens.length; i = i.add(1)) {
            CubeToken cubeToken = cubeTokens[i];
            params[cubeToken].depositPaused = depositPaused;
            params[cubeToken].withdrawPaused = withdrawPaused;
            params[cubeToken].updatePaused = updatePaused;
        }
    }

    /**
     * @notice Renounce emergency withdraw powers
     */
    function finalize() external onlyOwner {
        require(!finalized, "Already finalized");
        finalized = true;
    }

    /**
     * @notice Transfer all ETH to owner in case of emergency. Cannot be called
     * if already finalized
     */
    function emergencyWithdraw() external {
        require(msg.sender == owner() || msg.sender == guardian, "Must be owner or guardian");
        require(!finalized, "Finalized");
        payable(owner()).transfer(address(this).balance);
    }
}
