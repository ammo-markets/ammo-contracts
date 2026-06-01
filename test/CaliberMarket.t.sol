// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AmmoManager.sol";
import "../src/CaliberMarket.sol";
import "../src/CaliberToken.sol";
import "../src/interfaces/ICaliberMarket.sol";
import "./MockPriceOracle.sol";
import "./MockERC20.sol";

contract CaliberMarketTest is Test {
    AmmoManager manager;
    CaliberMarket market;
    CaliberToken ammoToken;
    MockERC20 usdc;
    MockPriceOracle oracle;

    address user = address(0xBEEF);
    address keeper = address(0xCA11);
    address feeRecipient = address(0xFEE1);
    address guardian = address(0x911);
    address treasury = address(0x73EA5);
    address caller = address(0xCA7);

    bytes32 constant CALIBER_9MM = bytes32("9MM");
    uint256 constant ORACLE_PRICE = 21e16; // $0.21 per round
    uint256 constant DEFAULT_DAILY_MINT_CAP = 1_000_000e6;
    uint256 constant KEEPER_USDC = 1_000_000e6;
    uint64 constant MIN_MINT_DEADLINE = 24 hours;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockPriceOracle(ORACLE_PRICE);

        manager = new AmmoManager(feeRecipient, address(0xAA0C));
        manager.setKeeper(keeper, true);
        manager.setGuardian(guardian);
        manager.setTreasury(treasury);

        market = _newMarket(manager, oracle, "Ammo 9MM", "MO9MM", 50);
        manager.setMarketDailyMintCap(address(market), DEFAULT_DAILY_MINT_CAP);

        ammoToken = market.token();
        usdc.mint(user, 1_000e6);

        // Keeper funds exits directly via finalizeExit
        usdc.mint(keeper, KEEPER_USDC);
        vm.prank(keeper);
        usdc.approve(address(market), type(uint256).max);
    }

    // ── 2-step mint ────────────────────────────────

    function testStartMintEscrowsUsdcAndStoresRequestPrice() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        uint256 orderId = market.startMint(100e6, _deadline());

        assertEq(usdc.balanceOf(address(market)), 100e6);
        assertEq(ammoToken.balanceOf(user), 0);
        assertEq(market.nextMintOrderId(), 2);

        (address orderUser, uint256 usdcAmount, uint256 requestPrice,,, ICaliberMarket.OrderStatus status) =
            market.mintOrders(orderId);
        assertEq(orderUser, user);
        assertEq(usdcAmount, 100e6);
        assertEq(requestPrice, ORACLE_PRICE);
        assertEq(uint256(status), uint256(ICaliberMarket.OrderStatus.Requested));
    }

    function testStartMintRejectsZeroDeadline() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.DeadlineTooShort.selector);
        market.startMint(100e6, 0);
    }

    function testStartMintRequiresDeadlineGreaterThanMinimum() public {
        vm.prank(user);
        usdc.approve(address(market), 300e6);

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.DeadlineTooShort.selector);
        market.startMint(100e6, uint64(block.timestamp + MIN_MINT_DEADLINE - 1));

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.DeadlineTooShort.selector);
        market.startMint(100e6, uint64(block.timestamp + MIN_MINT_DEADLINE));

        vm.prank(user);
        uint256 orderId = market.startMint(100e6, _deadline());

        (,,, uint64 deadline,, ICaliberMarket.OrderStatus status) = market.mintOrders(orderId);
        assertEq(deadline, _deadline());
        assertEq(uint256(status), uint256(ICaliberMarket.OrderStatus.Requested));
    }

    function testFinalizeMintUsesRequestPriceAndDistributesFunds() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, _deadline());

        oracle.setPrice(25e16);

        vm.prank(keeper);
        market.processMint(orderId);
        vm.prank(keeper);
        market.finalizeMint(orderId);

        uint256 tokenAmount = (100e6 * 1e12 * 1e18) / ORACLE_PRICE;

        assertEq(ammoToken.balanceOf(user), tokenAmount);
        assertEq(usdc.balanceOf(treasury), 100e6);
        assertEq(usdc.balanceOf(user), 900e6);
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    function testMintKeepsFullDepositWhenTokenAmountRoundsDown() public {
        oracle.setPrice(30e16);
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, _deadline());

        vm.prank(keeper);
        market.processMint(orderId);
        vm.prank(keeper);
        market.finalizeMint(orderId);

        assertTrue(ammoToken.balanceOf(user) > 0);
        assertEq(usdc.balanceOf(user), 900e6);
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    function testCancelMintRefundsFullAmount() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, _deadline());

        vm.prank(keeper);
        market.cancelMint(orderId, 2);

        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(usdc.balanceOf(address(market)), 0);
        assertEq(ammoToken.balanceOf(user), 0);
    }

    function testUserCanCancelMintAfterDeadline() public {
        uint64 deadline = _deadline();
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, deadline);

        vm.warp(deadline + 1);

        vm.prank(user);
        market.cancelMint(orderId, 0);

        assertEq(usdc.balanceOf(user), 1_000e6);
    }

    function testUserCannotCancelMintBeforeDeadline() public {
        uint64 deadline = _deadline();
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, deadline);

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.NotKeeper.selector);
        market.cancelMint(orderId, 0);
    }

    function testNonKeeperCannotCancelMintBeforeDeadline() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, _deadline());

        vm.prank(address(0xBAD));
        vm.expectRevert(ICaliberMarket.NotKeeper.selector);
        market.cancelMint(orderId, 0);
    }

    function testAnyoneCanCancelMintAfterDeadline() public {
        uint64 deadline = _deadline();
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, deadline);

        vm.warp(deadline + 1);

        vm.prank(caller);
        market.cancelMint(orderId, 0);

        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    function testProcessMintRespectsDeadline() public {
        uint64 deadline = _deadline();
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, deadline);

        vm.warp(deadline + 1);

        vm.prank(keeper);
        vm.expectRevert(ICaliberMarket.DeadlineExpired.selector);
        market.processMint(orderId);
    }

    function testFinalizeMintIgnoresDeadlineOnceProcessing() public {
        uint64 deadline = _deadline();
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, deadline);

        // Commit the order before the deadline...
        vm.prank(keeper);
        market.processMint(orderId);

        // ...then finalize after it: a committed order is never deadline-blocked.
        vm.warp(deadline + 1);
        vm.prank(keeper);
        market.finalizeMint(orderId);

        (,,,,, ICaliberMarket.OrderStatus status) = market.mintOrders(orderId);
        assertEq(uint256(status), uint256(ICaliberMarket.OrderStatus.Finalized));
        assertGt(ammoToken.balanceOf(user), 0);
    }

    function testFinalizeMintRevertsBeforeProcessing() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, _deadline());

        // Skipping processMint must block finalize — funds were never committed.
        vm.prank(keeper);
        vm.expectRevert(ICaliberMarket.InvalidStatus.selector);
        market.finalizeMint(orderId);
    }

    function testStartMintStalePriceReverts() public {
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.StalePrice.selector);
        market.startMint(100e6, _deadline());
    }

    function testStartMintZeroPriceReverts() public {
        oracle.setPrice(0);
        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.InvalidPrice.selector);
        market.startMint(100e6, _deadline());
    }

    function testStartMintMinRoundsNotMet() public {
        oracle.setPrice(100e18);
        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.MinMintNotMet.selector);
        market.startMint(100e6, _deadline());
    }

    function testProcessMintTreasuryNotSetReverts() public {
        AmmoManager freshManager = new AmmoManager(feeRecipient, address(0xAA0C));
        freshManager.setKeeper(keeper, true);
        CaliberMarket freshMarket = _newMarket(freshManager, oracle, "Ammo 9MM", "MO9MM", 50);
        freshManager.setMarketDailyMintCap(address(freshMarket), DEFAULT_DAILY_MINT_CAP);

        usdc.mint(user, 100e6);
        vm.prank(user);
        usdc.approve(address(freshMarket), 100e6);
        vm.prank(user);
        uint256 orderId = freshMarket.startMint(100e6, _deadline());

        vm.prank(keeper);
        vm.expectRevert(ICaliberMarket.TreasuryNotSet.selector);
        freshMarket.processMint(orderId);
    }

    function testFinalizeMintOnlyKeeper() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, _deadline());

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.NotKeeper.selector);
        market.finalizeMint(orderId);
    }

    function testStartMintRevertsWhenDailyCapUnset() public {
        CaliberMarket cappedMarket = _newMarket(manager, oracle, "Ammo 9MM", "MO9MM", 50);

        vm.prank(user);
        usdc.approve(address(cappedMarket), 100e6);

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.DailyMintCapExceeded.selector);
        cappedMarket.startMint(100e6, _deadline());
    }

    function testStartMintConsumesDailyGrossCap() public {
        manager.setMarketDailyMintCap(address(market), 150e6);

        vm.prank(user);
        usdc.approve(address(market), 200e6);

        vm.prank(user);
        market.startMint(100e6, _deadline());

        assertEq(market.dailyMintDay(), block.timestamp / 1 days);
        assertEq(market.dailyMintUsedUsdc(), 100e6);

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.DailyMintCapExceeded.selector);
        market.startMint(51e6, _deadline());

        vm.prank(user);
        market.startMint(50e6, _deadline());
        assertEq(market.dailyMintUsedUsdc(), 150e6);
    }

    function testDailyMintCapResetsOnNewDay() public {
        manager.setMarketDailyMintCap(address(market), 100e6);

        vm.prank(user);
        usdc.approve(address(market), 200e6);

        vm.prank(user);
        market.startMint(100e6, _deadline());

        vm.warp(((block.timestamp / 1 days) + 1) * 1 days);
        oracle.setPrice(ORACLE_PRICE);

        vm.prank(user);
        market.startMint(100e6, _deadline());

        assertEq(market.dailyMintDay(), block.timestamp / 1 days);
        assertEq(market.dailyMintUsedUsdc(), 100e6);
    }

    function testCancelMintReleasesDailyCapacity() public {
        manager.setMarketDailyMintCap(address(market), 100e6);

        vm.prank(user);
        usdc.approve(address(market), 200e6);

        vm.prank(user);
        uint256 orderId = market.startMint(100e6, _deadline());

        vm.prank(keeper);
        market.cancelMint(orderId, 1);

        assertEq(market.dailyMintUsedUsdc(), 0);

        vm.prank(user);
        market.startMint(100e6, _deadline());

        assertEq(market.dailyMintUsedUsdc(), 100e6);
    }

    function testProcessMintSweepsFullDepositToTreasury() public {
        uint256 price = 30e16; // price that does not divide 100e6 evenly
        oracle.setPrice(price);
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, _deadline());

        uint256 tokenAmount = (uint256(100e6) * 1e12 * 1e18) / price;
        assertLt((tokenAmount * price) / (1e12 * 1e18), 100e6);

        vm.prank(keeper);
        market.processMint(orderId);

        // Funds committed: treasury holds the full deposit, contract custodies nothing,
        // and no tokens exist yet.
        assertEq(usdc.balanceOf(treasury), 100e6);
        assertEq(usdc.balanceOf(user), 900e6);
        assertEq(usdc.balanceOf(address(market)), 0);
        assertEq(ammoToken.balanceOf(user), 0);

        (,,,,, ICaliberMarket.OrderStatus status) = market.mintOrders(orderId);
        assertEq(uint256(status), uint256(ICaliberMarket.OrderStatus.Processing));

        vm.prank(keeper);
        market.finalizeMint(orderId);
    }

    function testProcessMintOnlyKeeper() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, _deadline());

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.NotKeeper.selector);
        market.processMint(orderId);
    }

    function testProcessMintRequiresRequestedStatus() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, _deadline());

        vm.prank(keeper);
        market.processMint(orderId);

        // Already Processing — a second processMint must revert.
        vm.prank(keeper);
        vm.expectRevert(ICaliberMarket.InvalidStatus.selector);
        market.processMint(orderId);
    }

    function testCancelMintWhileProcessingRefundsFromCaller() public {
        uint64 deadline = _deadline();
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, deadline);

        vm.prank(keeper);
        market.processMint(orderId);

        usdc.mint(caller, 100e6);
        vm.prank(caller);
        usdc.approve(address(market), 100e6);
        vm.prank(caller);
        market.cancelMint(orderId, 0);

        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(usdc.balanceOf(caller), 0);
        assertEq(usdc.balanceOf(treasury), 100e6);
        assertEq(ammoToken.balanceOf(user), 0);

        (,,,,, ICaliberMarket.OrderStatus status) = market.mintOrders(orderId);
        assertEq(uint256(status), uint256(ICaliberMarket.OrderStatus.Canceled));
    }

    function testCancelMintWhileProcessingRequiresCallerFunding() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, _deadline());

        vm.prank(keeper);
        market.processMint(orderId);

        vm.prank(caller);
        vm.expectRevert();
        market.cancelMint(orderId, 0);
    }

    // ── Redeem ──────────────────────────────────────

    function testRedeemBurnsTokens() public {
        _mintTokensToUser(user);
        uint256 escrowed = 100e18;

        vm.prank(user);
        ammoToken.approve(address(market), escrowed);
        vm.prank(user);
        uint256 orderId = market.startRedeem(escrowed, _deadline());

        uint256 supplyBefore = ammoToken.totalSupply();

        vm.prank(keeper);
        market.finalizeRedeem(orderId);

        assertEq(ammoToken.balanceOf(address(market)), 0);
        assertEq(supplyBefore - ammoToken.totalSupply(), escrowed);
    }

    function testCancelRedeemUnlocksTokens() public {
        _mintTokensToUser(user);
        uint256 balBefore = ammoToken.balanceOf(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, _deadline());

        vm.prank(keeper);
        market.cancelRedeem(orderId, 2);

        assertEq(ammoToken.balanceOf(user), balBefore);
        assertEq(ammoToken.balanceOf(address(market)), 0);
    }

    function testUserCanCancelRedeemAfterDeadline() public {
        _mintTokensToUser(user);
        uint256 balBefore = ammoToken.balanceOf(user);
        uint64 deadline = _deadline();

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, deadline);

        vm.warp(deadline + 1);

        vm.prank(user);
        market.cancelRedeem(orderId, 0);

        assertEq(ammoToken.balanceOf(user), balBefore);
    }

    function testStartRedeemRequiresDeadlineGreaterThanMinimum() public {
        _mintTokensToUser(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.DeadlineTooShort.selector);
        market.startRedeem(100e18, 0);

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.DeadlineTooShort.selector);
        market.startRedeem(100e18, uint64(block.timestamp + MIN_MINT_DEADLINE));
    }

    function testCannotFinalizeRedeemTwice() public {
        _mintTokensToUser(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, _deadline());

        vm.prank(keeper);
        market.finalizeRedeem(orderId);

        vm.prank(keeper);
        vm.expectRevert(ICaliberMarket.InvalidStatus.selector);
        market.finalizeRedeem(orderId);
    }

    // ── Exit ────────────────────────────────────────

    function testRequestExitLocksTokensAndSnapshotsPayout() public {
        _mintTokensToUser(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.requestExit(100e18, _deadline());

        uint256 grossUsdc = (100e18 * ORACLE_PRICE) / (1e12 * 1e18);
        uint256 payout = (grossUsdc * 9_500) / 10_000;

        assertEq(ammoToken.balanceOf(address(market)), 100e18);
        (address orderUser,, uint256 requestPrice, uint256 payoutUsdc,,, ICaliberMarket.OrderStatus status) =
            market.exitOrders(orderId);
        assertEq(orderUser, user);
        assertEq(requestPrice, ORACLE_PRICE);
        assertEq(payoutUsdc, payout);
        assertEq(uint256(status), uint256(ICaliberMarket.OrderStatus.Requested));
    }

    function testFinalizeExitPullsUsdcFromKeeperToUser() public {
        _mintTokensToUser(user);
        uint256 orderId = _requestExit(user, 100e18, _deadline());
        uint256 payout = _exitPayout(100e18, ORACLE_PRICE);

        uint256 userUsdcBefore = usdc.balanceOf(user);
        uint256 keeperUsdcBefore = usdc.balanceOf(keeper);

        vm.prank(keeper);
        market.finalizeExit(orderId);

        assertEq(usdc.balanceOf(user), userUsdcBefore + payout);
        assertEq(usdc.balanceOf(keeper), keeperUsdcBefore - payout);
        assertEq(ammoToken.balanceOf(address(market)), 0);
    }

    function testFinalizeExitRevertsWhenKeeperHasInsufficientUsdc() public {
        _mintTokensToUser(user);
        uint256 orderId = _requestExit(user, 100e18, _deadline());

        // Drain keeper to a stranger before finalize
        uint256 keeperBalance = usdc.balanceOf(keeper);
        vm.prank(keeper);
        usdc.transfer(address(0xDEAD), keeperBalance);

        vm.prank(keeper);
        vm.expectRevert();
        market.finalizeExit(orderId);
    }

    function testFinalizeExitRevertsWhenKeeperHasNotApproved() public {
        // Keeper without approval
        address fresh = address(0xC0FFEE);
        manager.setKeeper(fresh, true);
        usdc.mint(fresh, 1_000_000e6);

        _mintTokensToUser(user);
        uint256 orderId = _requestExit(user, 100e18, _deadline());

        vm.prank(fresh);
        vm.expectRevert();
        market.finalizeExit(orderId);
    }

    function testCancelExitUnlocksTokens() public {
        _mintTokensToUser(user);
        uint256 balBefore = ammoToken.balanceOf(user);
        uint256 orderId = _requestExit(user, 100e18, _deadline());

        vm.prank(keeper);
        market.cancelExit(orderId, 1);

        assertEq(ammoToken.balanceOf(user), balBefore);
        assertEq(ammoToken.balanceOf(address(market)), 0);
    }

    function testUserCanCancelExitAfterDeadline() public {
        _mintTokensToUser(user);
        uint256 balBefore = ammoToken.balanceOf(user);
        uint64 deadline = _deadline();
        uint256 orderId = _requestExit(user, 100e18, deadline);

        vm.warp(deadline + 1);

        vm.prank(user);
        market.cancelExit(orderId, 0);

        assertEq(ammoToken.balanceOf(user), balBefore);
    }

    function testRequestExitRequiresDeadlineGreaterThanMinimum() public {
        _mintTokensToUser(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.DeadlineTooShort.selector);
        market.requestExit(100e18, 0);

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.DeadlineTooShort.selector);
        market.requestExit(100e18, uint64(block.timestamp + MIN_MINT_DEADLINE));
    }

    function testFinalizeExitOnlyKeeper() public {
        _mintTokensToUser(user);
        uint256 orderId = _requestExit(user, 100e18, _deadline());

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.NotKeeper.selector);
        market.finalizeExit(orderId);
    }

    // ── Pause/Admin ─────────────────────────────────

    function testGuardianCanPause() public {
        vm.prank(guardian);
        market.pause();
        assertTrue(market.paused());
    }

    function testPauseBlocksStartMintRedeemAndExit() public {
        _mintTokensToUser(user);
        market.pause();

        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        vm.expectRevert(ICaliberMarket.MarketPaused.selector);
        market.startMint(100e6, _deadline());

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        vm.expectRevert(ICaliberMarket.MarketPaused.selector);
        market.startRedeem(100e18, _deadline());

        vm.prank(user);
        vm.expectRevert(ICaliberMarket.MarketPaused.selector);
        market.requestExit(100e18, _deadline());
    }

    function testSetMinMint() public {
        market.setMinMint(100);
        assertEq(market.minMintRounds(), 100);
    }

    function testSeparateOrderCounters() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        market.startMint(100e6, _deadline());

        _mintTokensToUser(user);

        vm.startPrank(user);
        ammoToken.approve(address(market), 200e18);
        market.startRedeem(100e18, _deadline());
        market.requestExit(100e18, _deadline());
        vm.stopPrank();

        assertEq(market.nextMintOrderId(), 3);
        assertEq(market.nextRedeemOrderId(), 2);
        assertEq(market.nextExitOrderId(), 2);
    }

    function testMaxStalenessIs6Hours() public view {
        assertEq(market.MAX_STALENESS(), 6 hours);
    }

    // ── Helpers ─────────────────────────────────────

    function _deadline() internal view returns (uint64) {
        return uint64(block.timestamp + MIN_MINT_DEADLINE + 1);
    }

    function _mintTokensToUser(address who) internal {
        usdc.mint(who, 100e6);
        vm.prank(who);
        usdc.approve(address(market), 100e6);
        vm.prank(who);
        uint256 orderId = market.startMint(100e6, _deadline());
        vm.prank(keeper);
        market.processMint(orderId);
        vm.prank(keeper);
        market.finalizeMint(orderId);
    }

    function _requestExit(address who, uint256 tokenAmount, uint64 deadline) internal returns (uint256 orderId) {
        vm.prank(who);
        ammoToken.approve(address(market), tokenAmount);
        vm.prank(who);
        orderId = market.requestExit(tokenAmount, deadline);
    }

    function _exitPayout(uint256 tokenAmount, uint256 price) internal pure returns (uint256) {
        uint256 grossUsdc = (tokenAmount * price) / (1e12 * 1e18);
        return (grossUsdc * 9_500) / 10_000;
    }

    function _newMarket(
        AmmoManager manager_,
        MockPriceOracle oracle_,
        string memory name,
        string memory symbol,
        uint256 minMintRounds
    ) internal returns (CaliberMarket) {
        return new CaliberMarket(
            ICaliberMarket.MarketConfig({
                manager: address(manager_),
                usdc: address(usdc),
                usdcDecimals: 6,
                oracle: address(oracle_),
                caliberId: CALIBER_9MM,
                tokenName: name,
                tokenSymbol: symbol,
                minMintRounds: minMintRounds
            })
        );
    }
}
