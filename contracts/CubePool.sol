// SPDX-License-Identifier: Unlicense

pragma solidity 0.6.12;

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
 *          and burn them to withdraw ETH. Cube tokens represents a share of
 *          the pool and the pool share is adjusted continuously as the price
 *          of the underlying asset changes. Cube tokens such as cubeBTC
 *          approximately track BTC price ^ 3, while inverse cube tokens such
 *          as invBTC approximately track 1 / BTC price ^ 3.
 */
contract CubePool is ReentrancyGuard {
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
        uint256 protocolFees
    );

    event Update(CubeToken cubeToken, uint256 price);

    event AddCubeToken(
        CubeToken cubeToken,
        string spotSymbol,
        bool inverse,
        bytes32 currencyKey,
        uint256 initialSpotPrice
    );

    struct CubeTokenParams {
        bytes32 currencyKey;
        bool inverse;
        bool depositPaused;
        bool withdrawPaused;
        bool updatePaused;
        bool added; // always true
        uint256 depositWithdrawFee;
        uint256 maxPoolShare;
        uint256 initialSpotPrice;
        uint256 lastPrice;
        uint256 lastUpdated;
    }

    uint256 public constant MIN_TOTAL_EQUITY = 1000;

    ChainlinkFeedsRegistry public immutable feed;
    CubeToken public cubeTokenImpl = new CubeToken();

    mapping(CubeToken => CubeTokenParams) public params;
    mapping(string => mapping(bool => CubeToken)) public cubeTokensMap;
    CubeToken[] public cubeTokens;

    address public governance;
    address public pendingGovernance;
    address public guardian;
    uint256 public protocolFee;
    uint256 public maxPoolBalance;
    bool public finalized;

    uint256 public totalEquity;
    uint256 public accruedProtocolFees;

    /**
     * @param chainlinkFeedsRegistry The feed registry contract for fetching
     * spot prices from Chainlink oracles
     */
    constructor(address chainlinkFeedsRegistry) public {
        feed = ChainlinkFeedsRegistry(chainlinkFeedsRegistry);
        governance = msg.sender;

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
        CubeTokenParams storage _params = params[cubeToken];
        require(_params.added, "Not added");
        require(!_params.depositPaused, "Paused");
        require(msg.value > 0, "msg.value should be > 0");
        require(recipient != address(0), "Zero address");

        (uint256 price, uint256 _totalEquity) = _priceAndTotalEquity(cubeToken);
        _updatePrice(cubeToken, price);

        uint256 fees = _mulFee(msg.value, _params.depositWithdrawFee);
        uint256 ethIn = msg.value.sub(fees);
        uint256 _poolBalance = poolBalance();
        cubeTokensOut = _divPrice(ethIn, price, _totalEquity, _poolBalance.sub(msg.value));
        totalEquity = _totalEquity.add(cubeTokensOut.mul(price));

        uint256 protocolFees = _mulFee(fees, protocolFee);
        accruedProtocolFees = accruedProtocolFees.add(protocolFees);
        cubeToken.mint(recipient, cubeTokensOut);

        if (_params.maxPoolShare > 0) {
            uint256 equity = cubeToken.totalSupply().mul(price);
            require(equity.mul(1e4) <= _params.maxPoolShare.mul(totalEquity), "Max pool share exceeded");
        }

        if (maxPoolBalance > 0) {
            require(_poolBalance <= maxPoolBalance, "Max pool balance exceeded");
        }

        emit DepositOrWithdraw(cubeToken, msg.sender, recipient, true, cubeTokensOut, msg.value, protocolFees);
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
        CubeTokenParams storage _params = params[cubeToken];
        require(_params.added, "Not added");
        require(!_params.withdrawPaused, "Paused");
        require(cubeTokensIn > 0, "cubeTokensIn should be > 0");
        require(recipient != address(0), "Zero address");

        (uint256 price, uint256 _totalEquity) = _priceAndTotalEquity(cubeToken);
        _updatePrice(cubeToken, price);

        ethOut = _mulPrice(cubeTokensIn, price, _totalEquity, poolBalance());
        uint256 fees = _mulFee(ethOut, _params.depositWithdrawFee);
        ethOut = ethOut.sub(fees);

        // Make sure pool size isn't too small, otherwise there could be
        // rounding issues. Check total equity instead of pool balance since
        // pool balance is increased again by fees going back into pool.
        _totalEquity = _totalEquity.sub(cubeTokensIn.mul(price));
        require(_totalEquity >= MIN_TOTAL_EQUITY, "Min total equity exceeded");
        totalEquity = _totalEquity;

        uint256 protocolFees = _mulFee(fees, protocolFee);
        accruedProtocolFees = accruedProtocolFees.add(protocolFees);

        cubeToken.burn(msg.sender, cubeTokensIn);
        payable(recipient).transfer(ethOut);

        emit DepositOrWithdraw(cubeToken, msg.sender, recipient, false, cubeTokensIn, ethOut, protocolFees);
    }

    /**
     * @notice Update the stored cube token price and total equity. This is
     * automatically called whenever there's a deposit or withdrawal for this
     * cube token. However if this hasn't happened for a while, this method
     * should be called by an external keeper so that the total equity doesn't
     * get too far out of sync.
     */
    function update(CubeToken cubeToken) public {
        CubeTokenParams storage _params = params[cubeToken];
        require(_params.added, "Not added");

        if (!_params.updatePaused) {
            (uint256 price, uint256 _totalEquity) = _priceAndTotalEquity(cubeToken);
            _updatePrice(cubeToken, price);
            totalEquity = _totalEquity;
        }
    }

    /**
     * @dev Update `lastPrice` and `lastUpdated` in params. Should be called
     * whenever a new price is fetched from the oracle. Doesn't update if price
     * updates are paused or if price hasn't changed.
     */
    function _updatePrice(CubeToken cubeToken, uint256 price) internal {
        CubeTokenParams storage _params = params[cubeToken];
        if (!_params.updatePaused && price != _params.lastPrice) {
            _params.lastPrice = price;
            _params.lastUpdated = block.timestamp;
            emit Update(cubeToken, price);
        }
    }

    /**
     * @notice Update all cube tokens which haven't been updated in the last
     * `maxStaleTime` seconds. Should be called periodically by an external
     * keeper so that the total equity doesn't get too far out of sync.
     */
    function updateAll(uint256 maxStaleTime) external {
        for (uint256 i = 0; i < cubeTokens.length; i = i.add(1)) {
            CubeToken cubeToken = cubeTokens[i];
            if (params[cubeToken].lastUpdated.add(maxStaleTime) <= block.timestamp) {
                update(cubeToken);
            }
        }
    }

    /**
     * @notice Add a new cube token. Can only be called by governance.
     * @param spotSymbol Symbol of underlying token. Used to fetch price from oracle
     * @param inverse True means 3x short token. False means 3x long token.
     * @return address Address of cube token that was added
     */
    function addCubeToken(
        string memory spotSymbol,
        bool inverse,
        uint256 depositWithdrawFee,
        uint256 maxPoolShare
    ) external onlyGovernance returns (address) {
        require(address(cubeTokensMap[spotSymbol][inverse]) == address(0), "Already added");

        bytes32 salt = keccak256(abi.encodePacked(spotSymbol, inverse));
        CubeToken cubeToken = CubeToken(Clones.cloneDeterministic(address(cubeTokenImpl), salt));
        cubeToken.initialize(address(this), spotSymbol, inverse);

        bytes32 currencyKey = feed.stringToBytes32(spotSymbol);
        uint256 spot = feed.getPrice(currencyKey);
        require(spot > 0, "Spot price should be > 0");

        params[cubeToken] = CubeTokenParams({
            currencyKey: currencyKey,
            inverse: inverse,
            depositPaused: false,
            withdrawPaused: false,
            updatePaused: false,
            added: true,
            depositWithdrawFee: depositWithdrawFee,
            maxPoolShare: maxPoolShare,
            initialSpotPrice: spot,
            lastPrice: 0,
            lastUpdated: 0
        });
        cubeTokensMap[spotSymbol][inverse] = cubeToken;
        cubeTokens.push(cubeToken);

        // Set `lastPrice` and `lastUpdated`
        update(cubeToken);
        assert(params[cubeToken].lastPrice > 0);
        assert(params[cubeToken].lastUpdated > 0);

        emit AddCubeToken(cubeToken, spotSymbol, inverse, currencyKey, spot);
        return address(cubeToken);
    }

    /**
     * @notice Balance of ETH in this contract that belongs to cube token
     * holders. The remaining ETH are the accrued protocol fees that can be
     * collected by governance.
     */
    function poolBalance() public view returns (uint256) {
        return address(this).balance.sub(accruedProtocolFees);
    }

    /**
     * @notice Calculate price of a cube token in ETH multiplied by 1e18,
     * excluding fees. This price applies to both depositing and withdrawing.
     */
    function quote(CubeToken cubeToken) external view returns (uint256) {
        (uint256 price, uint256 _totalEquity) = _priceAndTotalEquity(cubeToken);
        return _mulPrice(1e18, price, _totalEquity, poolBalance());
    }

    /**
     * @notice Calculate amount of cube tokens received by depositing `ethIn`
     * ETH.
     */
    function quoteDeposit(CubeToken cubeToken, uint256 ethIn) external view returns (uint256) {
        (uint256 price, uint256 _totalEquity) = _priceAndTotalEquity(cubeToken);
        uint256 fees = _mulFee(ethIn, params[cubeToken].depositWithdrawFee);
        return _divPrice(ethIn.sub(fees), price, _totalEquity, poolBalance());
    }

    /**
     * @notice Calculate ETH withdrawn when burning `cubeTokensIn` cube tokens.
     */
    function quoteWithdraw(CubeToken cubeToken, uint256 cubeTokensIn) external view returns (uint256) {
        (uint256 price, uint256 _totalEquity) = _priceAndTotalEquity(cubeToken);
        uint256 ethOut = _mulPrice(cubeTokensIn, price, _totalEquity, poolBalance());
        uint256 fees = _mulFee(ethOut, params[cubeToken].depositWithdrawFee);
        return ethOut.sub(fees);
    }

    function numCubeTokens() external view returns (uint256) {
        return cubeTokens.length;
    }

    /// @dev Calculate price and total equity from latest oracle price
    function _priceAndTotalEquity(CubeToken cubeToken) internal view returns (uint256 price, uint256 _totalEquity) {
        CubeTokenParams storage _params = params[cubeToken];
        if (_params.updatePaused) {
            return (_params.lastPrice, totalEquity);
        }

        uint256 spot = feed.getPrice(_params.currencyKey);

        // Divide by the spot price at the time the cube token was added.
        // This helps the price not be too large or small which could cause
        // overflow or rounding issues.
        spot = spot.mul(1e6).div(_params.initialSpotPrice);

        // Price is spot^3 or 1/spot^3. Its value is multiplied by 1e18.
        if (_params.inverse) {
            price = uint256(1e36).div(spot).div(spot).div(spot);
        } else {
            price = spot.mul(spot).mul(spot);
        }

        // Update total equity to reflect new price. Total equity is the sum of
        // total supply * price over all cube tokens. Therefore, when the price
        // of a cube token with total supply T changes from P1 to P2, the total
        // equity needs to be increased by T * P2 - T * P1.
        _totalEquity = totalEquity;
        if (price != _params.lastPrice) {
            uint256 _totalSupply = cubeToken.totalSupply();
            uint256 equityBefore = _params.lastPrice.mul(_totalSupply);
            uint256 equityAfter = price.mul(_totalSupply);
            _totalEquity = _totalEquity.add(equityAfter).sub(equityBefore);
        }
    }

    /// @dev Multiply cube token quantity by price and normalize to get ETH cost
    function _mulPrice(
        uint256 quantity,
        uint256 price,
        uint256 _totalEquity,
        uint256 _poolBalance
    ) internal pure returns (uint256) {
        return _totalEquity > 0 ? price.mul(quantity).mul(_poolBalance).div(_totalEquity) : quantity;
    }

    /// @dev Divide ETH amount by price and normalize to get cube token quantity
    function _divPrice(
        uint256 amount,
        uint256 price,
        uint256 _totalEquity,
        uint256 _poolBalance
    ) internal pure returns (uint256) {
        return _poolBalance > 0 ? amount.mul(_totalEquity).div(price).div(_poolBalance) : amount;
    }

    /// @dev Multiply an amount by a fee rate in basis points
    function _mulFee(uint256 amount, uint256 fee) internal pure returns (uint256) {
        return amount.mul(fee).div(1e4);
    }

    /**
     * @notice Collect protocol fees accrued so far.
     */
    function collectProtocolFees() external onlyGovernance {
        payable(governance).transfer(accruedProtocolFees);
        accruedProtocolFees = 0;
    }

    /**
     * @notice Set protocol fee in basis points. This is the cut of fees that
     * go to the protocol. For example a value of 2000 means 20% of fees go to
     * the protocol and 80% go back into the pool.
     */
    function setProtocolFee(uint256 _protocolFee) external onlyGovernance {
        require(_protocolFee <= 1e4, "Protocol fee should be <= 100%");
        protocolFee = _protocolFee;
    }

    /**
     * @notice Set fee in basis points charged on each deposit and withdrawal.
     * For example a value of 150 means a 1.5% fee. Some of this fee goes to
     * the protocol while the rest goes back into the pool.
     * @dev Theoretically this fee should be at least 3x the max deviation in
     * the underlying Chainlink feed to avoid technical frontrunning.
     */
    function setDepositWithdrawFee(CubeToken cubeToken, uint256 depositWithdrawFee) external onlyGovernance {
        require(params[cubeToken].added, "Not added");
        require(depositWithdrawFee < 1e4, "Fee should be < 100%");
        params[cubeToken].depositWithdrawFee = depositWithdrawFee;
    }

    /**
     * @notice Set max pool share for a cube token. Expressed in basis points.
     * A value of 0 means no limit. This protects users from buying cube tokens
     * with limited upside, as well as protecting the whole pool from the
     * volatility of a single asset.
     */
    function setMaxPoolShare(CubeToken cubeToken, uint256 maxPoolShare) external onlyGovernance {
        require(params[cubeToken].added, "Not added");
        require(maxPoolShare < 1e4, "Max pool share should be < 100%");
        params[cubeToken].maxPoolShare = maxPoolShare;
    }

    /**
     * @notice Set max pool balance for a guarded launch. This is a limit for
     * the ETH balance deposited in the pool excluding accrued protocol fees.
     * A value of 0 means no limit.
     */
    function setMaxPoolBalance(uint256 _maxPoolBalance) external onlyGovernance {
        maxPoolBalance = _maxPoolBalance;
    }

    /**
     * @notice Governance address is not update until the new governance
     * address has called acceptGovernance() to accept this responsibility.
     */
    function setGovernance(address _governance) external onlyGovernance {
        pendingGovernance = _governance;
    }

    /**
     * @notice setGovernance() should be called by the existing governance
     * address prior to calling this function.
     */
    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "!pendingGovernance");
        governance = msg.sender;
    }

    /**
     * @notice Set guardian. This is a trusted account with the powers to pause
     * and unpause trading and to emergency withdraw. These protections are
     * needed for example to protect funds if there is an oracle mispricing.
     */
    function setGuardian(address _guardian) external onlyGovernance {
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
    ) public onlyGovernanceOrGuardian {
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
    ) external onlyGovernanceOrGuardian {
        for (uint256 i = 0; i < cubeTokens.length; i = i.add(1)) {
            setPaused(cubeTokens[i], depositPaused, withdrawPaused, updatePaused);
        }
    }

    /**
     * @notice Renounce emergency withdraw powers
     */
    function finalize() external onlyGovernance {
        require(!finalized, "Already finalized");
        finalized = true;
    }

    /**
     * @notice Transfer all ETH to governance in case of emergency. Cannot be called
     * if already finalized
     */
    function emergencyWithdraw() external onlyGovernanceOrGuardian {
        require(!finalized, "Finalized");
        payable(governance).transfer(address(this).balance);
    }

    modifier onlyGovernance {
        require(msg.sender == governance, "!governance");
        _;
    }

    modifier onlyGovernanceOrGuardian {
        require(msg.sender == governance || msg.sender == guardian, "!governance and !guardian");
        _;
    }

    receive() external payable {}
}
