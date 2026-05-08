// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AmmoManager.sol";

contract AmmoManagerTest is Test {
    AmmoManager manager;

    address feeRecipient = address(0xFEE1);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address wavax = address(0xAA0C);

    function setUp() public {
        manager = new AmmoManager(feeRecipient, wavax);
    }

    // ── Constructor ─────────────────────────────────

    function testConstructorSetsOwnerAndDefaults() public view {
        assertEq(manager.owner(), address(this));
        assertEq(manager.feeRecipient(), feeRecipient);
        assertTrue(manager.isKeeper(address(this)));
        assertTrue(manager.isOwner(address(this)));
    }

    // ── 2-step ownership transfer ───────────────────

    function testTransferOwnership() public {
        manager.transferOwnership(alice);
        assertEq(manager.pendingOwner(), alice);
        assertEq(manager.owner(), address(this)); // not transferred yet

        vm.prank(alice);
        manager.acceptOwnership();

        assertEq(manager.owner(), alice);
        assertEq(manager.pendingOwner(), address(0));
        assertTrue(manager.isOwner(alice));
        assertFalse(manager.isOwner(address(this)));
    }

    function testAcceptOwnershipRevertsIfNotPending() public {
        manager.transferOwnership(alice);

        vm.prank(bob);
        vm.expectRevert(AmmoManager.NotPendingOwner.selector);
        manager.acceptOwnership();
    }

    // ── Keeper management ───────────────────────────

    function testSetKeeperAddsAndRemoves() public {
        assertFalse(manager.isKeeper(alice));

        manager.setKeeper(alice, true);
        assertTrue(manager.isKeeper(alice));

        manager.setKeeper(alice, false);
        assertFalse(manager.isKeeper(alice));
    }

    function testSetKeeperRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(AmmoManager.NotOwner.selector);
        manager.setKeeper(bob, true);
    }

    function testSetKeeperRevertsForZeroAddress() public {
        vm.expectRevert(AmmoManager.ZeroAddress.selector);
        manager.setKeeper(address(0), true);
    }

    // ── Guardian ────────────────────────────────────

    function testSetGuardian() public {
        assertEq(manager.guardian(), address(0));
        manager.setGuardian(alice);
        assertEq(manager.guardian(), alice);
    }

    // ── Fee recipient ───────────────────────────────

    function testSetFeeRecipient() public {
        manager.setFeeRecipient(alice);
        assertEq(manager.feeRecipient(), alice);
    }

    function testSetFeeRecipientRevertsForZero() public {
        vm.expectRevert(AmmoManager.ZeroAddress.selector);
        manager.setFeeRecipient(address(0));
    }

    // ── Treasury ─────────────────────────────────

    function testSetTreasury() public {
        assertEq(manager.treasury(), address(0));
        manager.setTreasury(alice);
        assertEq(manager.treasury(), alice);
    }

    function testSetTreasuryRevertsForZero() public {
        vm.expectRevert(AmmoManager.ZeroAddress.selector);
        manager.setTreasury(address(0));
    }

    function testSetTreasuryRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(AmmoManager.NotOwner.selector);
        manager.setTreasury(bob);
    }

    function testSetTreasuryEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit AmmoManager.TreasuryUpdated(address(0), alice);
        manager.setTreasury(alice);
    }

    // ── Denylist admin ──────────────────────────────

    function testSetDeniedAddsAndRemoves() public {
        assertFalse(manager.isDenied(alice));

        manager.setDenied(alice, true);
        assertTrue(manager.isDenied(alice));

        manager.setDenied(alice, false);
        assertFalse(manager.isDenied(alice));
    }

    function testSetDeniedRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(AmmoManager.NotOwner.selector);
        manager.setDenied(bob, true);
    }

    function testSetDeniedRevertsForZeroAddress() public {
        vm.expectRevert(AmmoManager.ZeroAddress.selector);
        manager.setDenied(address(0), true);
    }

    function testSetDeniedEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit AmmoManager.DeniedUpdated(alice, true);
        manager.setDenied(alice, true);

        vm.expectEmit(true, false, false, true);
        emit AmmoManager.DeniedUpdated(alice, false);
        manager.setDenied(alice, false);
    }
}
