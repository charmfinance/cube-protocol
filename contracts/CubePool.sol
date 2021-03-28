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
        address indexed recipient,
        bool isDeposit,
        uint256 cubeTokenQuantity,
        uint256 ethAmount,
        uint256 fees
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

    ChainlinkFeedsRegistry public immutable feed;
    CubeToken public cubeTokenImpl = new CubeToken();

    mapping(CubeToken => Params) public params;
    mapping(string => mapping(bool => CubeToken)) public cubeTokensMap;
    CubeToken[] public cubeTokens;

    address public guardian;
    uint256 public protocolFee;
    uint256 public maxPoolBalance;
    bool public finalized;

    uint256 public totalValue;
    uint256 public accumulatedFees;

    /**
     * @param chainlinkFeedsRegistry The feed registry contract for
     * fetching spot prices from Chainlink oracles
     */
    constructor(address chainlinkFeedsRegistry) public {
        feed = ChainlinkFeedsRegistry(chainlinkFeedsRegistry);

        // Initialize with dummy data so that it can't be initialized again
        cubeTokenImpl.initialize(address(0), "", false);
    }

    /**
     * @notice Deposit ETH to mint cube tokens
     * @dev Quantity of cube tokens minted is calculated from the amount of ETH
     * attached with transaction
     * @param cubeToken Which cube token to mint
     * @param recipient Address that receives the cube tokens
     * @return cubeTokensOut Quantity of cube tokens that were minted
     */
    function deposit(CubeToken cubeToken, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 cubeTokensOut)
    {
        Params storage _params = params[cubeToken];
        require(_params.added, "Not added");
        require(!_params.depositPaused, "Paused");
        require(msg.value > 0, "msg.value should be > 0");
        require(recipient != address(0), "Zero address");

        (uint256 price, uint256 _totalValue) = _priceAndTotalValue(cubeToken);
        _updatePrice(cubeToken, price);

        uint256 fees = _mulFee(msg.value, _params.fee);
        uint256 ethIn = msg.value.sub(fees);
        uint256 _poolBalance = poolBalance();

        cubeTokensOut = _divPrice(ethIn, price, _totalValue, _poolBalance.sub(msg.value));
        totalValue = _totalValue.add(cubeTokensOut.mul(price));
        accumulatedFees = accumulatedFees.add(_mulFee(fees, protocolFee));
        cubeToken.mint(recipient, cubeTokensOut);

        if (_params.maxPoolShare > 0) {
            uint256 value = cubeToken.totalSupply().mul(price);
            require(value.mul(1e4) <= _params.maxPoolShare.mul(totalValue), "Max pool share exceeded");
        }

        if (maxPoolBalance > 0) {
            require(_poolBalance <= maxPoolBalance, "Max pool balance exceeded");
        }

        emit DepositOrWithdraw(cubeToken, msg.sender, recipient, true, cubeTokensOut, msg.value, fees);
    }

    /**
     * @notice Burn cube tokens to withdraw ETH
     * @param cubeToken Which cube token to burn
     * @param cubeTokensIn Quantity of cube tokens to burn
     * @param recipient Address that receives the withdrawn ETH
     * @return ethOut Amount of ETH withdrawn
     */
    function withdraw(
        CubeToken cubeToken,
        uint256 cubeTokensIn,
        address recipient
    ) external nonReentrant returns (uint256 ethOut) {
        Params storage _params = params[cubeToken];
        require(_params.added, "Not added");
        require(!_params.withdrawPaused, "Paused");
        require(cubeTokensIn > 0, "cubeTokensIn should be > 0");
        require(recipient != address(0), "Zero address");

        (uint256 price, uint256 _totalValue) = _priceAndTotalValue(cubeToken);
        _updatePrice(cubeToken, price);

        ethOut = _mulPrice(cubeTokensIn, price, _totalValue, poolBalance());
        totalValue = _totalValue.sub(cubeTokensIn.mul(price));

        uint256 fees = _mulFee(ethOut, _params.fee);
        ethOut = ethOut.sub(fees);
        accumulatedFees = accumulatedFees.add(_mulFee(fees, protocolFee));

        cubeToken.burn(msg.sender, cubeTokensIn);
        payable(recipient).transfer(ethOut);

        emit DepositOrWithdraw(cubeToken, msg.sender, recipient, false, cubeTokensIn, ethOut, fees);
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

    /**
     * @dev Update `lastPrice` and `lastUpdated` in params. Should be called
     * whenever a price from oracle changes.
     */
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

        bytes32 currencyKey = feed.stringToBytes32(spotSymbol);
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

        uint256 spot = feed.getPrice(currencyKey);
        require(spot > 0, "Spot price should be > 0");

        params[cubeToken].initialSpotPrice = spot;
        update(cubeToken);

        emit AddCubeToken(cubeToken, spotSymbol, inverse, currencyKey, spot);
        return instance;
    }

    /**
     * @notice ETH in this contract that belongs to cube token holders. The
     * remaining ETH are the accumulated fees that can be collected by the
     * owner.
     */
    function poolBalance() public view returns (uint256) {
        return address(this).balance.sub(accumulatedFees);
    }

    /**
     * @notice Calculate price of a cube token in ETH, multiplied by 1e18
     * excluding fees. Note that this price applies to both depositing and
     * withdrawing.
     */
    function quote(CubeToken cubeToken) public view returns (uint256) {
        (uint256 price, uint256 _totalValue) = _priceAndTotalValue(cubeToken);
        return _mulPrice(1e18, price, _totalValue, poolBalance());
    }

    /**
     * @notice Calculate amount of cube tokens received by depositing `ethIn`
     * ETH.
     */
    function quoteDeposit(CubeToken cubeToken, uint256 ethIn) external view returns (uint256) {
        (uint256 price, uint256 _totalValue) = _priceAndTotalValue(cubeToken);
        uint256 fees = _mulFee(ethIn, params[cubeToken].fee);
        return _divPrice(ethIn.sub(fees), price, _totalValue, poolBalance());
    }

    /**
     * @notice Calculate ETH withdrawn when burning `cubeTokensIn` cube tokens.
     */
    function quoteWithdraw(CubeToken cubeToken, uint256 cubeTokensIn) external view returns (uint256) {
        (uint256 price, uint256 _totalValue) = _priceAndTotalValue(cubeToken);
        uint256 ethOut = _mulPrice(cubeTokensIn, price, _totalValue, poolBalance());
        uint256 fees = _mulFee(ethOut, params[cubeToken].fee);
        return ethOut.sub(fees);
    }

    function numCubeTokens() external view returns (uint256) {
        return cubeTokens.length;
    }

    /// @dev Calculate price and total value from latest oracle price
    function _priceAndTotalValue(CubeToken cubeToken) internal view returns (uint256 price, uint256 _totalValue) {
        Params storage _params = params[cubeToken];
        if (_params.updatePaused) {
            return (_params.lastPrice, totalValue);
        }

        uint256 spot = feed.getPrice(_params.currencyKey);

        // Divide by the spot price at the time the cube token was added.
        // This helps the price not be too large or small which could cause
        // rounding issues.
        spot = spot.mul(1e6).div(_params.initialSpotPrice);

        // Price is spot^3 or 1/spot^3. Its value is multiplied by 1e18.
        if (_params.inverse) {
            price = uint256(1e36).div(spot).div(spot).div(spot);
        } else {
            price = spot.mul(spot).mul(spot);
        }

        // Update total value to reflect new price. Total value is the sum of
        // total supply * price over all cube tokens. Therefore, when the price
        // of a cube token with total supply T changes from P1 to P2, the total
        // value needs to be increased by T * (P2 - P1)
        uint256 _totalSupply = cubeToken.totalSupply();
        uint256 valueBefore = _params.lastPrice.mul(_totalSupply);
        uint256 valueAfter = price.mul(_totalSupply);
        _totalValue = totalValue.add(valueAfter).sub(valueBefore);
    }

    /// @dev Multiply cube token quantity by price and normalize to get ETH cost
    function _mulPrice(
        uint256 quantity,
        uint256 price,
        uint256 _totalValue,
        uint256 _poolBalance
    ) internal pure returns (uint256) {
        return _totalValue > 0 ? price.mul(quantity).mul(_poolBalance).div(_totalValue) : quantity;
    }

    /// @dev Divide ETH amount by price and normalize to get cube token quantity
    function _divPrice(
        uint256 amount,
        uint256 price,
        uint256 _totalValue,
        uint256 _poolBalance
    ) internal pure returns (uint256) {
        return _poolBalance > 0 ? amount.mul(_totalValue).div(price).div(_poolBalance) : amount;
    }

    /**
     * @dev Calculate amount of fees paid in ETH
     * @param amount Amount of ETH paid or received in deposit/withdrawal
     * @param fee Fee rate in basis points
     */
    function _mulFee(uint256 amount, uint256 fee) internal pure returns (uint256) {
        return amount.mul(fee).div(1e4);
    }

    function collectProtocolFees() external onlyOwner {
        payable(owner()).transfer(accumulatedFees);
        accumulatedFees = 0;
    }

    /**
     * @notice Set protocol fee in basis points. This is the cut of fees that
     * go to the protocol.
     */
    function setProtocolFee(uint256 _protocolFee) external onlyOwner {
        require(_protocolFee <= 1e4, "Protocol fee should be <= 100%");
        protocolFee = _protocolFee;
    }

    /**
     * @notice Set fee in basis points charged on each deposit and withdrawal.
     * For example a value of 100 means a 1% fee.
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
     * @notice Set max pool balance for a guarded launch. A value of 0 means no
     * limit
     */
    function setMaxPoolBalance(uint256 _maxPoolBalance) external onlyOwner {
        maxPoolBalance = _maxPoolBalance;
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
    ) public {
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
            setPaused(cubeTokens[i], depositPaused, withdrawPaused, updatePaused);
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

    receive() external payable {}
}
