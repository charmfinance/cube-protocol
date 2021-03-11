// SPDX-License-Identifier: Unlicense

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "./LToken.sol";
import "./LPool.sol";

contract LViews {
    using SafeMath for uint256;

    // /**
    //  * @notice Cost to buy leveraged tokens
    //  * @param lToken Leveraged token bought
    //  * @param quantity Quantity of leveraged tokens bought
    //  */
    // function buyQuote(
    //     LPool pool,
    //     LToken lToken,
    //     uint256 quantity
    // ) external view returns (uint256) {
    //     uint256 cost = pool.quote(lToken, quantity).add(1);
    //     return cost.add(pool.fee(cost));
    // }

    // /**
    //  * @notice Amount received by selling leveraged tokens
    //  * @param lToken Leveraged token sold
    //  * @param quantity Quantity of leveraged tokens sold
    //  */
    // function sellQuote(
    //     LPool pool,
    //     LToken lToken,
    //     uint256 quantity
    // ) external view returns (uint256) {
    //     uint256 cost = pool.quote(lToken, quantity);
    //     return cost.sub(pool.fee(cost));
    // }

    // function allPrices(LPool pool) external view returns (uint256[] memory prices) {
    //     uint256 n = pool.numLTokens();
    //     prices = new uint256[](n);
    //     for (uint256 i = 0; i < n; i++) {
    //         prices[i] = pool.quote(pool.lTokens(i), 1e18);
    //     }
    // }

    function allNames(LPool pool) external view returns (string[] memory names) {
        uint256 n = pool.numLTokens();
        names = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            names[i] = LToken(pool.lTokens(i)).name();
        }
    }

    function allSymbols(LPool pool) external view returns (string[] memory symbols) {
        uint256 n = pool.numLTokens();
        symbols = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            symbols[i] = LToken(pool.lTokens(i)).symbol();
        }
    }

    function allTotalSupplies(LPool pool) external view returns (uint256[] memory totalSupplies) {
        uint256 n = pool.numLTokens();
        totalSupplies = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            totalSupplies[i] = LToken(pool.lTokens(i)).totalSupply();
        }
    }

    function allBalances(LPool pool, address account) external view returns (uint256[] memory balances) {
        uint256 n = pool.numLTokens();
        balances = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            balances[i] = LToken(pool.lTokens(i)).balanceOf(account);
        }
    }

    // allPrices

    // allTotalSupplies

    // allBalances

    // allMaxBuyAmounts

    // allParams

    // move belwo to periphery
    // function getLeveragedTokenPrice(address token, Side side) external view returns (uint256) {
    //     uint256 price = getSquarePrice(ltoken.token(), ltoken.side());
    //     return price.div(totalValue);
    // }

    // function getLeveragedTokenPrices() external view returns (uint256[] prices) {
    //     uint256 n = leveragedTokens.length;
    //     prices = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         LToken ltoken = leveragedTokens[i];
    //         prices[i] = getLeveragedTokenPrice(ltoken.token(), ltoken.side());
    //     }
    // }

    // function getLeveragedTokenValues() public view returns (uint256 values) {
    //     uint256 n = leveragedTokens.length;
    //     values = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         LToken ltoken = leveragedTokens[i];
    //         values[i] = getLeveragedTokenPrices(ltoken).mul(ltoken.totalSupply());
    //     }
    // }

    // function getAccountValues(LToken ltoken, address account) external view returns (uint256 values) {
    //     uint256 n = leveragedTokens.length;
    //     values = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         values[i] = getLeveragedTokenPrices(ltoken).mul(ltoken.balanceOf(account));
    //     }
    // }

    // TODO: splti into 2 methods
    // function getMaxDepositAmounts() external view returns (uint256[] amounts) {
    //     uint256 n = leveragedTokens.length;
    //     amounts = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         uint256 maxAmount1 = maxTvl.sub(getBalance());
    //         uint256 maxAmount2 = maxPoolShare.mul(totalValue).sub(getLeveragedTokenValue(ltoken));
    //         amounts[i] = Math.min(maxAmount1, maxAmount2);
    //     }
    // }
}
