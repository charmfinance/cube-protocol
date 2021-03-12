// SPDX-License-Identifier: Unlicense

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "./ChainlinkFeedsRegistry.sol";
import "./CubePool.sol";
import "./CubeToken.sol";

library CubeViews {
    using SafeMath for uint256;

    // /**
    //  * @notice Cost to mint leveraged tokens
    //  * @param lToken Leveraged token bought
    //  * @param quantity Quantity of leveraged tokens minted
    //  */
    // function mintQuote(
    //     CubePool pool,
    //     CubeToken lToken,
    //     uint256 quantity
    // ) external view returns (uint256) {
    //     uint256 cost = pool.quote(lToken, quantity).add(1);
    //     return cost.add(pool.fee(cost));
    // }

    // /**
    //  * @notice Amount received by burning leveraged tokens
    //  * @param lToken Leveraged token sold
    //  * @param quantity Quantity of leveraged tokens burned
    //  */
    // function burnQuote(
    //     CubePool pool,
    //     CubeToken lToken,
    //     uint256 quantity
    // ) external view returns (uint256) {
    //     uint256 cost = pool.quote(lToken, quantity);
    //     return cost.sub(pool.fee(cost));
    // }

    function allPrices(CubePool pool) external view returns (uint256[] memory prices) {
        uint256 n = pool.numCubeTokens();
        prices = new uint256[](n);
        for (uint256 i = 0; i < n; i = i.add(1)) {
            prices[i] = pool.getCostFromQuantity(pool.cubeTokens(i), 1e18);
        }
    }

    function allUnderlyingPrices(CubePool pool) external view returns (uint256[] memory underlyingPrices) {
        ChainlinkFeedsRegistry feedRegistry = ChainlinkFeedsRegistry(pool.feedRegistry());
        uint256 n = pool.numCubeTokens();
        underlyingPrices = new uint256[](n);
        for (uint256 i = 0; i < n; i = i.add(1)) {
            (string memory symbol, , , , , , , , , ) = pool.getParams(pool.cubeTokens(i));
            underlyingPrices[i] = feedRegistry.getPrice(symbol);
        }
    }

    function allNames(CubePool pool) external view returns (string[] memory names) {
        uint256 n = pool.numCubeTokens();
        names = new string[](n);
        for (uint256 i = 0; i < n; i = i.add(1)) {
            names[i] = CubeToken(pool.cubeTokens(i)).name();
        }
    }

    function allSymbols(CubePool pool) external view returns (string[] memory symbols) {
        uint256 n = pool.numCubeTokens();
        symbols = new string[](n);
        for (uint256 i = 0; i < n; i = i.add(1)) {
            symbols[i] = CubeToken(pool.cubeTokens(i)).symbol();
        }
    }

    function allTotalSupplies(CubePool pool) external view returns (uint256[] memory totalSupplies) {
        uint256 n = pool.numCubeTokens();
        totalSupplies = new uint256[](n);
        for (uint256 i = 0; i < n; i = i.add(1)) {
            totalSupplies[i] = CubeToken(pool.cubeTokens(i)).totalSupply();
        }
    }

    function allBalances(CubePool pool, address account) external view returns (uint256[] memory balances) {
        uint256 n = pool.numCubeTokens();
        balances = new uint256[](n);
        for (uint256 i = 0; i < n; i = i.add(1)) {
            balances[i] = CubeToken(pool.cubeTokens(i)).balanceOf(account);
        }
    }

    function allMaxPoolShares(CubePool pool) external view returns (uint256[] memory maxPoolShares) {
        uint256 n = pool.numCubeTokens();
        maxPoolShares = new uint256[](n);
        for (uint256 i = 0; i < n; i = i.add(1)) {
            (, , uint256 maxPoolShare, , , , , , , ) = pool.getParams(pool.cubeTokens(i));
            maxPoolShares[i] = maxPoolShare;
        }
    }

    // struct Params {
    //     string underlyingSymbol;
    //     CubeToken.Side side;
    //     uint256 maxPoolShare;
    //     uint256 initialPrice;
    //     uint256 lastPrice;
    //     uint256 lastUpdated;
    //     bool mintPaused;
    //     bool burnPaused;
    //     bool priceUpdatePaused;
    //     bool added; // always true - used to check existence
    // }

    // function allParams(CubePool pool) external view returns (Params[] memory params) {
    //     uint256 n = pool.numCubeTokens();
    //     params = new Params[](n);
    //     for (uint256 i = 0; i < n; i = i.add(1)) {
    //         (
    //             string memory underlyingSymbol,
    //             CubeToken.Side side,
    //             uint256 maxPoolShare,
    //             uint256 initialPrice,
    //             uint256 lastPrice,
    //             uint256 lastUpdated,
    //             bool mintPaused,
    //             bool burnPaused,
    //             bool priceUpdatePaused,
    //             bool added
    //         ) = pool.getParams(pool.cubeTokens(i));
    //         params[i] = Params(
    //             underlyingSymbol,
    //             side,
    //             maxPoolShare,
    //             initialPrice,
    //             lastPrice,
    //             lastUpdated,
    //             mintPaused,
    //             burnPaused,
    //             priceUpdatePaused,
    //             added
    //         );
    //     }
    // }

    // allPrices

    // allTotalSupplies

    // allBalances

    // allMaxBuyAmounts

    // allParams
}
