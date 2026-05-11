// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AmmoManager.sol";
import "../src/CaliberMarket.sol";
import "../src/AmmoToken.sol";
import "../src/ExitLiquidityPool.sol";
import "./MockPriceOracle.sol";
import "./MockERC20.sol";
import "./MockEmissionController.sol";

contract CaliberMarketTest is Test {
    AmmoManager manager;
    CaliberMarket market;
    AmmoToken ammoToken;
    ExitLiquidityPool exitLiquidityPool;
    MockERC20 usdc;
    MockPriceOracle oracle;
    MockEmissionController emissionController;

    address user = address(0xBEEF);
    address keeper = address(0xCA11);
    address feeRecipient = address(0xFEE1);
    address guardian = address(0x911);
    address treasury = address(0x73EA5);
    address liquiditySource = address(0x5150);

    bytes32 constant CALIBER_9MM = bytes32("9MM");
    uint256 constant ORACLE_PRICE = 21e16; // $0.21 per round

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockPriceOracle(ORACLE_PRICE);
        emissionController = new MockEmissionController(address(new MockERC20("Protocol", "AMMO", 18)));

        manager = new AmmoManager(feeRecipient, address(0xAA0C));
        manager.setKeeper(keeper, true);
        manager.setGuardian(guardian);
        manager.setTreasury(treasury);

        exitLiquidityPool = new ExitLiquidityPool(address(manager), address(usdc), liquiditySource);
        market = _newMarket(manager, oracle, exitLiquidityPool, "Ammo 9MM", "MO9MM", 150, 150, 0, 50);
        exitLiquidityPool.setMarket(address(market), true);

        ammoToken = market.token();
        usdc.mint(user, 1_000e6);
    }

    // ── 2-step mint ────────────────────────────────

    function testStartMintEscrowsUsdcAndStoresRequestPrice() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        uint256 orderId = market.startMint(100e6, uint64(block.timestamp + 1 days));

        assertEq(usdc.balanceOf(address(market)), 100e6);
        assertEq(ammoToken.balanceOf(user), 0);
        assertEq(market.nextMintOrderId(), 2);

        (address orderUser, uint256 usdcAmount, uint256 requestPrice, uint256 feeBps,,,,, CaliberMarket.OrderStatus status)
        = market.mintOrders(orderId);
        assertEq(orderUser, user);
        assertEq(usdcAmount, 100e6);
        assertEq(requestPrice, ORACLE_PRICE);
        assertEq(feeBps, 150);
        assertEq(uint256(status), uint256(CaliberMarket.OrderStatus.Requested));
    }

    function testFinalizeMintUsesRequestPriceAndDistributesFunds() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, 0);

        oracle.setPrice(25e16);

        vm.prank(keeper);
        market.finalizeMint(orderId);

        uint256 feeAmount = (100e6 * 150) / 10_000;
        uint256 netUsdc = 100e6 - feeAmount;
        uint256 tokenAmount = (netUsdc * 1e12 * 1e18) / ORACLE_PRICE;
        uint256 actualUsdc = (tokenAmount * ORACLE_PRICE) / (1e12 * 1e18);
        uint256 refund = netUsdc - actualUsdc;

        assertEq(ammoToken.balanceOf(user), tokenAmount);
        assertEq(usdc.balanceOf(feeRecipient), feeAmount);
        assertEq(usdc.balanceOf(treasury), actualUsdc);
        assertEq(usdc.balanceOf(user), 900e6 + refund);
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    function testMintDustRefund() public {
        oracle.setPrice(30e16);
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, 0);

        uint256 userBeforeFinalize = usdc.balanceOf(user);

        vm.prank(keeper);
        market.finalizeMint(orderId);

        assertTrue(ammoToken.balanceOf(user) > 0);
        assertTrue(usdc.balanceOf(user) > userBeforeFinalize);
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    function testCancelMintRefundsFullAmount() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, 0);

        vm.prank(keeper);
        market.cancelMint(orderId, 2);

        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(usdc.balanceOf(address(market)), 0);
        assertEq(ammoToken.balanceOf(user), 0);
    }

    function testUserCanCancelMintAfterDeadline() public {
        uint64 deadline = uint64(block.timestamp + 60);
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
        uint64 deadline = uint64(block.timestamp + 60);
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, deadline);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.DeadlineExpired.selector);
        market.cancelMint(orderId, 0);
    }

    function testFinalizeMintRespectsDeadline() public {
        uint64 deadline = uint64(block.timestamp + 60);
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, deadline);

        vm.warp(deadline + 1);

        vm.prank(keeper);
        vm.expectRevert(CaliberMarket.DeadlineExpired.selector);
        market.finalizeMint(orderId);
    }

    function testStartMintStalePriceReverts() public {
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.StalePrice.selector);
        market.startMint(100e6, 0);
    }

    function testStartMintZeroPriceReverts() public {
        oracle.setPrice(0);
        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.InvalidPrice.selector);
        market.startMint(100e6, 0);
    }

    function testStartMintMinRoundsNotMet() public {
        oracle.setPrice(100e18);
        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.MinMintNotMet.selector);
        market.startMint(100e6, 0);
    }

    function testFinalizeMintTreasuryNotSetReverts() public {
        AmmoManager freshManager = new AmmoManager(feeRecipient, address(0xAA0C));
        freshManager.setKeeper(keeper, true);
        ExitLiquidityPool freshPool = new ExitLiquidityPool(address(freshManager), address(usdc), liquiditySource);
        CaliberMarket freshMarket =
            _newMarket(freshManager, oracle, freshPool, "Ammo 9MM", "MO9MM", 150, 150, 0, 50);

        usdc.mint(user, 100e6);
        vm.prank(user);
        usdc.approve(address(freshMarket), 100e6);
        vm.prank(user);
        uint256 orderId = freshMarket.startMint(100e6, 0);

        vm.prank(keeper);
        vm.expectRevert(CaliberMarket.TreasuryNotSet.selector);
        freshMarket.finalizeMint(orderId);
    }

    function testFinalizeMintOnlyKeeper() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        uint256 orderId = market.startMint(100e6, 0);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.NotKeeper.selector);
        market.finalizeMint(orderId);
    }

    // ── Redeem ──────────────────────────────────────

    function testRedeemFlowBurnsAndFees() public {
        _mintTokensToUser(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, 0);

        vm.prank(keeper);
        market.finalizeRedeem(orderId);

        assertEq(ammoToken.balanceOf(address(market)), 0);
        assertEq(ammoToken.balanceOf(feeRecipient), 1.5e18);
    }

    function testCancelRedeemUnlocksTokens() public {
        _mintTokensToUser(user);
        uint256 balBefore = ammoToken.balanceOf(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, 0);

        vm.prank(keeper);
        market.cancelRedeem(orderId, 2);

        assertEq(ammoToken.balanceOf(user), balBefore);
        assertEq(ammoToken.balanceOf(address(market)), 0);
    }

    function testUserCanCancelRedeemAfterDeadline() public {
        _mintTokensToUser(user);
        uint256 balBefore = ammoToken.balanceOf(user);
        uint64 deadline = uint64(block.timestamp + 60);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, deadline);

        vm.warp(deadline + 1);

        vm.prank(user);
        market.cancelRedeem(orderId, 0);

        assertEq(ammoToken.balanceOf(user), balBefore);
    }

    function testCannotFinalizeRedeemTwice() public {
        _mintTokensToUser(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, 0);

        vm.prank(keeper);
        market.finalizeRedeem(orderId);

        vm.prank(keeper);
        vm.expectRevert(CaliberMarket.InvalidStatus.selector);
        market.finalizeRedeem(orderId);
    }

    // ── Exit ────────────────────────────────────────

    function testRequestExitLocksTokensAndSnapshotsPayout() public {
        _mintTokensToUser(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.requestExit(100e18, uint64(block.timestamp + 1 days));

        uint256 grossUsdc = (100e18 * ORACLE_PRICE) / (1e12 * 1e18);
        uint256 payout = (grossUsdc * 9_500) / 10_000;

        assertEq(ammoToken.balanceOf(address(market)), 100e18);
        (address orderUser,, uint256 requestPrice, uint256 payoutUsdc, uint256 feeUsdc,,,,, CaliberMarket.OrderStatus status)
        = market.exitOrders(orderId);
        assertEq(orderUser, user);
        assertEq(requestPrice, ORACLE_PRICE);
        assertEq(payoutUsdc, payout);
        assertEq(feeUsdc, 0);
        assertEq(uint256(status), uint256(CaliberMarket.OrderStatus.Requested));
    }

    function testFinalizeExitUsesPoolBalanceFirst() public {
        _mintTokensToUser(user);
        uint256 orderId = _requestExit(user, 100e18, 0);
        uint256 payout = _exitPayout(100e18, ORACLE_PRICE, 0);

        usdc.mint(address(this), payout);
        usdc.approve(address(exitLiquidityPool), payout);
        exitLiquidityPool.deposit(payout);

        uint256 userUsdcBefore = usdc.balanceOf(user);

        vm.prank(keeper);
        market.finalizeExit(orderId);

        assertEq(usdc.balanceOf(user), userUsdcBefore + payout);
        assertEq(usdc.balanceOf(address(exitLiquidityPool)), 0);
        assertEq(usdc.balanceOf(liquiditySource), 0);
        assertEq(ammoToken.balanceOf(address(market)), 0);
    }

    function testFinalizeExitPullsShortfallFromLiquiditySource() public {
        _mintTokensToUser(user);
        uint256 orderId = _requestExit(user, 100e18, 0);
        uint256 payout = _exitPayout(100e18, ORACLE_PRICE, 0);
        uint256 poolPrefund = payout / 4;
        uint256 shortfall = payout - poolPrefund;

        usdc.mint(address(this), poolPrefund);
        usdc.approve(address(exitLiquidityPool), poolPrefund);
        exitLiquidityPool.deposit(poolPrefund);

        usdc.mint(liquiditySource, shortfall);
        vm.prank(liquiditySource);
        usdc.approve(address(exitLiquidityPool), shortfall);

        uint256 userUsdcBefore = usdc.balanceOf(user);

        vm.prank(keeper);
        market.finalizeExit(orderId);

        assertEq(usdc.balanceOf(user), userUsdcBefore + payout);
        assertEq(usdc.balanceOf(liquiditySource), 0);
        assertEq(usdc.balanceOf(address(exitLiquidityPool)), 0);
    }

    function testFinalizeExitRevertsWhenPoolAndSourceInsufficient() public {
        _mintTokensToUser(user);
        uint256 orderId = _requestExit(user, 100e18, 0);

        vm.prank(keeper);
        vm.expectRevert(ExitLiquidityPool.InvalidAmount.selector);
        market.finalizeExit(orderId);
    }

    function testExitFeeIsPaidToFeeRecipient() public {
        market.setExitFee(100);
        _mintTokensToUser(user);
        uint256 orderId = _requestExit(user, 100e18, 0);
        uint256 grossUsdc = (100e18 * ORACLE_PRICE) / (1e12 * 1e18);
        uint256 discounted = (grossUsdc * 9_500) / 10_000;
        uint256 fee = discounted / 100;
        uint256 payout = discounted - fee;

        usdc.mint(liquiditySource, discounted);
        vm.prank(liquiditySource);
        usdc.approve(address(exitLiquidityPool), discounted);

        uint256 userUsdcBefore = usdc.balanceOf(user);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);

        vm.prank(keeper);
        market.finalizeExit(orderId);

        assertEq(usdc.balanceOf(user), userUsdcBefore + payout);
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipientBefore, fee);
    }

    function testCancelExitUnlocksTokens() public {
        _mintTokensToUser(user);
        uint256 balBefore = ammoToken.balanceOf(user);
        uint256 orderId = _requestExit(user, 100e18, 0);

        vm.prank(keeper);
        market.cancelExit(orderId, 1);

        assertEq(ammoToken.balanceOf(user), balBefore);
        assertEq(ammoToken.balanceOf(address(market)), 0);
    }

    function testUserCanCancelExitAfterDeadline() public {
        _mintTokensToUser(user);
        uint256 balBefore = ammoToken.balanceOf(user);
        uint64 deadline = uint64(block.timestamp + 60);
        uint256 orderId = _requestExit(user, 100e18, deadline);

        vm.warp(deadline + 1);

        vm.prank(user);
        market.cancelExit(orderId, 0);

        assertEq(ammoToken.balanceOf(user), balBefore);
    }

    function testFinalizeExitOnlyKeeper() public {
        _mintTokensToUser(user);
        uint256 orderId = _requestExit(user, 100e18, 0);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.NotKeeper.selector);
        market.finalizeExit(orderId);
    }

    // ── Pool ────────────────────────────────────────

    function testPoolOnlyAuthorizedMarketCanPayExit() public {
        vm.expectRevert(ExitLiquidityPool.NotMarket.selector);
        exitLiquidityPool.payExit(user, 1);
    }

    function testPoolAvailableLiquidityIncludesSourceAllowanceLimitedByBalance() public {
        usdc.mint(address(this), 20e6);
        usdc.approve(address(exitLiquidityPool), 20e6);
        exitLiquidityPool.deposit(20e6);

        usdc.mint(liquiditySource, 100e6);
        vm.prank(liquiditySource);
        usdc.approve(address(exitLiquidityPool), 40e6);

        assertEq(exitLiquidityPool.availableLiquidity(), 60e6);
        assertEq(exitLiquidityPool.shortfallFor(50e6), 30e6);
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
        vm.expectRevert(CaliberMarket.MarketPaused.selector);
        market.startMint(100e6, 0);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        vm.expectRevert(CaliberMarket.MarketPaused.selector);
        market.startRedeem(100e18, 0);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.MarketPaused.selector);
        market.requestExit(100e18, 0);
    }

    function testSetFeesAndMinMint() public {
        market.setMintFee(300);
        market.setRedeemFee(400);
        market.setExitFee(500);
        market.setMinMint(100);

        assertEq(market.mintFeeBps(), 300);
        assertEq(market.redeemFeeBps(), 400);
        assertEq(market.exitFeeBps(), 500);
        assertEq(market.minMintRounds(), 100);
    }

    function testSeparateOrderCounters() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);
        vm.prank(user);
        market.startMint(100e6, 0);

        _mintTokensToUser(user);

        vm.startPrank(user);
        ammoToken.approve(address(market), 200e18);
        market.startRedeem(100e18, 0);
        market.requestExit(100e18, 0);
        vm.stopPrank();

        assertEq(market.nextMintOrderId(), 3);
        assertEq(market.nextRedeemOrderId(), 2);
        assertEq(market.nextExitOrderId(), 2);
    }

    function testMaxStalenessIs6Hours() public view {
        assertEq(market.MAX_STALENESS(), 6 hours);
    }

    // ── Helpers ─────────────────────────────────────

    function _mintTokensToUser(address who) internal {
        usdc.mint(who, 100e6);
        vm.prank(who);
        usdc.approve(address(market), 100e6);
        vm.prank(who);
        uint256 orderId = market.startMint(100e6, 0);
        vm.prank(keeper);
        market.finalizeMint(orderId);
    }

    function _requestExit(address who, uint256 tokenAmount, uint64 deadline) internal returns (uint256 orderId) {
        vm.prank(who);
        ammoToken.approve(address(market), tokenAmount);
        vm.prank(who);
        orderId = market.requestExit(tokenAmount, deadline);
    }

    function _exitPayout(uint256 tokenAmount, uint256 price, uint256 feeBps) internal pure returns (uint256) {
        uint256 grossUsdc = (tokenAmount * price) / (1e12 * 1e18);
        uint256 discounted = (grossUsdc * 9_500) / 10_000;
        uint256 fee = (discounted * feeBps) / 10_000;
        return discounted - fee;
    }

    function _newMarket(
        AmmoManager manager_,
        MockPriceOracle oracle_,
        ExitLiquidityPool pool_,
        string memory name,
        string memory symbol,
        uint256 mintFeeBps,
        uint256 redeemFeeBps,
        uint256 exitFeeBps,
        uint256 minMintRounds
    ) internal returns (CaliberMarket) {
        return new CaliberMarket(
            CaliberMarket.MarketConfig({
                manager: address(manager_),
                usdc: address(usdc),
                usdcDecimals: 6,
                oracle: address(oracle_),
                emissionController: address(emissionController),
                exitLiquidityPool: address(pool_),
                caliberId: CALIBER_9MM,
                tokenName: name,
                tokenSymbol: symbol,
                mintFeeBps: mintFeeBps,
                redeemFeeBps: redeemFeeBps,
                exitFeeBps: exitFeeBps,
                minMintRounds: minMintRounds
            })
        );
    }
}
