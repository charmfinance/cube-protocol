// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./LeveragedToken.sol";
import "./Oracle.sol";


// TODO
// - add more view methods like pricing, tvl per pool, value of position etc





contract LeveragedTokenPool is Ownable, ReentrancyGuard, Oracle {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    enum Side { Long, Short }

    struct Params {
        bool added;
        LeveragedToken ltoken;
        uint256 maxPoolShare;
        bool depositPaused;
        bool withdrawPaused;
        uint256 depositFee;
        uint256 lastPrice;
    }

    IERC20 baseToken;
    mapping(address => mapping(Side => Params)) public params;
    LeveragedToken[] public leveragedTokens;
    uint256 public totalValue;
    uint256 public feeEarned;
    uint256 public maxTvl;

    constructor (address _baseToken) {
        baseToken = IERC20(_baseToken);
    }

    function deposit(address token, Side side, uint256 amount, address to) external nonReentrant returns (uint256 shares) {
        require(side == Side.Short || side == Side.Long, "Invalid side");

        Params storage _params = params[token][side];
        require(_params.added, "Token not added");
        require(!_params.depositPaused, "Paused");

        baseToken.transferFrom(msg.sender, address(this), amount);

        uint256 fee = amount.mul(_params.depositFee).div(1e4);
        feeEarned = feeEarned.add(fee);

        uint256 price = updatePrice(token, side);
        shares = _calcSharesFromAmount(price, amount.sub(fee));
        totalValue = totalValue.add(shares.mul(price));

        LeveragedToken ltoken = _params.ltoken;
        ltoken.mint(to, shares);

        uint256 maxPoolShare = _params.maxPoolShare;
        require(maxPoolShare == 0 || ltoken.totalSupply().mul(price) < maxPoolShare.mul(totalValue), "Max pool share exceeded");
        require(maxTvl == 0 || getBalance() < maxTvl, "Max TVL exceeded");
    }

    function withdraw(address token, Side side, uint256 amount, address to) external nonReentrant returns (uint256 shares) {
        require(side == Side.Short || side == Side.Long, "Invalid side");

        Params storage _params = params[token][side];
        require(_params.added, "Token not added");
        require(!_params.withdrawPaused, "Paused");

        uint256 price = updatePrice(token, side);

        if (amount == 0) {
            shares = _params.ltoken.balanceOf(msg.sender);
        } else {
            shares = _calcSharesFromAmount(price, amount);
        }

        _params.ltoken.burn(msg.sender, shares);
        baseToken.transfer(to, amount);
        totalValue = totalValue.sub(shares.mul(price));
    }

    function _calcSharesFromAmount(uint256 price, uint256 amount) internal view returns (uint256) {
        uint256 balance = getBalance();
        if (balance == 0) {
            return amount;
        }
        return amount.mul(totalValue).div(price).div(balance);
    }

    function getUnnormalizedPrice(address token, Side side) public view returns (uint256) {
        uint256 price = getTokenPrice(token);
        uint256 squarePrice = price.mul(price);
        return side == Side.Short ? uint256(1e36).div(squarePrice) : squarePrice;
    }

    function updatePrice(address token, Side side) public returns (uint256 price) {
        Params storage _params = params[token][side];
        uint256 lastPrice = _params.lastPrice;

        uint256 _totalSupply = _params.ltoken.totalSupply();
        price = getUnnormalizedPrice(token, side);

        totalValue = totalValue.sub(_params.lastPrice.mul(_totalSupply));
        totalValue = totalValue.add(price.mul(_totalSupply));
        _params.lastPrice = price;
    }

    function updateAllPrices() external {
        for (uint256 i = 0; i < leveragedTokens.length; i++) {
            LeveragedToken ltoken = leveragedTokens[i];
            updatePrice(ltoken.token(), ltoken.side());
        }
    }

    function addLeveragedToken(address token, Side side) external onlyOwner {
        require(side == Side.Short || side == Side.Long, "Invalid side");
        require(!params[token][side].added, "Already added");

        string memory name = string(
            abi.encodePacked(
                "Charm 2X ",
                (side == Side.Long ? "Long " : "Short "),
                ERC20(token).name()
            )
        );

        string memory symbol = string(
            abi.encodePacked(
                "charm",
                ERC20(token).symbol(),
                (side == Side.Long ? "BULL" : "BEAR")
            )
        );

        LeveragedToken ltoken = new LeveragedToken(address(this), token, side, name, symbol);
        params[token][side] = Params({
            added: true,
            ltoken: ltoken,
            maxPoolShare: 0,
            depositPaused: true,
            withdrawPaused: true,
            depositFee: 0,
            lastPrice: 0
        });
        leveragedTokens.push(ltoken);
    }

    function getBalance() public view returns (uint256) {
        return baseToken.balanceOf(address(this)).sub(feeEarned);
    }

    function numLeveragedTokens() external view returns (uint256) {
        return leveragedTokens.length;
    }




    // move belwo to periphery
    // function getLeveragedTokenPrice(address token, Side side) external view returns (uint256) {
    //     uint256 price = getUnnormalizedPrice(ltoken.token(), ltoken.side());
    //     return price.div(totalValue);
    // }

    // function getLeveragedTokenPrices() external view returns (uint256[] prices) {
    //     uint256 n = leveragedTokens.length;
    //     prices = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         LeveragedToken ltoken = leveragedTokens[i];
    //         prices[i] = getLeveragedTokenPrice(ltoken.token(), ltoken.side());
    //     }
    // }

    // function getLeveragedTokenValues() public view returns (uint256 values) {
    //     uint256 n = leveragedTokens.length;
    //     values = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         LeveragedToken ltoken = leveragedTokens[i];
    //         values[i] = getLeveragedTokenPrices(ltoken).mul(ltoken.totalSupply());
    //     }
    // }

    // function getAccountValues(LeveragedToken ltoken, address account) external view returns (uint256 values) {
    //     uint256 n = leveragedTokens.length;
    //     values = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         values[i] = getLeveragedTokenPrices(ltoken).mul(ltoken.balanceOf(account));
    //     }
    // }

    // function getMaxDepositAmounts() external view returns (uint256[] amounts) {
    //     uint256 n = leveragedTokens.length;
    //     amounts = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         uint256 maxAmount1 = maxTvl.sub(getBalance());
    //         uint256 maxAmount2 = maxPoolShare.mul(totalValue).sub(getLeveragedTokenValue(ltoken));
    //         amounts[i] = Math.min(maxAmount1, maxAmount2);
    //     }
    // }



    // function setDepositPaused(uint256 index, bool isPaused) external onlyOwner {
    //     isDepositPaused[index] = isPaused;
    // }

    // function setWithdrawPaused(uint256 index, bool isPaused) external onlyOwner {
    //     isWithdrawPaused[index] = isPaused;
    // }

    // function updateFee(uint256 _fee) external onlyOwner {
    //     fee = _fee;
    // }

    // function collectFee() external onlyOwner {
    //     require(owner.send(feeEarned));
    //     feeEarned = 0;
    // }
}
