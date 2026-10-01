// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {SatoshiTest} from "../src/SatoshiTest.sol";

/// @title Handler driving SatoshiTest with random, bounded call sequences.
/// @dev Keeps an independent model of balances and allowances (ghost state) and asserts after
/// every call that the token either did what the model says or reverted with exactly the error
/// the model predicts. Every entry point catches its own revert, so the invariant runner is
/// configured with fail-on-revert: an unexpected revert anywhere in a handler is a failure.
///
/// Actors: the deployer (holds the supply at the start) and five ordinary holders. Recipients
/// additionally include the token's own address (a sink: nothing can ever send from it) and the
/// zero address (which must always be refused).
contract SatoshiHandler is Test {
    SatoshiTest public immutable token;
    uint256 public immutable supply;

    address[] public actors;
    address public immutable deployer;
    address public immutable sink;

    // ------------------------------------------------------------------ ghost state
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    uint256 public ghostSinkHighWater; // tokens sent to the token contract never come back

    // ------------------------------------------------------------------ call accounting
    uint256 public transfersOk;
    uint256 public transfersRevertedAsPredicted;
    uint256 public transferFromsOk;
    uint256 public transferFromsRevertedAsPredicted;
    uint256 public approvalsOk;
    uint256 public approvalsRevertedAsPredicted;
    uint256 public foreignCallsRefused;

    constructor(SatoshiTest token_, address deployer_) {
        token = token_;
        supply = token_.INITIAL_SUPPLY();
        deployer = deployer_;
        sink = address(token_);

        actors.push(deployer_);
        actors.push(makeAddr("holder1"));
        actors.push(makeAddr("holder2"));
        actors.push(makeAddr("holder3"));
        actors.push(makeAddr("holder4"));
        actors.push(makeAddr("holder5"));

        ghostBalance[deployer_] = supply;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ------------------------------------------------------------------ helpers

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Recipients are the actors, the token itself and the zero address.
    function _recipient(uint256 seed) internal view returns (address) {
        uint256 i = seed % (actors.length + 2);
        if (i < actors.length) return actors[i];
        if (i == actors.length) return sink;
        return address(0);
    }

    function _recordTransfer(address from, address to, uint256 amount) internal {
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        if (to == sink && ghostBalance[sink] > ghostSinkHighWater) ghostSinkHighWater = ghostBalance[sink];
    }

    // ================================================================== unclamped (raw) layer
    // Unrestricted inputs. The outcome is compared with the model, revert reason included.

    function transfer_raw(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        address to = _recipient(toSeed);
        uint256 fromBalance = ghostBalance[from];

        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            assertTrue(ok, "transfer returned false");
            assertTrue(to != address(0), "transfer to the zero address succeeded");
            assertLe(amount, fromBalance, "transfer above balance succeeded");
            _recordTransfer(from, to, amount);
            transfersOk++;
        } catch (bytes memory reason) {
            bytes memory expected;
            if (to == address(0)) {
                expected = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
            } else {
                assertGt(amount, fromBalance, "transfer within balance reverted");
                expected =
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, fromBalance, amount);
            }
            assertEq(reason, expected, "transfer reverted with an unexpected reason");
            transfersRevertedAsPredicted++;
        }
    }

    function transferFrom_raw(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _recipient(toSeed);
        uint256 allowed = ghostAllowance[from][spender];
        uint256 fromBalance = ghostBalance[from];

        vm.prank(spender);
        try token.transferFrom(from, to, amount) returns (bool ok) {
            assertTrue(ok, "transferFrom returned false");
            assertTrue(to != address(0), "transferFrom to the zero address succeeded");
            assertLe(amount, allowed, "transferFrom above allowance succeeded");
            assertLe(amount, fromBalance, "transferFrom above balance succeeded");
            if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
            _recordTransfer(from, to, amount);
            transferFromsOk++;
        } catch (bytes memory reason) {
            // OpenZeppelin order: allowance is spent first, then the receiver is checked, then the balance.
            bytes memory expected;
            if (allowed != type(uint256).max && amount > allowed) {
                expected =
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount);
            } else if (to == address(0)) {
                expected = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
            } else {
                assertGt(amount, fromBalance, "transferFrom within allowance and balance reverted");
                expected =
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, fromBalance, amount);
            }
            assertEq(reason, expected, "transferFrom reverted with an unexpected reason");
            transferFromsRevertedAsPredicted++;
        }
    }

    function approve_raw(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        address spender = _recipient(spenderSeed); // may be the sink or the zero address

        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            assertTrue(ok, "approve returned false");
            assertTrue(spender != address(0), "approve of the zero address succeeded");
            ghostAllowance[owner][spender] = amount;
            approvalsOk++;
        } catch (bytes memory reason) {
            assertEq(spender, address(0), "approve of a non-zero spender reverted");
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)),
                "approve reverted with an unexpected reason"
            );
            approvalsRevertedAsPredicted++;
        }
    }

    // ================================================================== clamped layer
    // Inputs normalised so the call reaches the success path most of the time.

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        transfer_raw(fromSeed, toSeed % actors.length, amount);
    }

    function transferAll(uint256 fromSeed, uint256 toSeed) public {
        address from = _actor(fromSeed);
        transfer_raw(fromSeed, toSeed % actors.length, ghostBalance[from]);
    }

    function transferOneWeiAboveBalance(uint256 fromSeed, uint256 toSeed) public {
        address from = _actor(fromSeed);
        transfer_raw(fromSeed, toSeed % actors.length, ghostBalance[from] + 1);
    }

    function transferToSelf(uint256 fromSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        transfer_raw(fromSeed, fromSeed % actors.length, amount);
    }

    /// @dev Donation handler: tokens sent to the token's own address. Nothing can ever move them.
    function donateToTokenContract(uint256 fromSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        transfer_raw(fromSeed, actors.length, amount);
    }

    function approveThenTransferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        amount = bound(amount, 0, ghostBalance[owner]);
        approve_raw(ownerSeed, spenderSeed % actors.length, amount);
        transferFrom_raw(spenderSeed, ownerSeed, toSeed % actors.length, amount);
    }

    function approveMaxThenTransferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        amount = bound(amount, 0, ghostBalance[owner]);
        approve_raw(ownerSeed, spenderSeed % actors.length, type(uint256).max);
        transferFrom_raw(spenderSeed, ownerSeed, toSeed % actors.length, amount);
        assertEq(token.allowance(owner, _actor(spenderSeed)), type(uint256).max, "infinite allowance was decremented");
    }

    function transferFromWithinAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        uint256 cap = ghostAllowance[from][spender];
        if (ghostBalance[from] < cap) cap = ghostBalance[from];
        amount = bound(amount, 0, cap);
        transferFrom_raw(spenderSeed, fromSeed, toSeed % actors.length, amount);
    }

    function revokeAllowance(uint256 ownerSeed, uint256 spenderSeed) public {
        approve_raw(ownerSeed, spenderSeed % actors.length, 0);
    }

    // ================================================================== adversarial layer

    /// @dev Any selector the token does not implement must be refused by any caller, with no
    /// effect on supply or balances. Covers the mint, admin, pause, blacklist and burn names the
    /// launch floor probes, plus a random selector.
    function callForeignSelector(uint256 callerSeed, uint256 which, bytes4 randomSelector, uint256 arg) public {
        string[16] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "seize(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)",
            "increaseAllowance(address,uint256)",
            "decreaseAllowance(address,uint256)",
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)"
        ];
        address caller = _actor(callerSeed);
        address target = _actor(arg);
        bytes memory data;
        which = which % (signatures.length + 1);
        if (which == signatures.length) {
            data = abi.encodeWithSelector(randomSelector, target, arg);
            if (_isTokenSelector(randomSelector)) return;
        } else {
            data = abi.encodeWithSignature(signatures[which], target, arg);
        }

        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "a selector the token does not implement was accepted");
        foreignCallsRefused++;
    }

    /// @dev Plain ether, with or without calldata, must be refused: the token has no receive or fallback.
    function sendEther(uint256 callerSeed, uint96 amount) public {
        address caller = _actor(callerSeed);
        vm.deal(caller, amount);
        vm.prank(caller);
        (bool ok,) = address(token).call{value: amount}("");
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    function _isTokenSelector(bytes4 s) internal view returns (bool) {
        return s == IERC20.transfer.selector || s == IERC20.transferFrom.selector || s == IERC20.approve.selector
            || s == IERC20.allowance.selector || s == IERC20.balanceOf.selector || s == IERC20.totalSupply.selector
            || s == IERC20Metadata.name.selector || s == IERC20Metadata.symbol.selector
            || s == IERC20Metadata.decimals.selector || s == token.INITIAL_SUPPLY.selector;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SatoshiTestInvariantTest is Test {
    uint256 constant SUPPLY = 21_000_000 ether;

    SatoshiTest token;
    SatoshiHandler handler;
    address deployer = makeAddr("deployer");
    bytes32 runtimeHashAtDeploy;

    function setUp() public {
        vm.prank(deployer);
        token = new SatoshiTest();
        handler = new SatoshiHandler(token, deployer);
        runtimeHashAtDeploy = keccak256(address(token).code);

        targetContract(address(handler));
    }

    // ------------------------------------------------------------------ conservation

    /// @dev The supply is fixed at construction and no call sequence changes it in either direction.
    function invariant_totalSupplyIsConstant() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    /// @dev Everything the token says exists is held by someone it was sent to: the actors plus the
    /// token's own address. Nothing leaks and nothing appears.
    function invariant_balancesSumToSupply() public view {
        uint256 sum = token.balanceOf(address(token));
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply(), "sum of balances differs from the supply");
    }

    // ------------------------------------------------------------------ model agreement

    function invariant_balancesMatchModel() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            assertEq(token.balanceOf(a), handler.ghostBalance(a), "balance drifted from the model");
        }
        assertEq(token.balanceOf(address(token)), handler.ghostBalance(address(token)), "sink balance drifted");
    }

    function invariant_allowancesMatchModel() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drifted");
            }
            assertEq(token.allowance(owner, address(token)), handler.ghostAllowance(owner, address(token)));
        }
    }

    // ------------------------------------------------------------------ one-way states

    /// @dev Tokens sent to the token contract are unrecoverable: that balance never decreases.
    function invariant_tokensAtContractAddressNeverLeave() public view {
        assertEq(token.balanceOf(address(token)), handler.ghostSinkHighWater());
    }

    /// @dev Nobody outside the set of recipients ever holds anything, and the zero address holds nothing.
    function invariant_strangersHoldNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0x5712A0)), 0);
    }

    // ------------------------------------------------------------------ contract shape

    function invariant_noEtherAndRuntimeUnchanged() public view {
        assertEq(address(token).balance, 0, "the token holds ether");
        assertEq(keccak256(address(token).code), runtimeHashAtDeploy, "runtime code changed");
        assertEq(token.name(), "Satoshi Test");
        assertEq(token.symbol(), "SATS");
        assertEq(token.decimals(), 18);
    }

    /// @dev Logs what the campaign did at the end of each run, so a campaign that only ever hit
    /// revert paths would be visible in the output (run with -vv to see it).
    function afterInvariant() public {
        emit log_named_uint("transfers ok", handler.transfersOk());
        emit log_named_uint("transfers reverted as predicted", handler.transfersRevertedAsPredicted());
        emit log_named_uint("transferFroms ok", handler.transferFromsOk());
        emit log_named_uint("transferFroms reverted as predicted", handler.transferFromsRevertedAsPredicted());
        emit log_named_uint("approvals ok", handler.approvalsOk());
        emit log_named_uint("approvals reverted as predicted", handler.approvalsRevertedAsPredicted());
        emit log_named_uint("foreign calls refused", handler.foreignCallsRefused());
    }
}
