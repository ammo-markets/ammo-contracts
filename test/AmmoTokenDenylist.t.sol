// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AmmoManager.sol";
import "../src/AmmoToken.sol";
import "../src/AmmoLiquidityManager.sol";
import "../src/CaliberMarket.sol";
import "./MockDexRouter.sol";
import "./MockPriceOracle.sol";
import "./MockERC20.sol";
import "./MockEmissionController.sol";

/// @notice Verifies the AmmoManager.isDenied denylist short-circuits AmmoToken
///         transfers in both directions and takes precedence over tax/exempt logic.
contract AmmoTokenDenylistTest is Test {
    AmmoManager manager;
    CaliberMarket market;
    AmmoToken token;
    MockDexRouter router;
    AmmoLiquidityManager liquidityManager;
    MockERC20 usdc;
    MockPriceOracle oracle;
    MockEmissionController emissionController;

    address user = address(0xBEEF);
    address user2 = address(0xCAFE);
    address bridge = address(0xB81D6E); // simulated bridge contract
    address pool = address(0xDEE1); // simulated DEX pair
    address treasury = address(0x73EA5);
    address feeRecipient = address(0xFEE1);
    address wavax = address(0xAA0C);

    bytes32 constant CALIBER_9MM = bytes32("9MM");
    uint256 constant ORACLE_PRICE = 21e16; // $0.21 per round
    uint256 constant BUY_TAX = 300; // 3%
    uint256 constant SELL_TAX = 300; // 3%

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockPriceOracle(ORACLE_PRICE);
        router = new MockDexRouter(wavax);
        liquidityManager = new AmmoLiquidityManager(address(router));
        emissionController = new MockEmissionController(address(new MockERC20("Protocol", "AMMO", 18)));

        manager = new AmmoManager(feeRecipient, wavax);
        manager.setTreasury(treasury);
        manager.setDexRouter(address(router));

        market = new CaliberMarket(
            CaliberMarket.MarketConfig({
                manager: address(manager),
                usdc: address(usdc),
                usdcDecimals: 6,
                oracle: address(oracle),
                emissionController: address(emissionController),
                caliberId: CALIBER_9MM,
                tokenName: "Ammo 9MM",
                tokenSymbol: "MO9MM",
                mintFeeBps: 150,
                redeemFeeBps: 150,
                minMintRounds: 50
            })
        );
        token = market.token();

        manager.setPoolTax(address(token), pool, BUY_TAX, SELL_TAX);
        manager.setSwapPath(address(token), wavax, false);
        manager.setTaxSwapThreshold(address(token), 1e18);

        vm.deal(address(router), 100 ether);

        _mintTokensToUser(user, 1000e6);
        _mintTokensToUser(user2, 1000e6);
    }

    // ═══════════════════════════════════════════════
    // ── Default state ─────────────────────────────
    // ═══════════════════════════════════════════════

    function testNoAddressIsDeniedByDefault() public view {
        assertFalse(manager.isDenied(user));
        assertFalse(manager.isDenied(bridge));
        assertFalse(manager.isDenied(address(token)));
        assertFalse(manager.isDenied(address(market)));
    }

    function testTransfersWorkWhenNothingDenied() public {
        uint256 before_ = token.balanceOf(user2);

        vm.prank(user);
        token.transfer(user2, 50e18);

        assertEq(token.balanceOf(user2) - before_, 50e18);
    }

    // ═══════════════════════════════════════════════
    // ── Denial blocks `to` (sending to a bridge) ──
    // ═══════════════════════════════════════════════

    function testTransferToDeniedAddressReverts() public {
        manager.setDenied(bridge, true);

        vm.prank(user);
        vm.expectRevert(AmmoToken.Denied.selector);
        token.transfer(bridge, 10e18);
    }

    function testTransferFromUserToDeniedPoolRevertsEvenWithSellTax() public {
        // pool is a registered tax pool. Denying it should still block the transfer
        // outright — denylist takes precedence over tax logic.
        manager.setDenied(pool, true);

        vm.prank(user);
        vm.expectRevert(AmmoToken.Denied.selector);
        token.transfer(pool, 50e18);
    }

    function testTransferFromExemptAddressToDeniedReverts() public {
        // Even a tax-exempt sender cannot push tokens into a denied address.
        address staking = address(0x57AE);
        manager.setTaxExempt(staking, true);

        vm.prank(user);
        token.transfer(staking, 100e18);

        manager.setDenied(bridge, true);

        vm.prank(staking);
        vm.expectRevert(AmmoToken.Denied.selector);
        token.transfer(bridge, 50e18);
    }

    // ═══════════════════════════════════════════════
    // ── Denial blocks `from` (frozen address) ─────
    // ═══════════════════════════════════════════════

    function testTransferFromDeniedAddressReverts() public {
        // Bridge accumulated tokens before being denied.
        vm.prank(user);
        token.transfer(bridge, 100e18);
        assertEq(token.balanceOf(bridge), 100e18);

        manager.setDenied(bridge, true);

        // Bridge can no longer send the tokens out.
        vm.prank(bridge);
        vm.expectRevert(AmmoToken.Denied.selector);
        token.transfer(user2, 10e18);
    }

    function testTransferFromDeniedPoolRevertsEvenForBuy() public {
        // Seed pool with tokens, then deny it. A "buy" (pool→user) should also revert.
        vm.prank(user);
        token.transfer(pool, 200e18); // taxed sell, but pool now holds tokens
        assertTrue(token.balanceOf(pool) > 0);

        manager.setDenied(pool, true);

        vm.prank(pool);
        vm.expectRevert(AmmoToken.Denied.selector);
        token.transfer(user2, 10e18);
    }

    // ═══════════════════════════════════════════════
    // ── Lift denial ───────────────────────────────
    // ═══════════════════════════════════════════════

    function testLiftingDenialRestoresTransfers() public {
        manager.setDenied(bridge, true);

        vm.prank(user);
        vm.expectRevert(AmmoToken.Denied.selector);
        token.transfer(bridge, 10e18);

        manager.setDenied(bridge, false);

        vm.prank(user);
        token.transfer(bridge, 10e18);
        assertEq(token.balanceOf(bridge), 10e18);
    }

    // ═══════════════════════════════════════════════
    // ── Denial does NOT block mint/burn paths ─────
    // ═══════════════════════════════════════════════

    function testMintToDeniedAddressStillSucceeds() public {
        // Mint goes through the `mint()` function (onlyMarket-gated), not _transfer,
        // so it bypasses the denylist by design. Bridges should never have been
        // granted mint permissions in the first place — mint() is onlyMarket.
        manager.setDenied(user, true);

        // Existing balance should not change from setUp's prior mint
        uint256 before_ = token.balanceOf(user);

        // Direct mint via market's pathway (we simulate by calling mint as the market).
        vm.prank(address(market));
        token.mint(user, 5e18);

        assertEq(token.balanceOf(user) - before_, 5e18);
    }

    function testBurnFromDeniedAddressStillSucceeds() public {
        // Burn is onlyMarket-gated and does not go through _transfer either.
        // The market is the redemption gate, not a user surface.
        manager.setDenied(user, true);

        uint256 before_ = token.balanceOf(user);
        assertTrue(before_ >= 5e18);

        vm.prank(address(market));
        token.burn(user, 5e18);

        assertEq(before_ - token.balanceOf(user), 5e18);
    }

    // ═══════════════════════════════════════════════
    // ── Auto-swap path interaction ────────────────
    // ═══════════════════════════════════════════════

    function testTaxSwapPathStillWorksWhenUnrelatedAddressDenied() public {
        // Deny an unrelated address. The protocol's internal tax flush
        // (token→pool for swap, treasury for AVAX) should be unaffected.
        manager.setDenied(bridge, true);

        // Accumulate taxes via a sell.
        vm.prank(user);
        token.transfer(pool, 100e18);
        assertTrue(token.balanceOf(address(token)) >= 1e18);

        // Regular transfer triggers auto-swap; should not revert.
        uint256 treasuryBefore = treasury.balance;
        vm.prank(user);
        token.transfer(user2, 1e18);
        assertTrue(treasury.balance > treasuryBefore, "Treasury received AVAX");
    }

    // ═══════════════════════════════════════════════
    // ── Helpers ────────────────────────────────────
    // ═══════════════════════════════════════════════

    function _mintTokensToUser(address who, uint256 usdcAmount) internal {
        usdc.mint(who, usdcAmount);
        vm.prank(who);
        usdc.approve(address(market), usdcAmount);
        vm.prank(who);
        market.mint(usdcAmount);
    }
}
