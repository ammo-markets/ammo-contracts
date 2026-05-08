// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AmmoManager.sol";
import "../src/AmmoMarketLPFarm.sol";
import "./MockERC20.sol";
import "./MockEmissionController.sol";

contract AmmoMarketLPFarmTest is Test {
    AmmoManager manager;
    AmmoMarketLPFarm farm;
    MockEmissionController emissionController;
    MockERC20 reward;
    MockERC20 lp9mm;
    MockERC20 lp556;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address feeRecipient = address(0xFEE1);
    address wavax = address(0xAA0C);

    uint256 startTime = 1_000;
    uint256 duration = 10 days;
    uint256 startRewardPerDay = 1_000e18;

    bytes32 constant CALIBER_9MM = keccak256("9mm");
    bytes32 constant CALIBER_556 = keccak256("556");

    function setUp() public {
        manager = new AmmoManager(feeRecipient, wavax);
        reward = new MockERC20("Ammo Reward", "AMMO", 18);
        emissionController = new MockEmissionController(address(reward));
        lp9mm = new MockERC20("9mm LP", "9MM-LP", 18);
        lp556 = new MockERC20("556 LP", "556-LP", 18);

        farm = new AmmoMarketLPFarm(
            address(manager), address(emissionController), address(reward), duration, startRewardPerDay, 10_000e18
        );

        lp9mm.mint(alice, 100e18);
        lp9mm.mint(bob, 100e18);
        lp556.mint(alice, 100e18);
        lp556.mint(bob, 100e18);

        vm.startPrank(alice);
        lp9mm.approve(address(farm), type(uint256).max);
        lp556.approve(address(farm), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        lp9mm.approve(address(farm), type(uint256).max);
        lp556.approve(address(farm), type(uint256).max);
        vm.stopPrank();

        vm.warp(startTime);
    }

    function _add9mmPool() internal {
        farm.addPool(CALIBER_9MM, address(lp9mm));
    }

    function _addTwoPools() internal {
        farm.addPool(CALIBER_9MM, address(lp9mm));
        farm.addPool(CALIBER_556, address(lp556));
    }

    function _deposit(address account, uint256 pid, uint256 amount) internal {
        vm.prank(account);
        farm.deposit(pid, amount);
    }

    function _cappedFarm(uint256 cap) internal returns (AmmoMarketLPFarm lowCapFarm) {
        lowCapFarm = new AmmoMarketLPFarm(
            address(manager), address(emissionController), address(reward), duration, startRewardPerDay, cap
        );

        vm.prank(alice);
        lp9mm.approve(address(lowCapFarm), type(uint256).max);

        lowCapFarm.addPool(CALIBER_9MM, address(lp9mm));
    }

    function testTotalProgramRewardsIsTriangularEmission() public view {
        assertEq(farm.totalProgramRewards(), 5_000e18);
    }

    function testSplitsEmissionEquallyBetweenPools() public {
        _addTwoPools();
        _deposit(alice, 0, 10e18);
        _deposit(bob, 1, 10e18);

        vm.warp(startTime + 1 days);

        assertEq(farm.pendingRewards(0, alice), 475e18);
        assertEq(farm.pendingRewards(1, bob), 475e18);
    }

    function testDistributesPoolShareProRataToStakers() public {
        _add9mmPool();
        _deposit(alice, 0, 30e18);
        _deposit(bob, 0, 10e18);

        vm.warp(startTime + 1 days);

        assertEq(farm.pendingRewards(0, alice), 712.5e18);
        assertEq(farm.pendingRewards(0, bob), 237.5e18);
    }

    function testAddingPoolDoesNotRepricePastEmissions() public {
        _add9mmPool();
        _deposit(alice, 0, 10e18);

        vm.warp(startTime + 1 days);
        farm.addPool(CALIBER_556, address(lp556));

        assertEq(farm.pendingRewards(0, alice), 950e18);

        _deposit(bob, 1, 10e18);

        vm.warp(startTime + 2 days);

        assertEq(farm.pendingRewards(0, alice), 1_375e18);
        assertEq(farm.pendingRewards(1, bob), 425e18);
    }

    function testEmptyAddedPoolDoesNotDiluteExistingStakers() public {
        _add9mmPool();
        _deposit(alice, 0, 10e18);

        vm.warp(startTime + 1 days);
        farm.addPool(CALIBER_556, address(lp556));

        vm.warp(startTime + 2 days);

        assertEq(farm.pendingRewards(0, alice), 1_800e18);
        assertEq(farm.pendingRewards(1, bob), 0);
        assertEq(farm.rewardablePoolCount(), 1);
    }

    function testFirstDepositToNewPoolStartsSharingFutureEmissionsOnly() public {
        _add9mmPool();
        _deposit(alice, 0, 10e18);

        vm.warp(startTime + 1 days);
        farm.addPool(CALIBER_556, address(lp556));

        vm.warp(startTime + 2 days);
        _deposit(bob, 1, 10e18);

        assertEq(farm.pendingRewards(0, alice), 1_800e18);
        assertEq(farm.pendingRewards(1, bob), 0);
        assertEq(farm.rewardablePoolCount(), 2);

        vm.warp(startTime + 3 days);

        assertEq(farm.pendingRewards(0, alice), 2_175e18);
        assertEq(farm.pendingRewards(1, bob), 375e18);
    }

    function testHarvestTransfersRewards() public {
        _add9mmPool();
        _deposit(alice, 0, 10e18);

        vm.warp(startTime + 1 days);

        vm.prank(alice);
        farm.harvest(0);

        assertEq(reward.balanceOf(alice), 950e18);
        assertEq(farm.pendingRewards(0, alice), 0);
    }

    function testInactivePoolStopsEarningButAllowsWithdraw() public {
        _add9mmPool();
        _deposit(alice, 0, 10e18);

        vm.warp(startTime + 1 days);
        farm.setPoolActive(0, false);
        vm.warp(startTime + 2 days);

        assertEq(farm.pendingRewards(0, alice), 950e18);

        vm.prank(alice);
        farm.withdraw(0, 10e18);

        assertEq(lp9mm.balanceOf(alice), 100e18);
        assertEq(reward.balanceOf(alice), 950e18);
    }

    function testCannotDepositInactivePool() public {
        _add9mmPool();
        farm.setPoolActive(0, false);

        vm.prank(alice);
        vm.expectRevert(AmmoMarketLPFarm.PoolInactive.selector);
        farm.deposit(0, 10e18);
    }

    function testDuplicatePoolRejected() public {
        _add9mmPool();

        vm.expectRevert(AmmoMarketLPFarm.DuplicatePool.selector);
        farm.addPool(CALIBER_556, address(lp9mm));
    }

    function testRewardTokenCannotBeAddedAsPool() public {
        vm.expectRevert(AmmoMarketLPFarm.InvalidPool.selector);
        farm.addPool(CALIBER_9MM, address(reward));
    }

    function testStaggeredDepositsAndPartialWithdrawKeepRewardDebtConsistent() public {
        _add9mmPool();
        _deposit(alice, 0, 30e18);

        vm.warp(startTime + 1 days);
        _deposit(bob, 0, 10e18);

        vm.warp(startTime + 2 days);

        assertApproxEqAbs(farm.pendingRewards(0, alice), 1_587.5e18, 100);
        assertApproxEqAbs(farm.pendingRewards(0, bob), 212.5e18, 100);

        vm.prank(alice);
        farm.withdraw(0, 15e18);

        assertApproxEqAbs(reward.balanceOf(alice), 1_587.5e18, 100);
        assertApproxEqAbs(farm.pendingRewards(0, bob), 212.5e18, 100);

        vm.warp(startTime + 3 days);

        assertEq(farm.pendingRewards(0, alice), 450e18);
        assertApproxEqAbs(farm.pendingRewards(0, bob), 512.5e18, 100);
    }

    function testReactivatedPoolDoesNotBackpayInactivePeriod() public {
        _add9mmPool();
        _deposit(alice, 0, 10e18);

        vm.warp(startTime + 1 days);
        farm.setPoolActive(0, false);

        assertEq(farm.pendingRewards(0, alice), 950e18);
        assertEq(farm.rewardablePoolCount(), 0);

        vm.warp(startTime + 2 days);
        farm.setPoolActive(0, true);

        assertEq(farm.pendingRewards(0, alice), 950e18);
        assertEq(farm.rewardablePoolCount(), 1);

        vm.warp(startTime + 3 days);

        assertEq(farm.pendingRewards(0, alice), 1_700e18);
    }

    function testFirstStakeStartsScheduleWithoutBackpay() public {
        _add9mmPool();

        vm.warp(startTime + 1 days);
        _deposit(alice, 0, 10e18);

        assertTrue(farm.farmingStarted());
        assertEq(farm.startTime(), startTime + 1 days);
        assertEq(farm.endTime(), startTime + 1 days + duration);

        vm.warp(startTime + 2 days);

        assertEq(farm.pendingRewards(0, alice), 950e18);
    }

    function testFinalWithdrawRemovesPoolFromFutureRewardSharing() public {
        _addTwoPools();
        _deposit(alice, 0, 10e18);
        _deposit(bob, 1, 10e18);

        vm.warp(startTime + 1 days);

        vm.prank(alice);
        farm.withdraw(0, 10e18);

        assertEq(reward.balanceOf(alice), 475e18);
        assertEq(farm.rewardablePoolCount(), 1);

        vm.warp(startTime + 2 days);

        assertEq(farm.pendingRewards(1, bob), 1_325e18);
    }

    function testEmergencyWithdrawLastStakeRemovesPoolFromFutureRewardSharing() public {
        _addTwoPools();
        _deposit(alice, 0, 10e18);
        _deposit(bob, 1, 10e18);

        vm.warp(startTime + 1 days);

        vm.prank(alice);
        farm.emergencyWithdraw(0);

        assertEq(reward.balanceOf(alice), 0);
        assertEq(farm.rewardablePoolCount(), 1);

        vm.warp(startTime + 2 days);

        assertEq(farm.pendingRewards(1, bob), 1_325e18);
    }

    function testScheduleBoundariesCapRewards() public {
        _add9mmPool();
        _deposit(alice, 0, 10e18);

        vm.warp(startTime - 1);
        assertEq(farm.pendingRewards(0, alice), 0);

        vm.warp(startTime + duration + 30 days);
        assertEq(farm.pendingRewards(0, alice), 5_000e18);

        vm.prank(alice);
        farm.harvest(0);

        assertEq(reward.balanceOf(alice), 5_000e18);

        vm.warp(startTime + duration + 60 days);
        assertEq(farm.pendingRewards(0, alice), 0);
    }

    function testDepositZeroHarvestsPendingRewards() public {
        _add9mmPool();
        _deposit(alice, 0, 10e18);

        vm.warp(startTime + 1 days);
        _deposit(alice, 0, 0);

        assertEq(reward.balanceOf(alice), 950e18);
        assertEq(farm.pendingRewards(0, alice), 0);
    }

    function testEmergencyWithdrawForfeitsCallerRewardsWithoutOverpayingRemainingStaker() public {
        _add9mmPool();
        _deposit(alice, 0, 10e18);
        _deposit(bob, 0, 10e18);

        vm.warp(startTime + 1 days);

        vm.prank(alice);
        farm.emergencyWithdraw(0);

        assertEq(lp9mm.balanceOf(alice), 100e18);
        assertEq(reward.balanceOf(alice), 0);
        assertEq(farm.pendingRewards(0, bob), 475e18);
        assertEq(reward.totalSupply(), 0);

        vm.prank(bob);
        farm.harvest(0);

        assertEq(reward.balanceOf(bob), 475e18);
        assertEq(reward.totalSupply(), 475e18);
    }

    function testFarmCapStopsNewAccrual() public {
        AmmoMarketLPFarm lowCapFarm = _cappedFarm(500e18);

        vm.prank(alice);
        lowCapFarm.deposit(0, 10e18);

        vm.warp(startTime + 1 days);

        assertEq(lowCapFarm.pendingRewards(0, alice), 500e18);
        assertEq(lowCapFarm.totalFarmAccrued(), 0);

        lowCapFarm.updatePool(0);

        assertEq(lowCapFarm.totalFarmAccrued(), 500e18);
        assertEq(lowCapFarm.pendingRewards(0, alice), 500e18);
    }

    function testDisablingOneOfTwoPoolsGivesRemainingPoolFullEmissionUntilReactivation() public {
        _addTwoPools();
        _deposit(alice, 0, 10e18);
        _deposit(bob, 1, 10e18);

        vm.warp(startTime + 1 days);
        farm.setPoolActive(0, false);

        assertEq(farm.pendingRewards(0, alice), 475e18);
        assertEq(farm.pendingRewards(1, bob), 475e18);
        assertEq(farm.rewardablePoolCount(), 1);

        vm.warp(startTime + 2 days);

        assertEq(farm.pendingRewards(0, alice), 475e18);
        assertEq(farm.pendingRewards(1, bob), 1_325e18);

        farm.setPoolActive(0, true);

        assertEq(farm.pendingRewards(0, alice), 475e18);
        assertEq(farm.pendingRewards(1, bob), 1_325e18);
        assertEq(farm.rewardablePoolCount(), 2);

        vm.warp(startTime + 3 days);

        assertEq(farm.pendingRewards(0, alice), 850e18);
        assertEq(farm.pendingRewards(1, bob), 1_700e18);
    }

    function testZeroDepositDoesNotStartFarm() public {
        AmmoMarketLPFarm lowCapFarm = _cappedFarm(1e18);

        vm.prank(alice);
        vm.expectRevert(AmmoMarketLPFarm.InvalidAmount.selector);
        lowCapFarm.deposit(0, 0);

        assertFalse(lowCapFarm.farmingStarted());
    }

    function testConstructorRejectsZeroAddressesAndInvalidSchedule() public {
        vm.expectRevert(AmmoMarketLPFarm.ZeroAddress.selector);
        new AmmoMarketLPFarm(
            address(0), address(emissionController), address(reward), duration, startRewardPerDay, 10_000e18
        );

        vm.expectRevert(AmmoMarketLPFarm.ZeroAddress.selector);
        new AmmoMarketLPFarm(address(manager), address(0), address(reward), duration, startRewardPerDay, 10_000e18);

        vm.expectRevert(AmmoMarketLPFarm.ZeroAddress.selector);
        new AmmoMarketLPFarm(
            address(manager), address(emissionController), address(0), duration, startRewardPerDay, 10_000e18
        );

        vm.expectRevert(AmmoMarketLPFarm.InvalidTime.selector);
        new AmmoMarketLPFarm(
            address(manager), address(emissionController), address(reward), 0, startRewardPerDay, 10_000e18
        );

        vm.expectRevert(AmmoMarketLPFarm.InvalidTime.selector);
        new AmmoMarketLPFarm(address(manager), address(emissionController), address(reward), duration, 0, 10_000e18);

        vm.expectRevert(AmmoMarketLPFarm.InvalidTime.selector);
        new AmmoMarketLPFarm(
            address(manager), address(emissionController), address(reward), duration, startRewardPerDay, 0
        );
    }

    function testRejectsInvalidAmountsAndZeroRecoveryAddresses() public {
        _add9mmPool();

        vm.expectRevert(AmmoMarketLPFarm.ZeroAddress.selector);
        farm.addPool(CALIBER_556, address(0));

        vm.prank(alice);
        vm.expectRevert(AmmoMarketLPFarm.InvalidAmount.selector);
        farm.withdraw(0, 1);

        MockERC20 junk = new MockERC20("Junk", "JUNK", 18);

        vm.expectRevert(AmmoMarketLPFarm.ZeroAddress.selector);
        farm.recoverToken(address(0), bob, 1);

        vm.expectRevert(AmmoMarketLPFarm.ZeroAddress.selector);
        farm.recoverToken(address(junk), address(0), 1);
    }

    function testInvalidPoolIdsRevertForPublicEntrypoints() public {
        vm.expectRevert(AmmoMarketLPFarm.InvalidPool.selector);
        farm.setPoolActive(0, false);

        vm.expectRevert(AmmoMarketLPFarm.InvalidPool.selector);
        farm.updatePool(0);

        vm.expectRevert(AmmoMarketLPFarm.InvalidPool.selector);
        farm.pendingRewards(0, alice);

        vm.prank(alice);
        vm.expectRevert(AmmoMarketLPFarm.InvalidPool.selector);
        farm.deposit(0, 1);

        vm.prank(alice);
        vm.expectRevert(AmmoMarketLPFarm.InvalidPool.selector);
        farm.withdraw(0, 1);

        vm.prank(alice);
        vm.expectRevert(AmmoMarketLPFarm.InvalidPool.selector);
        farm.harvest(0);

        vm.prank(alice);
        vm.expectRevert(AmmoMarketLPFarm.InvalidPool.selector);
        farm.emergencyWithdraw(0);
    }

    function testRoundingDustDoesNotOverpayEmittedRewards() public {
        _add9mmPool();
        _deposit(alice, 0, 1);
        _deposit(bob, 0, 2);

        vm.warp(startTime + 1 days);

        vm.prank(alice);
        farm.harvest(0);
        vm.prank(bob);
        farm.harvest(0);

        uint256 paid = reward.balanceOf(alice) + reward.balanceOf(bob);
        uint256 emitted = farm.emitted(startTime, startTime + 1 days);

        assertLe(paid, emitted);
        assertLe(emitted - paid, 2);
    }

    function testAdminFunctionsRejectNonOwner() public {
        _add9mmPool();

        vm.prank(alice);
        vm.expectRevert(AmmoMarketLPFarm.NotOwner.selector);
        farm.addPool(CALIBER_556, address(lp556));

        vm.prank(alice);
        vm.expectRevert(AmmoMarketLPFarm.NotOwner.selector);
        farm.setPoolActive(0, false);
    }

    function testRecoverTokenAllowsJunkTokenAndBlocksPoolTokens() public {
        _add9mmPool();

        MockERC20 junk = new MockERC20("Junk", "JUNK", 18);
        junk.mint(address(farm), 5e18);

        farm.recoverToken(address(junk), bob, 5e18);

        assertEq(junk.balanceOf(bob), 5e18);

        vm.expectRevert(AmmoMarketLPFarm.InvalidPool.selector);
        farm.recoverToken(address(lp9mm), bob, 1);
    }

    function testShutdownFreezesAccrualButAllowsHarvests() public {
        _addTwoPools();
        _deposit(alice, 0, 10e18);
        _deposit(bob, 1, 10e18);

        assertTrue(farm.hasActivePools());

        vm.warp(startTime + 1 days);
        farm.shutdownFarm();

        assertTrue(farm.farmShutdown());
        assertEq(farm.shutdownTime(), startTime + 1 days);
        assertFalse(farm.hasActivePools());

        vm.warp(startTime + 2 days);

        assertEq(farm.pendingRewards(0, alice), 475e18);
        assertEq(farm.pendingRewards(1, bob), 475e18);

        vm.prank(alice);
        farm.harvest(0);

        vm.prank(bob);
        farm.harvest(1);

        assertEq(reward.balanceOf(alice), 475e18);
        assertEq(reward.balanceOf(bob), 475e18);
        assertEq(reward.totalSupply(), 950e18);
    }

    function testShutdownRejectsInvalidCallersAndSecondShutdown() public {
        _add9mmPool();

        vm.prank(alice);
        vm.expectRevert(AmmoMarketLPFarm.NotOwner.selector);
        farm.shutdownFarm();

        farm.shutdownFarm();

        vm.expectRevert(AmmoMarketLPFarm.FarmAlreadyShutdown.selector);
        farm.shutdownFarm();
    }

    function testShutdownBlocksPoolManagementAndDepositsButAllowsWithdraw() public {
        _add9mmPool();
        _deposit(alice, 0, 10e18);

        vm.warp(startTime + 1 days);
        farm.shutdownFarm();

        vm.expectRevert(AmmoMarketLPFarm.FarmIsShutdown.selector);
        farm.addPool(CALIBER_556, address(lp556));

        vm.expectRevert(AmmoMarketLPFarm.FarmIsShutdown.selector);
        farm.setPoolActive(0, true);

        vm.prank(bob);
        vm.expectRevert(AmmoMarketLPFarm.FarmIsShutdown.selector);
        farm.deposit(0, 10e18);

        vm.prank(alice);
        farm.withdraw(0, 10e18);

        assertEq(lp9mm.balanceOf(alice), 100e18);
        assertEq(reward.balanceOf(alice), 950e18);
        assertEq(reward.totalSupply(), 950e18);
    }

    function testRecoverTokenRejectsNonGuardianOrOwner() public {
        MockERC20 junk = new MockERC20("Junk", "JUNK", 18);
        junk.mint(address(farm), 1e18);

        vm.prank(alice);
        vm.expectRevert(AmmoMarketLPFarm.NotGuardian.selector);
        farm.recoverToken(address(junk), bob, 1e18);

        manager.setGuardian(alice);

        vm.prank(alice);
        farm.recoverToken(address(junk), bob, 1e18);

        assertEq(junk.balanceOf(bob), 1e18);
    }
}
