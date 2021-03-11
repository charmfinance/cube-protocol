// SPDX-License-Identifier: Unlicense

pragma solidity 0.6.11;

import "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";

/**
 * @title Leveraged Token
 * @notice ERC20 token representing a leveraged token
 * @dev This contract extends OpenZeppelin's ERC20 contract and allows the
 * `cubePool` to call `mint()` and `burn()`, which mint and burn tokens from any
 * account. `cubePool` is intended to be the `CubePool` contract that deployed this
 * contract.
 */
contract CubeToken is ERC20Upgradeable {
    address public cubePool;

    /**
     * @dev Initialize the contract. Should be called exactly once immediately after deployment
     * @param _cubePool The `CubePool` contract that deployed this contract
     * @param _name The name of this token
     * @param _symbol The symbol of this token
     */
    function initialize(
        address _cubePool,
        string memory _name,
        string memory _symbol
    ) external initializer {
        __ERC20_init(_name, _symbol);
        cubePool = _cubePool;
    }

    /**
     * @dev Mint tokens. Can only be called by `cubePool`
     * @param account The account that receives the tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address account, uint256 amount) external {
        require(msg.sender == cubePool, "!cubePool");
        _mint(account, amount);
    }

    /**
     * @dev Burn tokens. Can only be called by `cubePool`
     * @param account The account that loses the tokens
     * @param amount The amount of tokens to burn
     */
    function burn(address account, uint256 amount) external {
        require(msg.sender == cubePool, "!cubePool");
        _burn(account, amount);
    }
}
