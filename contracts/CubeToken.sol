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
    enum Side {Long, Short}

    address public cubePool;
    string public underlyingSymbol;
    Side public side;

    /**
     * @dev Initialize the contract. Should be called exactly once immediately after deployment
     * @param _cubePool The `CubePool` contract that deployed this contract
     * @param _underlyingSymbol Symbol of underying ERC20 token
     * @param _side Whether long or short
     */
    function initialize(
        address _cubePool,
        string memory _underlyingSymbol,
        Side _side
    ) external initializer {
        bool long = _side == Side.Long;
        string memory name =
            string(abi.encodePacked(_underlyingSymbol, (long ? " Cube Token" : " Inverse Cube Token")));
        string memory symbol = string(abi.encodePacked((long ? "cube" : "inv"), _underlyingSymbol));
        __ERC20_init(name, symbol);

        cubePool = _cubePool;
        underlyingSymbol = _underlyingSymbol;
        side = _side;
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
