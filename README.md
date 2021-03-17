# Cube tokens

An implementation of decentralized leveraged tokens.

Implemements a parimutuel pool where users can deposit ETH to mint cube tokens
and burn them to withdraw ETH. The cube token represents a share of the pool
and the share percentage is adjusted by the pool continuously as the price of
the underlying asset changes.

Cube tokens such as cubeBTC approximately track `BTC price ^ 3`, while
inverse cube tokens such as invBTC approximately track `1 / BTC price ^ 3`.

This code isn't ready. Please do not use in production.


### Owner and guardian privileges

There are two privileged accounts for each pool: an owner and a guardian.

The **owner** can:

- Change max pool share of each cube token

- Change TVL cap

- Collect fees that have accrued

- Change trading fee

Both the **owner** and the **guardian** can:

- Emergency withdraw all ETH from the contract. This power can later be
  revoked if the owner calls `finalize()`

- Pause and unpause deposits, withdrawals and price updates for any cube token


### Repo

`CubePool.sol` is the pool containing deposited ETH. Users can deposit and
withdraw ETH from it to mint and burn cube tokens.

`CubeToken.sol` is the ERC20 token representing a cube token.

`ChainlinkFeedsRegistry.sol` is a contract containing a mapping from tokens
to their Chainlink price feed.


### Usage

Before installing, run below as a workaround for [this bug in brownie](https://github.com/eth-brownie/brownie/issues/893)
```
brownie pm clone OpenZeppelin/openzeppelin-contracts-upgradeable@3.4.0
```

Run solidity linter
```
npm run lint:fix
```

Run python formatter for unit tests
```
black .
```

Run unit tests
```
brownie test
```

Run keeper script
```
brownie run keep
```

Deploy
```
brownie run deploy
```
