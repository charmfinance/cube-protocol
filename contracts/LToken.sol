// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;

import "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";

/**
 * @title Leveraged Token
 * @notice ERC20 token representing a leveraged token
 * @dev This contract extends OpenZeppelin's ERC20 contract and allows the
 * `lpool` to call `mint()` and `burn()`, which mint and burn tokens from any
 * account. `lpool` is intended to be the `LPool` contract that deployed this
 * contract.
 */
contract LToken is ERC20Upgradeable {
    address public lpool;

    /**
     * @dev Initialize the contract. Should be called exactly once immediately after deployment
     * @param _lpool The `LPool` contract that deployed this contract
     * @param name The name of this token
     * @param symbol The symbol of this token
     */
    function initialize(
        address _lpool,
        string memory name,
        string memory symbol
    ) public initializer {
        __ERC20_init(name, symbol);
        lpool = _lpool;
    }

    /**
     * @dev Mint tokens. Can only be called by `lpool`
     * @param account The account that receives the tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address account, uint256 amount) external {
        require(msg.sender == lpool, "!lpool");
        _mint(account, amount);
    }

    /**
     * @dev Burn tokens. Can only be called by `lpool`
     * @param account The account that loses the tokens
     * @param amount The amount of tokens to burn
     */
    function burn(address account, uint256 amount) external {
        require(msg.sender == lpool, "!lpool");
        _burn(account, amount);
    }
}
