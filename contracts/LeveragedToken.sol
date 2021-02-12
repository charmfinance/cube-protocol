// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./LeveragedTokenPool.sol";

contract LeveragedToken is ERC20 {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public pool;
    IERC20 public token;
    LeveragedTokenPool.Side public side;

    constructor(
        address _pool,
        address _token,
        LeveragedTokenPool.Side _side,
        string memory name,
        string memory symbol
    )
        ERC20(name, symbol)
    {
        pool = _pool;
        token = IERC20(token);
        side = side;
    }

    function mint(address account, uint256 amount) external {
        require(msg.sender == pool, "!pool");
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        require(msg.sender == pool, "!pool");
        _burn(account, amount);
    }
}
