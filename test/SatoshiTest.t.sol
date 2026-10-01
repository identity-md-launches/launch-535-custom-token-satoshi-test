// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {SatoshiTest} from "../src/SatoshiTest.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract SatoshiTestTest is Test {
    uint256 constant SUPPLY = 21_000_000 ether;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    SatoshiTest token;

    function setUp() public {
        vm.prank(deployer);
        token = new SatoshiTest();
    }

    // ------------------------------------------------------------------ metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "Satoshi Test");
        assertEq(token.symbol(), "SATS");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsFixedAndMintedToDeployer() public view {
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), 21_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        address other = makeAddr("other");
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), other, SUPPLY);
        vm.prank(other);
        SatoshiTest fresh = new SatoshiTest();
        assertEq(fresh.balanceOf(other), SUPPLY);
        assertEq(fresh.balanceOf(deployer), 0);
    }

    function test_supplyGoesToWhoeverDeploys_evenAContract() public {
        // The launch factory deploys through CREATE2 and must end up holding the supply.
        Deployer factory = new Deployer();
        SatoshiTest fresh = factory.deployToken(bytes32(uint256(7)));
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(address(factory)), SUPPLY);
    }

    function test_runtimeFitsEip170() public view {
        assertGt(address(token).code.length, 0);
        assertLe(address(token).code.length, 24_576);
    }

    // ------------------------------------------------------------------ transfer success paths

    function test_transfer() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5 ether));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(deployer, alice, 1 ether);
        vm.prank(deployer);
        token.transfer(alice, 1 ether);
    }

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        assertTrue(token.approve(alice, 500 ether));
        assertEq(token.allowance(deployer, alice), 500 ether);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 200 ether));
        assertEq(token.balanceOf(bob), 200 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 200 ether);
        assertEq(token.allowance(deployer, alice), 300 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_approveEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Approval(deployer, alice, 3 ether);
        vm.prank(deployer);
        token.approve(alice, 3 ether);
    }

    // ------------------------------------------------------------------ transfer failure paths

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10 ether, 10 ether + 1)
        );
        token.transfer(bob, 10 ether + 1);
    }

    function test_transferFromEmptyAccountReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
    }

    function test_transferFromWithoutAllowanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1 ether));
        token.transferFrom(deployer, bob, 1 ether);
    }

    function test_transferFromAboveAllowanceReverts() public {
        vm.prank(deployer);
        token.approve(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 1 ether, 1 ether + 1)
        );
        token.transferFrom(deployer, bob, 1 ether + 1);
    }

    function test_transferFromAboveBalanceRevertsEvenWithAllowance() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_approveZeroAddressSpenderReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ------------------------------------------------------------------ no privileged surface

    /// @dev Every common admin or mint entry point must be absent: calling it fails and supply and
    /// balances are untouched, whether the caller is a stranger or the deployer.
    function test_noMintOrAdminFunctionExists() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        address attacker = makeAddr("attacker");
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    /// @dev No pause, blacklist, freeze or seize: after the deployer tries them all, a holder still
    /// holds what it held and can still transfer.
    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, SUPPLY / 1_000);
        uint256 held = token.balanceOf(alice);

        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        vm.prank(deployer);
        vm.expectRevert();
        token.transferFrom(alice, deployer, 1);

        assertEq(token.balanceOf(alice), held);
        vm.prank(alice);
        assertTrue(token.transfer(bob, held / 2));
        assertEq(token.balanceOf(bob), held / 2);
    }

    function test_unknownSelectorAndPlainEtherAreRejected() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to) + (to == deployer ? 0 : token.balanceOf(deployer)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 funded, uint256 amount) public {
        funded = bound(funded, 0, SUPPLY - 1);
        amount = bound(amount, funded + 1, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, funded);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funded, amount));
        token.transfer(bob, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowance);
        vm.prank(alice);
        if (amount > allowance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowance, amount)
            );
            token.transferFrom(deployer, bob, amount);
        } else {
            assertTrue(token.transferFrom(deployer, bob, amount));
            assertEq(token.balanceOf(bob), amount);
            assertEq(token.allowance(deployer, alice), allowance - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_chainOfTransfersConservesSupply(uint8 hops, uint256 seed) public {
        address from = deployer;
        for (uint256 i; i < hops; ++i) {
            address to = address(uint160(uint256(keccak256(abi.encode(seed, i)))) | 1);
            uint256 amount = token.balanceOf(from) / 2;
            vm.prank(from);
            token.transfer(to, amount);
            from = to;
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ------------------------------------------------------------------ deploy script

    function test_deployScriptDeploysOneTokenToCaller() public {
        Deploy script = new Deploy();
        SatoshiTest fresh = script.deploy();
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(address(script)), SUPPLY);
        assertEq(fresh.name(), "Satoshi Test");
        assertEq(fresh.symbol(), "SATS");
    }

    function test_deployScriptChainGuard() public {
        Deploy script = new Deploy();
        script.checkChain(0, 1);
        script.checkChain(31_337, 31_337);
        script.checkChain(11_155_111, 11_155_111);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnexpectedChain.selector, 11_155_111, 31_337));
        script.checkChain(11_155_111, 31_337);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, 1));
        script.checkChain(1, 1);
    }
}

/// @dev Minimal CREATE2 deployer standing in for the launch factory.
contract Deployer {
    function deployToken(bytes32 salt) external returns (SatoshiTest) {
        return new SatoshiTest{salt: salt}();
    }
}
