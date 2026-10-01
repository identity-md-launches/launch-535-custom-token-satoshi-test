// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Satoshi Test (SATS)
/// @notice A plain fixed-supply ERC-20. The whole supply of 21,000,000 SATS (18 decimals) is minted
/// once to the deployer in the constructor. There is no owner, no minter, no pause, no blacklist,
/// no fee and no hook: transfers follow the unmodified OpenZeppelin ERC20 rules.
/// @dev In a custom-token launch the deployer is the ProjectFactory, which deploys this contract
/// through CREATE2 and receives the supply before distributing it. The contract exposes nothing
/// beyond the ERC-20 interface, so the supply can never grow after construction.
contract SatoshiTest is ERC20 {
    /// @notice Total and only supply ever minted, in minor units (21,000,000 * 10^18).
    uint256 public constant INITIAL_SUPPLY = 21_000_000 * 10 ** 18;

    constructor() ERC20("Satoshi Test", "SATS") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
