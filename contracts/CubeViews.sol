// SPDX-License-Identifier: Unlicense

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "./CubeToken.sol";
import "./CubePool.sol";

contract CubeViews {
    using SafeMath for uint256;

    // /**
    //  * @notice Cost to buy leveraged tokens
    //  * @param lToken Leveraged token bought
    //  * @param quantity Quantity of leveraged tokens bought
    //  */
    // function buyQuote(
    //     CubePool pool,
    //     CubeToken lToken,
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
    //     CubePool pool,
    //     CubeToken lToken,
    //     uint256 quantity
    // ) external view returns (uint256) {
    //     uint256 cost = pool.quote(lToken, quantity);
    //     return cost.sub(pool.fee(cost));
    // }

    // function allPrices(CubePool pool) external view returns (uint256[] memory prices) {
    //     uint256 n = pool.numCubeTokens();
    //     prices = new uint256[](n);
    //     for (uint256 i = 0; i < n; i++) {
    //         prices[i] = pool.quote(pool.cubeTokens(i), 1e18);
    //     }
    // }

    function allNames(CubePool pool) external view returns (string[] memory names) {
        uint256 n = pool.numCubeTokens();
        names = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            names[i] = CubeToken(pool.cubeTokens(i)).name();
        }
    }

    function allSymbols(CubePool pool) external view returns (string[] memory symbols) {
        uint256 n = pool.numCubeTokens();
        symbols = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            symbols[i] = CubeToken(pool.cubeTokens(i)).symbol();
        }
    }

    function allTotalSupplies(CubePool pool) external view returns (uint256[] memory totalSupplies) {
        uint256 n = pool.numCubeTokens();
        totalSupplies = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            totalSupplies[i] = CubeToken(pool.cubeTokens(i)).totalSupply();
        }
    }

    function allBalances(CubePool pool, address account) external view returns (uint256[] memory balances) {
        uint256 n = pool.numCubeTokens();
        balances = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            balances[i] = CubeToken(pool.cubeTokens(i)).balanceOf(account);
        }
    }

    // allPrices

    // allTotalSupplies

    // allBalances

    // allMaxBuyAmounts

    // allParams

    // move belwo to periphery
    // function getLeveragedTokenPrice(address token, Side side) external view returns (uint256) {
    //     uint256 price = getSquarePrice(cubeToken.token(), cubeToken.side());
    //     return price.div(totalValue);
    // }

    // function getLeveragedTokenPrices() external view returns (uint256[] prices) {
    //     uint256 n = leveragedTokens.length;
    //     prices = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         CubeToken cubeToken = leveragedTokens[i];
    //         prices[i] = getLeveragedTokenPrice(cubeToken.token(), cubeToken.side());
    //     }
    // }

    // function getLeveragedTokenValues() public view returns (uint256 values) {
    //     uint256 n = leveragedTokens.length;
    //     values = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         CubeToken cubeToken = leveragedTokens[i];
    //         values[i] = getLeveragedTokenPrices(cubeToken).mul(cubeToken.totalSupply());
    //     }
    // }

    // function getAccountValues(CubeToken cubeToken, address account) external view returns (uint256 values) {
    //     uint256 n = leveragedTokens.length;
    //     values = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         values[i] = getLeveragedTokenPrices(cubeToken).mul(cubeToken.balanceOf(account));
    //     }
    // }

    // TODO: splti into 2 methods
    // function getMaxDepositAmounts() external view returns (uint256[] amounts) {
    //     uint256 n = leveragedTokens.length;
    //     amounts = new uint256[n];
    //     for (uint256 i = 0; i < n; i++) {
    //         uint256 maxAmount1 = maxTvl.sub(getBalance());
    //         uint256 maxAmount2 = maxPoolShare.mul(totalValue).sub(getLeveragedTokenValue(cubeToken));
    //         amounts[i] = Math.min(maxAmount1, maxAmount2);
    //     }
    // }
}
