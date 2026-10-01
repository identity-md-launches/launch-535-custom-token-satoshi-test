// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SatoshiTest} from "../src/SatoshiTest.sol";

/// @title Deploy script for Satoshi Test (SATS)
/// @notice Standalone deployment helper. In a custom-token launch the network's ProjectFactory
/// deploys the token itself through CREATE2 and this script is not used; it exists so the token can
/// be deployed and inspected on a local or test chain by an operator who holds the key.
/// @dev Reads no private key and no RPC secret. Its only input is `EXPECTED_CHAIN_ID`, an optional
/// guard against broadcasting to the wrong chain. Tests call `deploy()` directly and never touch
/// the environment.
contract Deploy is Script {
    /// @notice Local Anvil chain id.
    uint256 public constant ANVIL_CHAIN_ID = 31_337;
    /// @notice Sepolia, the launch target of this network.
    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;

    error UnexpectedChain(uint256 expected, uint256 actual);
    error UnsupportedChain(uint256 chainId);

    /// @notice Entry point for `forge script`. Reads `EXPECTED_CHAIN_ID` (0 or unset disables the
    /// check) and deploys exactly one token between the broadcast markers.
    function run() external returns (SatoshiTest token) {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        checkChain(expected, block.chainid);
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }

    /// @notice Refuses to proceed when the expectation is set and disagrees with the live chain, or
    /// when the expectation names a chain this project does not target.
    function checkChain(uint256 expected, uint256 actual) public pure {
        if (expected == 0) return;
        if (expected != ANVIL_CHAIN_ID && expected != SEPOLIA_CHAIN_ID) revert UnsupportedChain(expected);
        if (expected != actual) revert UnexpectedChain(expected, actual);
    }

    /// @notice Deploys the token. The caller of this function's transaction becomes the holder of
    /// the whole supply. The token has no constructor arguments.
    function deploy() public returns (SatoshiTest token) {
        token = new SatoshiTest();
    }
}
