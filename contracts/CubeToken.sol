// SPDX-License-Identifier: Unlicense

pragma solidity 0.6.12;

import "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";

/**
 * @title   Cube Token
 * @notice  ERC20 token representing share of a cube token pool. The pool share
 *          will be adjusted by the pool continuously as the price of the
 *          underlying asset changes.
 * @dev     This contract extends OpenZeppelin's ERC20 token contract with two
 *          modifications. Firstly it derives its name and symbol from the
 *          constructor parameters. Secondly it allows the parent pool to mint
 *          and burn tokens.
 */
contract CubeToken is ERC20Upgradeable {
    address public cubePool;
    string public spotSymbol;
    bool public inverse;

    /**
     * @dev Initialize the contract. Should be called exactly once immediately
     * after deployment. `_spotSymbol` and `_inverse` are stored for so that
     * they can be read conveniently.
     * @param _cubePool Address of CubePool contract which can mint and burn
     * cube tokens.
     * @param _spotSymbol Symbol of underying ERC20 token.
     * @param _inverse True means 3x short token. False means 3x long token.
     */
    function initialize(
        address _cubePool,
        string memory _spotSymbol,
        bool _inverse
    ) external initializer {
        // Example name: Charm 3X Long BTC
        // Example symbol: cubeBTC
        string memory name = string(abi.encodePacked("Charm 3X ", _inverse ? "Short " : "Long ", _spotSymbol));
        string memory symbol = string(abi.encodePacked(_inverse ? "inv" : "cube", _spotSymbol));
        __ERC20_init(name, symbol);

        cubePool = _cubePool;
        spotSymbol = _spotSymbol;
        inverse = _inverse;
    }

    function mint(address account, uint256 amount) external {
        require(msg.sender == cubePool, "!cubePool");
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        require(msg.sender == cubePool, "!cubePool");
        _burn(account, amount);
    }
}
