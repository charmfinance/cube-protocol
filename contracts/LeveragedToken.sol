// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

import "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";

contract LeveragedToken is ERC20Upgradeable {
    address public pool;

    function initialize(
        address _pool,
        string memory name,
        string memory symbol
    ) public initializer {
        __ERC20_init(name, symbol);
        pool = _pool;
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
