// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {SatoshiTest} from "../src/SatoshiTest.sol";

/// @title Edge cases and metamorphic properties for SatoshiTest not pinned by the main suite.
/// @dev Adversarial inputs: the maximum amount, exact-boundary allowances, the zero address on every
/// argument that can take it, a spender that is the owner, approvals that overwrite, events that must
/// and must not be emitted, and a second deployment that must not share state with the first.
/// forge-config: default.fuzz.runs = 1000
contract SatoshiTestEdgesTest is Test {
    uint256 constant SUPPLY = 21_000_000 ether;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    SatoshiTest token;

    function setUp() public {
        vm.prank(deployer);
        token = new SatoshiTest();
    }

    // ------------------------------------------------------------------ the maximum

    function test_transferMaxUintReverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
    }

    function test_transferOneWeiAboveSupplyReverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferFromMaxUintWithMaxAllowanceRevertsOnBalance() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transferFrom(deployer, bob, type(uint256).max);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_approveMaxThenSpendEntireSupplyKeepsAllowanceInfinite() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, SUPPLY));
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    // ------------------------------------------------------------------ allowance boundaries

    function test_transferFromExactAllowanceLeavesZeroAndBlocksNextWei() public {
        vm.prank(deployer);
        token.approve(alice, 7 ether);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 7 ether));
        assertEq(token.allowance(deployer, alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_maxMinusOneAllowanceIsFinite() public {
        uint256 almostInfinite = type(uint256).max - 1;
        vm.prank(deployer);
        token.approve(alice, almostInfinite);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), almostInfinite - 1);
    }

    function test_approveOverwritesInsteadOfAccumulating() public {
        vm.startPrank(deployer);
        token.approve(alice, 10 ether);
        token.approve(alice, 3 ether);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 3 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 3 ether, 3 ether + 1)
        );
        token.transferFrom(deployer, bob, 3 ether + 1);
    }

    function test_approveZeroRevokes() public {
        vm.startPrank(deployer);
        token.approve(alice, 10 ether);
        token.approve(alice, 0);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_allowanceIsPerSpender() public {
        vm.prank(deployer);
        token.approve(alice, 5 ether);
        assertEq(token.allowance(deployer, bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(deployer, carol, 1);
    }

    function test_allowanceIsDirectional() public {
        vm.prank(deployer);
        token.approve(alice, 5 ether);
        // alice approving deployer is a different entry; deployer may not spend alice's (empty) balance.
        assertEq(token.allowance(alice, deployer), 0);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    /// @dev OpenZeppelin does not special-case the owner as spender: transferFrom(self) needs a self-approval.
    function test_ownerCannotTransferFromSelfWithoutSelfApproval() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);

        vm.startPrank(deployer);
        token.approve(deployer, 1);
        assertTrue(token.transferFrom(deployer, alice, 1));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.allowance(deployer, deployer), 0);
    }

    function test_allowanceCheckedBeforeBalance() public {
        // alice holds nothing and approved bob nothing: the allowance error wins over the balance error.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    // ------------------------------------------------------------------ the zero address everywhere

    function test_transferFromToZeroAddressRevertsEvenWithAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1 ether);
        assertEq(token.allowance(deployer, alice), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromZeroAddressRevertsOnAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), bob, 1);
    }

    function test_transferZeroToZeroAddressStillReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_approveZeroAmountToZeroAddressStillReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
    }

    function test_zeroAddressHoldsNothingAndCannotBeCreditedByAnyPath() public view {
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(address(0), deployer), 0);
        assertEq(token.allowance(deployer, address(0)), 0);
    }

    // ------------------------------------------------------------------ events

    function test_transferFromEmitsTransferAndNoApproval() public {
        vm.prank(deployer);
        token.approve(alice, 2 ether);

        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "transferFrom must emit exactly one event");
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), deployer);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), bob);
        assertEq(abi.decode(logs[0].data, (uint256)), 1 ether);
    }

    function test_zeroValueTransferEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        token.transfer(bob, 0);
    }

    function test_revertedTransferEmitsNothing() public {
        vm.recordLogs();
        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.transfer, (bob, 1)));
        assertFalse(ok);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // ------------------------------------------------------------------ the contract's own address

    /// @dev Tokens sent to the token contract are stuck: there is no rescue path and the contract
    /// never calls transfer on itself. Documented behaviour, pinned here so a rescue function added
    /// later (a privileged balance move) would surface.
    function test_tokensSentToContractAreUnrecoverable() public {
        vm.prank(deployer);
        token.transfer(address(token), 1 ether);
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);

        (bool ok,) = address(token).call(abi.encodeWithSignature("rescue(address,uint256)", deployer, 1 ether));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("recoverERC20(address,uint256)", address(token), 1 ether));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("withdraw(uint256)", 1 ether));
        assertFalse(ok);
        assertEq(token.balanceOf(address(token)), 1 ether);
    }

    // ------------------------------------------------------------------ independence of deployments

    function test_secondDeploymentIsIndependent() public {
        vm.prank(deployer);
        SatoshiTest second = new SatoshiTest();
        assertTrue(address(second) != address(token));
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(second.balanceOf(deployer), SUPPLY);

        vm.prank(deployer);
        token.transfer(alice, 1 ether);
        assertEq(second.balanceOf(alice), 0);
        assertEq(second.balanceOf(deployer), SUPPLY);

        vm.prank(deployer);
        token.approve(alice, 5 ether);
        assertEq(second.allowance(deployer, alice), 0);
    }

    function test_metadataThroughStandardInterface() public view {
        IERC20Metadata m = IERC20Metadata(address(token));
        assertEq(m.name(), "Satoshi Test");
        assertEq(m.symbol(), "SATS");
        assertEq(m.decimals(), 18);
        assertEq(IERC20(address(token)).totalSupply(), 21_000_000 * 10 ** uint256(m.decimals()));
    }

    // ------------------------------------------------------------------ fuzzed properties

    /// @dev Every address but the deployer starts empty; the deployer starts with everything.
    function testFuzz_initialDistributionIsAllOrNothing(address who) public view {
        if (who == deployer) assertEq(token.balanceOf(who), SUPPLY);
        else assertEq(token.balanceOf(who), 0);
    }

    /// @dev Round trip: sending an amount away and back restores both balances exactly.
    function testFuzz_transferRoundTrip(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Metamorphic: two transfers of a and b leave the same state as one transfer of a + b,
    /// checked on two independent deployments rather than against re-derived arithmetic.
    function testFuzz_splitTransferEqualsSingleTransfer(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);

        vm.prank(deployer);
        SatoshiTest other = new SatoshiTest();

        vm.startPrank(deployer);
        token.transfer(alice, a);
        token.transfer(alice, b);
        other.transfer(alice, a + b);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), other.balanceOf(alice));
        assertEq(token.balanceOf(deployer), other.balanceOf(deployer));
        assertEq(token.totalSupply(), other.totalSupply());
    }

    /// @dev transferFrom and transfer of the same amount agree on balances; the only difference is
    /// the allowance consumed.
    function testFuzz_transferFromAgreesWithTransfer(uint256 amount, uint256 allowance) public {
        amount = bound(amount, 0, SUPPLY);
        allowance = bound(allowance, amount, type(uint256).max);

        vm.prank(deployer);
        SatoshiTest other = new SatoshiTest();

        vm.prank(deployer);
        token.transfer(bob, amount);

        vm.prank(deployer);
        other.approve(alice, allowance);
        vm.prank(alice);
        other.transferFrom(deployer, bob, amount);

        assertEq(token.balanceOf(bob), other.balanceOf(bob));
        assertEq(token.balanceOf(deployer), other.balanceOf(deployer));
        uint256 expectedLeft = allowance == type(uint256).max ? type(uint256).max : allowance - amount;
        assertEq(other.allowance(deployer, alice), expectedLeft);
    }

    /// @dev Any spender with an infinite allowance may move anything up to the balance and never
    /// consumes the allowance; one wei more than the balance reverts on balance, not allowance.
    function testFuzz_infiniteAllowanceAnySpender(address spender, uint256 amount) public {
        vm.assume(spender != address(0));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);

        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, amount));
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), amount);

        uint256 left = SUPPLY - amount;
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, left, left + 1)
        );
        token.transferFrom(deployer, alice, left + 1);
    }

    /// @dev A reverted call changes nothing: balances, allowance and supply are exactly as before.
    function testFuzz_failedTransferFromLeavesStateUntouched(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, SUPPLY - 1);
        amount = bound(amount, allowance + 1, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowance);

        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.transferFrom, (deployer, bob, amount)));
        assertFalse(ok);

        assertEq(token.allowance(deployer, alice), allowance);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Any number of approvals, of any size, from anyone, never moves a token.
    function testFuzz_approvalsNeverMoveTokens(address owner, address spender, uint256 amount) public {
        vm.assume(spender != address(0));
        vm.prank(owner);
        if (owner == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
            token.approve(spender, amount);
            assertEq(token.allowance(owner, spender), 0);
        } else {
            assertTrue(token.approve(spender, amount));
            assertEq(token.allowance(owner, spender), amount);
        }
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(spender), spender == deployer ? SUPPLY : 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
