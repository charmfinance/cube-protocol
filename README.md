# Cube tokens

Decentralized leveraged tokens.

Cube tokens such as cubeBTC approximately track `P ^ 3`, while
inverse cube tokens such as invBTC approximately track `1 / P ^ 3`, where `P` is
the price of BTC.

Users can deposit ETH into a pool to mint cube tokens and later burn them to
withdraw their ETH. If BTC goes up by 1%, cubeBTC's share of the pool will go
up by around 3% and invBTC's pool share will go down by 3%. The pool shares are
then normalized to sum to 100%.


### Governance and guardian privileges

There are two privileged accounts for each pool: governance and a guardian.

The **governance** account can:

- Change max pool share of each cube token

- Change TVL cap

- Collect fees that have accrued

- Change trading fee

Both **governance** and the **guardian** can:

- Emergency withdraw all ETH from the contract to the owner. This power can later be
  revoked if the owner calls `finalize()`. This is intended to be used in the
  case of a bug to rescue funds.

- Pause and unpause deposits, withdrawals and price updates for any cube token.
  This is intended to be used in the case of a bug or oracle failure.


### Repo

`CubePool.sol` is a pool containing deposited ETH. Users can deposit ETH to
mint cube tokens and later burn them to withdraw their ETH.

`CubeToken.sol` is an ERC20 token representing a cube token. It's deployed
from the `CubePool` when a new cube token is added. 

`ChainlinkFeedsRegistry.sol` is a contract containing a mapping from tokens
to their Chainlink price feed.


### Usage

Run below as a workaround for [this bug in brownie](https://github.com/eth-brownie/brownie/issues/893)
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

Run keeper script. You need to set up a brownie account and set environment
variables `KEEPER_ACCOUNT`, `KEEPER_PW` and `WEB3_INFURA_PROJECT_ID`
```
brownie run keep
```

Deploy
```
brownie run deploy
```
