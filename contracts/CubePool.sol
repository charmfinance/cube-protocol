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
 * @notice  This pool lets users mint cube tokens by depositing ETH and
 *          burn them to withdraw ETH. Cube tokens are 3x leveraged tokens
 *          whose theoretical price is roughly proportional to the cube of the
 *          underlying price. Inverse tokens are roughly proportional to the
 *          reciprocal of the cube price.
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
        uint256 ethAmount
    );
    event Update(CubeToken cubeToken, uint256 price);
    event AddCubeToken(CubeToken cubeToken, string spotSymbol, bool inverse);

    struct Params {
        string spotSymbol;
        bool inverse;
        uint256 maxPoolShare;
        uint256 initialSpotPrice;
        uint256 lastPrice;
        uint256 lastUpdated;
        bool depositPaused;
        bool withdrawPaused;
        bool updatePaused;
        bool added; // always true
    }

    ChainlinkFeedsRegistry public feedRegistry;
    CubeToken public cubeTokenImpl = new CubeToken();

    mapping(CubeToken => Params) public params;
    mapping(string => mapping(bool => CubeToken)) public cubeTokensMap;
    CubeToken[] public cubeTokens;

    address public guardian;
    uint256 public tradingFee;
    uint256 public maxTvl;
    bool public finalized;

    // total value is always equal to sum of totalSupply * price over all cube tokens
    uint256 public totalValue;

    // pool balance is ETH balance of this contract minus trading fees accrued so far
    uint256 public poolBalance;

    /**
     * @param _feedRegistry The feed registry contract for
     * fetching spot prices from Chainlink oracles
     */
    constructor(address _feedRegistry) public {
        feedRegistry = ChainlinkFeedsRegistry(_feedRegistry);

        // initialize with dummy data so that it can't be initialized again
        cubeTokenImpl.initialize(address(0), "", false);
    }

    /**
     * @notice Deposit ETH and mint cube tokens
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

        (uint256 price, uint256 _totalValue) = _updatedPriceAndTotalValue(cubeToken);
        _updatePrice(cubeToken, price);

        uint256 ethIn = _subtractFee(msg.value);
        cubeTokensOut = poolBalance > 0 ? ethIn.mul(_totalValue).div(price).div(poolBalance) : ethIn;
        poolBalance = poolBalance.add(ethIn);
        totalValue = _totalValue.add(cubeTokensOut.mul(price));
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

        (uint256 price, uint256 _totalValue) = _updatedPriceAndTotalValue(cubeToken);
        _updatePrice(cubeToken, price);

        ethOut = _totalValue > 0 ? price.mul(cubeTokensIn).mul(poolBalance).div(_totalValue) : cubeTokensIn;
        poolBalance = poolBalance.sub(ethOut);
        totalValue = _totalValue.sub(cubeTokensIn.mul(price));
        cubeToken.burn(msg.sender, cubeTokensIn);

        ethOut = _subtractFee(ethOut);
        payable(to).transfer(ethOut);

        emit DepositOrWithdraw(msg.sender, to, cubeToken, false, cubeTokensIn, ethOut);
    }

    /**
     * @notice Update the stored cube token price and total value. This is
     * automatically called when the cube token is minted or burned. However
     * if it has not been traded for a while, it should be called periodically
     * so that the total value does get too far out of sync
     * @param cubeToken Cube token whose price is updated
     */
    function update(CubeToken cubeToken) public {
        Params storage _params = params[cubeToken];
        require(_params.added, "Not added");

        if (!_params.updatePaused) {
            (uint256 price, uint256 _totalValue) = _updatedPriceAndTotalValue(cubeToken);
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

        params[cubeToken] = Params({
            added: true,
            spotSymbol: spotSymbol,
            inverse: inverse,
            maxPoolShare: 0,
            depositPaused: false,
            withdrawPaused: false,
            updatePaused: false,
            initialSpotPrice: 0,
            lastPrice: 0,
            lastUpdated: 0
        });
        cubeTokensMap[spotSymbol][inverse] = cubeToken;
        cubeTokens.push(cubeToken);

        uint256 spot = feedRegistry.getPrice(spotSymbol);
        require(spot > 0, "Spot price should be > 0");

        params[cubeToken].initialSpotPrice = spot;
        update(cubeToken);

        emit AddCubeToken(cubeToken, spotSymbol, inverse);
        return instance;
    }

    function quote(CubeToken cubeToken, uint256 quantity) public view returns (uint256) {
        (uint256 price, uint256 _totalValue) = _updatedPriceAndTotalValue(cubeToken);
        return _totalValue > 0 ? price.mul(quantity).mul(poolBalance).div(_totalValue) : quantity;
    }

    function quoteDeposit(CubeToken cubeToken, uint256 ethIn) external view returns (uint256) {
        ethIn = _subtractFee(ethIn);
        (uint256 price, uint256 _totalValue) = _updatedPriceAndTotalValue(cubeToken);
        return poolBalance > 0 ? ethIn.mul(_totalValue).div(price).div(poolBalance) : ethIn;
    }

    function quoteWithdraw(CubeToken cubeToken, uint256 quantityIn) external view returns (uint256) {
        return _subtractFee(quote(cubeToken, quantityIn));
    }

    function numCubeTokens() external view returns (uint256) {
        return cubeTokens.length;
    }

    function _updatedPriceAndTotalValue(CubeToken cubeToken)
        internal
        view
        returns (uint256 price, uint256 _totalValue)
    {
        Params storage _params = params[cubeToken];
        if (_params.updatePaused) {
            return (_params.lastPrice, totalValue);
        }

        uint256 spot = feedRegistry.getPrice(_params.spotSymbol);
        spot = spot.mul(1e6).div(_params.initialSpotPrice);
        if (_params.inverse) {
            // 1 / spot ^ 3
            price = uint256(1e36).div(spot).div(spot).div(spot);
        } else {
            // spot ^ 3
            price = spot.mul(spot).mul(spot);
        }

        uint256 _totalSupply = cubeToken.totalSupply();
        uint256 valueBefore = _params.lastPrice.mul(_totalSupply);
        uint256 valueAfter = price.mul(_totalSupply);
        _totalValue = totalValue.add(valueAfter).sub(valueBefore);
    }

    function _subtractFee(uint256 amount) internal view returns (uint256) {
        uint256 fee = amount.mul(tradingFee).div(1e4); // round down fee amount
        return amount.sub(fee);
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
     * @notice Update max pool share for token. Expressed in basis points.
     * Setting to 0 means no limit. This protects users from buying cube tokens
     * with limited upside, as well as protecting the whole pool from the
     * volatility of a single asset.
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
     * @notice Transfer all ETH to owner in case of emergency
     */
    function emergencyWithdraw() external {
        require(msg.sender == owner() || msg.sender == guardian, "Must be owner or guardian");
        require(!finalized, "Finalized");
        payable(owner()).transfer(address(this).balance);
    }
}
