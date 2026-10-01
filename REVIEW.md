# Review: Satoshi Test (SATS)

Scope: `src/SatoshiTest.sol`, `script/Deploy.s.sol`, `test/SatoshiTest.t.sol`, `foundry.toml`,
`remappings.txt`, the vendored files under `lib/`. Checked against the brief (fixed supply of
21,000,000 × 10^18 minted once to the deployer, no transfer rules), the custom-token launch floor
(`Token.protected.t.sol`) and the eth-security checklist supplied with the task.

## What was re-run

| Command | Result |
| --- | --- |
| `forge build --offline` | 28 files compiled with solc 0.8.26, no warnings |
| `forge test --offline` | 30 passed, 0 failed (4 fuzz tests at 256 runs each) |
| `forge fmt --check` | clean |
| `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline` | ran, one deployment |
| `EXPECTED_CHAIN_ID=31337 forge script …` | ran, one deployment |
| `EXPECTED_CHAIN_ID=11155111 forge script …` (on the local 31337 fork) | reverted `UnexpectedChain(11155111, 31337)` as intended |

Tooling: Foundry 1.8.3 only. Slither and Mythril are not available in this environment and did not
run. The protected floor test cannot be run here as-is because it depends on the factory
repository's `LaunchLiquidity`, `PoolInitializationGuard` and `HookFlags`; its checks on the token
itself were mirrored in the delivered suite (see below).

## Floor checks mirrored in the test suite

| Floor requirement | Delivered test |
| --- | --- |
| Supply equals the manifest and is minted to the factory (`msg.sender`) | `test_supplyIsFixedAndMintedToDeployer`, `test_supplyGoesToWhoeverDeploys_evenAContract` (CREATE2 deployer) |
| Decimals match | `test_metadata` |
| Swarm share and claims arrive whole | `test_transfer`, `test_transferWholeBalance`, `testFuzz_transferConservesSupply`, `testFuzz_chainOfTransfersConservesSupply` |
| No common admin call increases supply (same 10 selectors) | `test_noMintOrAdminFunctionExists` |
| No privileged hand moves or freezes a holder (same 12 selectors + `transferFrom`) | `test_noPrivilegedCallMovesOrFreezesAHolder` |
| Runtime has no DELEGATECALL / CALLCODE / SELFDESTRUCT | `test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct` |
| Runtime within EIP-170 | `test_runtimeFitsEip170` |

The seed-and-swap floor test exercises the PoolManager; the token has no transfer hooks or
exemptions, so it moves exactly the requested amount in both directions and nothing in it is
address-dependent.

## Checklist findings

| # | Item | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | Reentrancy | No external calls in the token; OZ `ERC20` has none. | No issue |
| 2 | Access control | No privileged functions exist. The contract's only non-ERC-20 member is a `constant`. | No issue; documented as "nothing to administer" |
| 3 | Integer overflow | Solidity 0.8 checked arithmetic; OZ `_update` uses `unchecked` only where the prior check guarantees safety. | No issue |
| 4 | Unchecked return values | `transfer`/`transferFrom` return `true` or revert; never `false`. The floor's `assertTrue` on these holds. | No issue |
| 5 | Front-running / approve race | Standard `approve` semantics; no `increaseAllowance` in OZ v5. Holders should set allowances to 0 before changing them if they care about the race. | Accepted, inherent to ERC-20, documented here |
| 6 | Pausable / upgradeability | None requested, none implemented; no proxy, no `initialize`. | No issue |
| 7 | Timestamp / randomness | Not used. | N/A |
| 8 | Compiler pin | `solc = "0.8.26"` exact; files use `pragma solidity 0.8.26`; vendored OZ files are `^0.8.20` / `>=0.8.4` / `>=0.6.2` / `>=0.4.16` and compile under it. `bytecode_hash = "none"` so the creation code is deterministic for attestation. | No issue |
| 9 | Dependencies | OZ v5.7.0 subset and forge-std 1.16.2 copied as plain files; no submodule, no remote import. | No issue |
| 10 | Deploy script secrets | Script reads only `EXPECTED_CHAIN_ID`; no key, no RPC. `vm.startBroadcast()` with no argument uses the operator's own signer. | No issue |
| 11 | Tokens stuck at the contract address | Any ERC-20 without a rescue path has this property; a rescue function would be a privileged balance move, which the floor refuses. | Accepted, documented in README |
| 12 | Test isolation | No `vm.env*` or `vm.setEnv` in tests; deployer is a `makeAddr` prank, not the test contract or script caller. | No issue |

## Open items for the deployer

- Explorer verification after deployment with the pinned settings (0.8.26, optimizer 200 runs,
  paris, `bytecode_hash = none`).
- The manifest must state `totalSupply = 21000000000000000000000000`, `decimals = 18`,
  `constructorArgs = []`. This project does not write the manifest.

## Residual risk

Tests passing are not an audit. The custom code is a two-line constructor over an audited library;
the residual risk is in the launch economics and in the library version, not in token logic.
