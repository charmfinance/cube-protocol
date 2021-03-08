// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;

import "./LToken.sol";
import "./LPool.sol";

contract LViews {
    function getLTokens(LPool lpool) external view returns (LToken[] memory ltokens) {
        uint256 n = lpool.numLTokens();
        ltokens = new LToken[](n);
        for (uint256 i = 0; i < n; i++) {
            ltokens[i] = lpool.lTokens(i);
        }
    }

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