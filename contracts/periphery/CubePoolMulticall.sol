// SPDX-License-Identifier: Unlicense

pragma solidity 0.6.12;

import "../CubePool.sol";
import "../CubeToken.sol";


contract CubePoolMulticall is Ownable, ReentrancyGuard {
    function allCubeTokens(CubePool pool) external view returns (CubeToken[] memory cubeTokens) {
        uint256 n = pool.numCubeTokens();
        cubeTokens = new CubeToken[](n);
        for (uint256 i = 0; i < n; i++) {
            cubeTokens[i] = pool.cubeTokens(i);
        }
    }

    function getCubeToken(CubePool pool, CubeToken cubeToken)
        external
        view
        returns (
            string memory name,
            string memory symbol,
            uint256 totalSupply,
            uint256 price,
            uint256 spotPrice,
            bool inverse,
            uint256 fee,
            uint256 maxPoolShare,
            bool depositPaused,
            bool withdrawPaused,
            bool updatePaused
        )
    {
        name = cubeToken.name();
        symbol = cubeToken.symbol();
        totalSupply = cubeToken.totalSupply();

        bytes32 currencyKey;
        (
            currencyKey,
            inverse,
            depositPaused,
            withdrawPaused,
            updatePaused,
            ,
            fee,
            maxPoolShare,
            ,
            ,
        ) = pool.params(cubeToken);

        price = pool.quote(cubeToken);
        spotPrice = pool.feedRegistry().getPrice(currencyKey);
    }
}
