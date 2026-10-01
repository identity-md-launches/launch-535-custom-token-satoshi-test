# Satoshi Test (SATS)

A plain fixed-supply ERC-20 token with no transfer rules.

| Parameter | Value |
| --- | --- |
| Name | `Satoshi Test` |
| Symbol | `SATS` |
| Decimals | 18 |
| Total supply | 21,000,000 SATS = `21000000000000000000000000` minor units |
| Minted to | `msg.sender` of the constructor, once, in the constructor |
| Constructor arguments | none |
| Owner / minter / pauser | none |
| Transfer fee, burn, blacklist, hooks | none |
| Contract | `src/SatoshiTest.sol` (`SatoshiTest`) |

## Rules

- The constructor mints the whole supply to the deployer and emits one `Transfer(0x0, deployer, supply)`.
- After construction the contract exposes only the ERC-20 interface (`name`, `symbol`, `decimals`,
  `totalSupply`, `balanceOf`, `transfer`, `approve`, `allowance`, `transferFrom`) plus the constant
  `INITIAL_SUPPLY`. There is no `mint`, `burn`, `pause`, `blacklist`, owner, upgrade path, `receive` or
  `fallback`.
- The supply can never grow. It can never shrink either: there is no burn function, and the base ERC-20
  refuses transfers to the zero address.
- Transfers follow the unmodified OpenZeppelin v5 `ERC20` rules: a transfer of more than the sender's
  balance reverts with `ERC20InsufficientBalance`, a `transferFrom` above the allowance reverts with
  `ERC20InsufficientAllowance`, the zero address is refused as receiver and spender, and an allowance of
  `type(uint256).max` is never decremented.
- The runtime code contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, and is well under the
  EIP-170 size limit.

## Launch flows

In a custom-token launch the network's ProjectFactory deploys the token through CREATE2 and so becomes
`msg.sender` of the constructor and the holder of the whole supply. Because every transfer moves exactly
the amount asked for, the factory's transfer to the MerkleDistributor, the distributor's claim transfers,
the single-sided pool seed through the Uniswap v4 PoolManager and every later buy or sell move whole
amounts. The token does not need, and does not take, the factory, pool manager or launch number as
constructor arguments: there is nothing to exempt.

Manifest values for this token:

- `decimals`: `18`
- `totalSupply`: `21000000000000000000000000`
- `constructorArgs`: `[]`

## Dependencies

Vendored as ordinary files under `lib/`, no git submodules, no network needed to build:

- `lib/openzeppelin-contracts` — the `ERC20`, `IERC20`, `IERC20Metadata`, `IERC6093` and `Context`
  files from OpenZeppelin Contracts v5.7.0 (MIT, licence file included).
- `lib/forge-std` — forge-std 1.16.2 (`src/` only, MIT/Apache-2.0).

Remappings are in `remappings.txt`.

## Build and test (offline)

Compiler is pinned to `solc = "0.8.26"` in `foundry.toml`, with `optimizer = true`, `optimizer_runs = 200`,
`evm_version = "paris"`, `bytecode_hash = "none"`, `ffi = false` and no filesystem permissions.

```sh
forge build --offline
forge test --offline
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
```

Tests read no environment variables and do not depend on the calling address, so they pass in any
order and in parallel.

## Deployment

The launch factory deploys this token; the script below is a standalone helper for an operator who
wants the same token on a local chain or on Sepolia outside a launch.

`script/Deploy.s.sol` holds no key and no RPC URL. It reads one optional variable, `EXPECTED_CHAIN_ID`:
when set to a non-zero value it must equal the connected chain and must be `31337` (Anvil) or
`11155111` (Sepolia), otherwise the script reverts before broadcasting. Exactly one contract is deployed
between the broadcast markers. The account that signs the transaction receives the entire supply.

Operator-only command (the signer and RPC are supplied by the operator's own environment, never by
this repository):

```sh
EXPECTED_CHAIN_ID=11155111 forge script script/Deploy.s.sol:Deploy --rpc-url <sepolia-rpc> --broadcast
```

## Operational responsibilities

- Whoever deploys holds 100% of the supply at the moment of construction. In a launch that is the
  factory, which distributes it by its own rules; in a standalone deployment it is the signer, who is
  responsible for distribution.
- There is nothing to administer afterwards: no keys to rotate, no roles to hand to a multisig, no
  pause to lift. Losing the deployer key loses only the deployer's own balance.
- Explorer verification of the deployed bytecode (`forge verify-contract` with the pinned compiler
  settings) is the deployer's step after deployment.

## Assumptions

- "Deployer" means the `msg.sender` of the constructor, which for a factory deployment is the factory.
- "No transfer rules" means the stock OpenZeppelin behaviour: no fee, no tax, no max wallet, no
  cooldown, no exemptions. The zero-address and balance/allowance reverts are standard ERC-20
  safety checks, not transfer rules.
- Tokens sent to the contract's own address are stuck, as with any ERC-20 without a rescue function.
  A rescue function would be a privileged hand on balances, which the brief excludes.

See `REVIEW.md` for the independent review notes and what was re-run.
