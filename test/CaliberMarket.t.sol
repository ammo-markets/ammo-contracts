// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AmmoManager.sol";
import "../src/CaliberMarket.sol";
import "../src/AmmoToken.sol";
import "./MockPriceOracle.sol";
import "./MockERC20.sol";
import "./MockEmissionController.sol";

contract CaliberMarketTest is Test {
    AmmoManager manager;
    CaliberMarket market;
    AmmoToken ammoToken;
    MockERC20 usdc;
    MockPriceOracle oracle;
    MockEmissionController emissionController;

    address user = address(0xBEEF);
    address keeper = address(0xCA11);
    address feeRecipient = address(0xFEE1);
    address guardian = address(0x911);
    address treasury = address(0x73EA5);

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

        market = _newMarket(manager, oracle, "Ammo 9MM", "MO9MM", 150, 150, 50);

        ammoToken = market.token();

        usdc.mint(user, 1_000e6);
    }

    // ═══════════════════════════════════════════════
    // ── 1-Step Mint ────────────────────────────────
    // ═══════════════════════════════════════════════

    function testMintHappyPath() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        market.mint(100e6);

        // fee = 100e6 * 150 / 10_000 = 1_500_000
        // netUsdc = 98_500_000
        // tokenAmount = 98_500_000 * 1e12 * 1e18 / 21e16
        uint256 expectedTokens = (uint256(98_500_000) * 1e12 * 1e18) / ORACLE_PRICE;

        assertEq(ammoToken.balanceOf(user), expectedTokens);
        assertEq(usdc.balanceOf(feeRecipient), 1_500_000);
    }

    function testMintSendsTreasuryCorrectAmount() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(user);
        market.mint(100e6);

        uint256 feeAmount = (100e6 * 150) / 10_000;
        uint256 netUsdc = 100e6 - feeAmount;
        uint256 tokenAmount = (netUsdc * 1e12 * 1e18) / ORACLE_PRICE;
        uint256 actualUsdc = (tokenAmount * ORACLE_PRICE) / (1e12 * 1e18);

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, actualUsdc);
        // Market should have zero USDC left (or only dust if refund went to user)
    }

    function testMintDustRefund() public {
        // Use a price that causes rounding: $0.30 per round
        oracle.setPrice(30e16);

        vm.prank(user);
        usdc.approve(address(market), 100e6);

        uint256 userBefore = usdc.balanceOf(user);

        vm.prank(user);
        market.mint(100e6);

        uint256 userAfter = usdc.balanceOf(user);
        uint256 tokens = ammoToken.balanceOf(user);

        // Verify user got some tokens
        assertTrue(tokens > 0);

        // Verify total accounting: fee + treasury + refund = 100e6
        uint256 refund = userAfter - (userBefore - 100e6);
        assertEq(usdc.balanceOf(feeRecipient) + usdc.balanceOf(treasury) + refund, 100e6);

        // Refund should be > 0 (dust from rounding)
        assertTrue(refund > 0);

        // Market should have no USDC
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    function testMintExactAccounting() public {
        // Use a clean price: $0.25 per round (4 rounds per USDC)
        oracle.setPrice(25e16);

        // 100 USDC, fee = 1.5 USDC, net = 98.5 USDC
        // tokenAmount = 98_500_000 * 1e12 * 1e18 / 25e16 = 394e18
        // actualUsdc = 394e18 * 25e16 / (1e12 * 1e18) = 98_500_000
        // refund = 0
        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        market.mint(100e6);

        assertEq(ammoToken.balanceOf(user), 394e18);
        assertEq(usdc.balanceOf(feeRecipient), 1_500_000);
        assertEq(usdc.balanceOf(treasury), 98_500_000);
        assertEq(usdc.balanceOf(user), 900e6); // no refund
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    function testMintStalePriceReverts() public {
        // Advance time past staleness
        vm.warp(block.timestamp + 6 hours + 1);

        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.StalePrice.selector);
        market.mint(100e6);
    }

    function testMintAtExactStalenessLimit() public {
        // Exactly at the boundary — should still work
        vm.warp(block.timestamp + 6 hours);

        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        market.mint(100e6);

        assertTrue(ammoToken.balanceOf(user) > 0);
    }

    function testMintZeroPriceReverts() public {
        oracle.setPrice(0);

        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.InvalidPrice.selector);
        market.mint(100e6);
    }

    function testMintMinRoundsNotMet() public {
        // $100 per round — 100 USDC can only get < 1 token (after fee)
        oracle.setPrice(100e18);

        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.MinMintNotMet.selector);
        market.mint(100e6);
    }

    function testMintPausedReverts() public {
        market.pause();

        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.MarketPaused.selector);
        market.mint(100e6);
    }

    function testMintZeroAmountReverts() public {
        vm.prank(user);
        vm.expectRevert(CaliberMarket.InvalidAmount.selector);
        market.mint(0);
    }

    function testMintTreasuryNotSetReverts() public {
        AmmoManager freshManager = new AmmoManager(feeRecipient, address(0xAA0C));
        freshManager.setKeeper(keeper, true);
        // treasury not set

        MockPriceOracle freshOracle = new MockPriceOracle(ORACLE_PRICE);

        CaliberMarket freshMarket = _newMarket(freshManager, freshOracle, "Ammo 9MM", "MO9MM", 150, 150, 50);

        usdc.mint(user, 100e6);
        vm.prank(user);
        usdc.approve(address(freshMarket), 100e6);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.TreasuryNotSet.selector);
        freshMarket.mint(100e6);
    }

    function testMintZeroFeeAllToTreasury() public {
        CaliberMarket zeroFeeMarket = _newMarket(manager, oracle, "Ammo 9MM Zero", "MO9Z", 0, 150, 50);

        usdc.mint(user, 100e6);
        vm.prank(user);
        usdc.approve(address(zeroFeeMarket), 100e6);

        vm.prank(user);
        zeroFeeMarket.mint(100e6);

        // 0% fee → feeRecipient gets nothing from this market
        // All net USDC goes to treasury
        assertTrue(zeroFeeMarket.token().balanceOf(user) > 0);
    }

    function testMintEmitsMintedEvent() public {
        vm.prank(user);
        usdc.approve(address(market), 100e6);

        uint256 feeAmount = (100e6 * 150) / 10_000;
        uint256 netUsdc = 100e6 - feeAmount;
        uint256 tokenAmount = (netUsdc * 1e12 * 1e18) / ORACLE_PRICE;
        uint256 actualUsdc = (tokenAmount * ORACLE_PRICE) / (1e12 * 1e18);
        uint256 refund = netUsdc - actualUsdc;

        vm.expectEmit(true, true, false, true);
        emit CaliberMarket.Minted(user, CALIBER_9MM, 100e6, tokenAmount, ORACLE_PRICE, refund);

        vm.prank(user);
        market.mint(100e6);
    }

    function testMintE2EBalances() public {
        uint256 userUsdcBefore = usdc.balanceOf(user);

        vm.prank(user);
        usdc.approve(address(market), 200e6);

        vm.prank(user);
        market.mint(200e6);

        uint256 tokens = ammoToken.balanceOf(user);
        assertTrue(tokens > 0);

        // Token supply equals user balance (first mint)
        assertEq(ammoToken.totalSupply(), tokens);

        // USDC distributed correctly
        uint256 feeAmount = (200e6 * 150) / 10_000;
        uint256 netUsdc = 200e6 - feeAmount;
        uint256 actualUsdc = (tokens * ORACLE_PRICE) / (1e12 * 1e18);
        uint256 refund = netUsdc - actualUsdc;

        assertEq(usdc.balanceOf(feeRecipient), feeAmount);
        assertEq(usdc.balanceOf(treasury), actualUsdc);
        assertEq(usdc.balanceOf(user), userUsdcBefore - 200e6 + refund);
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    // ═══════════════════════════════════════════════
    // ── Redeem (unchanged) ─────────────────────────
    // ═══════════════════════════════════════════════

    function testRedeemFlowBurnsAndFees() public {
        _mintTokensToUser(user);
        uint256 userBalance = ammoToken.balanceOf(user);
        assertTrue(userBalance > 100e18);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);

        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, 0);

        assertEq(ammoToken.balanceOf(address(market)), 100e18);

        vm.prank(keeper);
        market.finalizeRedeem(orderId);

        // fee = 100e18 * 150 / 10_000 = 1.5e18
        // netTokens = 98.5e18 → burned
        assertEq(ammoToken.balanceOf(address(market)), 0);
        assertEq(ammoToken.balanceOf(feeRecipient), 1.5e18);
    }

    // ── cancelRedeem ────────────────────────────────

    function testCancelRedeemUnlocksTokens() public {
        _mintTokensToUser(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);

        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, 0);

        uint256 balBefore = ammoToken.balanceOf(user);

        vm.prank(keeper);
        market.cancelRedeem(orderId, 2);

        assertEq(ammoToken.balanceOf(user), balBefore + 100e18);
        assertEq(ammoToken.balanceOf(address(market)), 0);
    }

    // ── Pause ───────────────────────────────────────

    function testGuardianCanPause() public {
        vm.prank(guardian);
        market.pause();
        assertTrue(market.paused());
    }

    function testGuardianCannotUnpause() public {
        market.pause();

        vm.prank(guardian);
        vm.expectRevert(CaliberMarket.NotOwner.selector);
        market.unpause();
    }

    // ── Admin ───────────────────────────────────────

    function testSetMintFee() public {
        market.setMintFee(300);
        assertEq(market.mintFeeBps(), 300);
    }

    function testSetRedeemFee() public {
        market.setRedeemFee(300);
        assertEq(market.redeemFeeBps(), 300);
    }

    function testSetMinMint() public {
        market.setMinMint(100);
        assertEq(market.minMintRounds(), 100);
    }

    // ── State-machine integrity (redeem) ─────────

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

    function testCannotCancelRedeemAfterFinalize() public {
        _mintTokensToUser(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, 0);

        vm.prank(keeper);
        market.finalizeRedeem(orderId);

        vm.prank(keeper);
        vm.expectRevert(CaliberMarket.InvalidStatus.selector);
        market.cancelRedeem(orderId, 1);
    }

    // ── Access control ──────────────────────────────

    function testFinalizeRedeemOnlyKeeper() public {
        _mintTokensToUser(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, 0);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.NotKeeper.selector);
        market.finalizeRedeem(orderId);
    }

    function testCancelRedeemRejectsRandomCaller() public {
        _mintTokensToUser(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, 0);

        address random = address(0xDEAD);
        vm.prank(random);
        vm.expectRevert(CaliberMarket.NotKeeper.selector);
        market.cancelRedeem(orderId, 1);
    }

    // ── Pause parity ────────────────────────────────

    function testPauseBlocksMint() public {
        market.pause();

        vm.prank(user);
        usdc.approve(address(market), 100e6);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.MarketPaused.selector);
        market.mint(100e6);
    }

    function testPauseBlocksStartRedeem() public {
        _mintTokensToUser(user);
        market.pause();

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.MarketPaused.selector);
        market.startRedeem(100e18, 0);
    }

    function testPauseBlocksFinalizeRedeem() public {
        _mintTokensToUser(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, 0);

        market.pause();

        vm.prank(keeper);
        vm.expectRevert(CaliberMarket.MarketPaused.selector);
        market.finalizeRedeem(orderId);
    }

    function testPauseAllowsCancelRedeem() public {
        _mintTokensToUser(user);
        uint256 balBefore = ammoToken.balanceOf(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, 0);

        market.pause();

        vm.prank(keeper);
        market.cancelRedeem(orderId, 1);

        assertEq(ammoToken.balanceOf(user), balBefore);
    }

    // ── Redeem deadline ─────────────────────────────

    function testFinalizeRedeemRespectsDeadline() public {
        _mintTokensToUser(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, uint64(block.timestamp + 60));

        vm.warp(block.timestamp + 120);

        vm.prank(keeper);
        vm.expectRevert(CaliberMarket.DeadlineExpired.selector);
        market.finalizeRedeem(orderId);
    }

    function testFinalizeRedeemUsesSnapshotFee() public {
        _mintTokensToUser(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, 0);

        // Admin changes redeem fee after order creation
        market.setRedeemFee(500);

        vm.prank(keeper);
        market.finalizeRedeem(orderId);

        // Should use 150 bps (snapshot), NOT 500 bps
        assertEq(ammoToken.balanceOf(feeRecipient), 1.5e18);
    }

    // ── User self-rescue after deadline ─────────────

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

    function testUserCannotCancelRedeemBeforeDeadline() public {
        _mintTokensToUser(user);

        uint64 deadline = uint64(block.timestamp + 60);
        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, deadline);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.DeadlineExpired.selector);
        market.cancelRedeem(orderId, 0);
    }

    function testUserCannotCancelRedeemWithZeroDeadline() public {
        _mintTokensToUser(user);

        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, 0);

        vm.warp(block.timestamp + 9999);

        vm.prank(user);
        vm.expectRevert(CaliberMarket.DeadlineNotSet.selector);
        market.cancelRedeem(orderId, 0);
    }

    function testUserSelfRescueRedeemWorksWhenPaused() public {
        _mintTokensToUser(user);
        uint256 balBefore = ammoToken.balanceOf(user);

        uint64 deadline = uint64(block.timestamp + 60);
        vm.prank(user);
        ammoToken.approve(address(market), 100e18);
        vm.prank(user);
        uint256 orderId = market.startRedeem(100e18, deadline);

        market.pause();
        vm.warp(deadline + 1);

        vm.prank(user);
        market.cancelRedeem(orderId, 0);

        assertEq(ammoToken.balanceOf(user), balBefore);
    }

    // ── MAX_STALENESS constant ──────────────────────

    function testMaxStalenessIs6Hours() public view {
        assertEq(market.MAX_STALENESS(), 6 hours);
    }

    // ── Helpers ─────────────────────────────────────

    function _mintTokensToUser(address who) internal {
        usdc.mint(who, 100e6);
        vm.prank(who);
        usdc.approve(address(market), 100e6);
        vm.prank(who);
        market.mint(100e6);
    }

    function _newMarket(
        AmmoManager manager_,
        MockPriceOracle oracle_,
        string memory name,
        string memory symbol,
        uint256 mintFeeBps,
        uint256 redeemFeeBps,
        uint256 minMintRounds
    ) internal returns (CaliberMarket) {
        return new CaliberMarket(
            CaliberMarket.MarketConfig({
                manager: address(manager_),
                usdc: address(usdc),
                usdcDecimals: 6,
                oracle: address(oracle_),
                emissionController: address(emissionController),
                caliberId: CALIBER_9MM,
                tokenName: name,
                tokenSymbol: symbol,
                mintFeeBps: mintFeeBps,
                redeemFeeBps: redeemFeeBps,
                minMintRounds: minMintRounds
            })
        );
    }
}
