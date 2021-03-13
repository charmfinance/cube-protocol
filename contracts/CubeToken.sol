// SPDX-License-Identifier: Unlicense

pragma solidity 0.6.12;

import "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";

/**
 * @title Cube Token
 * @notice ERC20 token representing a cube token which can be minted from or
 * redeemed to its `CubePool` for a certain price
 * @dev This contract extends OpenZeppelin's ERC20 contract and allows the
 * `cubePool` to call `mint()` and `burn()`, which mint and burn tokens from any
 * account. `cubePool` is intended to be the `CubePool` contract that deployed this
 * contract.
 */
contract CubeToken is ERC20Upgradeable {
    address public cubePool;
    string public spotSymbol;
    bool public inverse;

    /**
     * @dev Initialize the contract. Should be called exactly once immediately after deployment
     * @param _cubePool The `CubePool` contract that deployed this contract
     * @param _spotSymbol Symbol of underying ERC20 token
     * @param _inverse Whether long or short
     */
    function initialize(
        address _cubePool,
        string memory _spotSymbol,
        bool _inverse
    ) external initializer {
        string memory name = string(abi.encodePacked("Charm 3X ", _inverse ? "Short " : "Long ", _spotSymbol));
        string memory symbol = string(abi.encodePacked(_inverse ? "inv" : "cube", _spotSymbol));
        __ERC20_init(name, symbol);

        cubePool = _cubePool;
        spotSymbol = _spotSymbol;
        inverse = _inverse;
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
     * @param account The account whose tokens are burned
     * @param amount The amount of tokens to burn
     */
    function burn(address account, uint256 amount) external {
        require(msg.sender == cubePool, "!cubePool");
        _burn(account, amount);
    }
}
