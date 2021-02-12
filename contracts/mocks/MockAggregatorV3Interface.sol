// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

import "../../interfaces/AggregatorV3Interface.sol";

contract MockAggregatorV3Interface is AggregatorV3Interface {
    uint8 internal _decimals;
    int256 internal _price;

    function decimals() external override view returns (uint8) {
        return _decimals;
    }

    function getRoundData(uint80 _roundId)
        external
        override
        view
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        )
    {}

    function latestRoundData()
        external
        override
        view
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        )
    {
        return (0, _price, 0, 0, 0);
    }

    function description() external override view returns (string memory) {
        return "";
    }

    function version() external override view returns (uint256) {
        return 0;
    }

    function setDecimals(uint8 d) external {
        _decimals = d;
    }

    function setPrice(int256 price) external {
        _price = price;
    }
}
