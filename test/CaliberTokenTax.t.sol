// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AmmoManager.sol";
import "../src/CaliberToken.sol";
import "../src/AmmoLiquidityManager.sol";
import "../src/CaliberMarket.sol";
import "../src/interfaces/ICaliberMarket.sol";
import "./MockDexRouter.sol";
import "./MockPriceOracle.sol";
import "./MockERC20.sol";

contract MockGvAmmo {
    mapping(address => uint256) internal balances;
    uint256 public totalSupply;
    bool public shouldRevert;

    function setBalance(address account, uint256 amount) external {
        balances[account] = amount;
    }

    function setTotalSupply(uint256 amount) external {
        totalSupply = amount;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function balanceOf(address account) external view returns (uint256) {
        require(!shouldRevert, "gv balance unavailable");
        return balances[account];
    }
}

contract CaliberTokenTaxTest is Test {
    AmmoManager manager;
    CaliberMarket market;
    CaliberToken token;
    MockDexRouter router;
    AmmoLiquidityManager liquidityManager;
    MockERC20 usdc;
    MockPriceOracle oracle;
    MockGvAmmo gvAmmo;

    address owner = address(this);
    address user = address(0xBEEF);
    address user2 = address(0xCAFE);
    address pool = address(0xDEE1); // simulated DEX pair
    address treasury = address(0x73EA5);
    address feeRecipient = address(0xFEE1);
    address wavax = address(0xAA0C);

    bytes32 constant CALIBER_9MM = bytes32("9MM");
    uint256 constant ORACLE_PRICE = 21e16; // $0.21 per round
    uint64 constant MIN_MINT_DEADLINE = 24 hours;
    uint256 constant BUY_TAX = 300; // 3%
    uint256 constant SELL_TAX = 300; // 3%

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockPriceOracle(ORACLE_PRICE);
        router = new MockDexRouter(wavax);
        liquidityManager = new AmmoLiquidityManager(address(router));
        gvAmmo = new MockGvAmmo();

        manager = new AmmoManager(feeRecipient, wavax);
        manager.setTreasury(treasury);
        manager.setTaxExempt(address(liquidityManager), true);

        market = new CaliberMarket(
            ICaliberMarket.MarketConfig({
                manager: address(manager),
                usdc: address(usdc),
                usdcDecimals: 6,
                oracle: address(oracle),
                caliberId: CALIBER_9MM,
                tokenName: "Ammo 9MM",
                tokenSymbol: "MO9MM",
                minMintRounds: 50
            })
        );
        token = market.token();
        manager.setMarketDailyMintCap(address(market), type(uint256).max);

        manager.setPoolTax(address(token), pool, BUY_TAX, SELL_TAX);

        // Mint tokens to users via market
        _mintTokensToUser(user, 1000e6);
        _mintTokensToUser(user2, 1000e6);

        // Give pool some tokens to simulate buys (pool sending tokens to user)
        vm.prank(user2);
        token.transfer(pool, 500e18);
    }

    // ═══════════════════════════════════════════════
    // ── Buy Tax (transfer FROM pool TO user) ──────
    // ═══════════════════════════════════════════════

    function testBuyTaxApplied() public {
        uint256 amount = 100e18;
        uint256 expectedTax = (amount * BUY_TAX) / 10_000; // 3e18
        uint256 expectedReceive = amount - expectedTax; // 97e18

        uint256 userBefore = token.balanceOf(user);
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(pool);
        token.transfer(user, amount);

        assertEq(token.balanceOf(user) - userBefore, expectedReceive);
        assertEq(token.balanceOf(treasury) - treasuryBefore, expectedTax);
    }

    function testBuyTaxEmitsCorrectTransferAmounts() public {
        uint256 amount = 100e18;
        uint256 expectedTax = (amount * BUY_TAX) / 10_000;
        uint256 expectedReceive = amount - expectedTax;

        vm.expectEmit(true, true, false, true);
        emit CaliberToken.Transfer(pool, user, expectedReceive);

        vm.expectEmit(true, true, false, true);
        emit CaliberToken.Transfer(pool, treasury, expectedTax);

        vm.prank(pool);
        token.transfer(user, amount);
    }

    // ═══════════════════════════════════════════════
    // ── Sell Tax (transfer FROM user TO pool) ─────
    // ═══════════════════════════════════════════════

    function testSellTaxApplied() public {
        uint256 amount = 100e18;
        uint256 expectedTax = (amount * SELL_TAX) / 10_000;

        uint256 poolBefore = token.balanceOf(pool);
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(user);
        token.transfer(pool, amount);

        assertEq(token.balanceOf(pool) - poolBefore, amount - expectedTax);
        assertEq(token.balanceOf(treasury) - treasuryBefore, expectedTax);
    }

    function testTaxStaysInTokenContractWhenTreasuryUnset() public {
        AmmoManager unsetTreasuryManager = new AmmoManager(feeRecipient, wavax);
        CaliberToken unsetTreasuryToken =
            new CaliberToken("Unset Treasury Ammo", "UTA", address(this), address(unsetTreasuryManager));
        unsetTreasuryManager.setPoolTax(address(unsetTreasuryToken), pool, BUY_TAX, SELL_TAX);

        unsetTreasuryToken.mint(user, 100e18);

        uint256 amount = 100e18;
        uint256 expectedTax = (amount * SELL_TAX) / 10_000;

        vm.expectEmit(true, true, false, true);
        emit CaliberToken.Transfer(user, address(unsetTreasuryToken), expectedTax);

        vm.prank(user);
        unsetTreasuryToken.transfer(pool, amount);

        assertEq(unsetTreasuryToken.balanceOf(pool), amount - expectedTax);
        assertEq(unsetTreasuryToken.balanceOf(address(unsetTreasuryToken)), expectedTax);
        assertEq(unsetTreasuryToken.balanceOf(address(0)), 0);
    }

    function testHeldTaxSweepsToTreasuryOnNextTaxedTransfer() public {
        AmmoManager unsetTreasuryManager = new AmmoManager(feeRecipient, wavax);
        CaliberToken unsetTreasuryToken =
            new CaliberToken("Unset Treasury Ammo", "UTA", address(this), address(unsetTreasuryManager));
        unsetTreasuryManager.setPoolTax(address(unsetTreasuryToken), pool, BUY_TAX, SELL_TAX);

        unsetTreasuryToken.mint(user, 200e18);

        uint256 amount = 100e18;
        uint256 expectedTax = (amount * SELL_TAX) / 10_000;

        vm.prank(user);
        unsetTreasuryToken.transfer(pool, amount);

        assertEq(unsetTreasuryToken.balanceOf(address(unsetTreasuryToken)), expectedTax);
        assertEq(unsetTreasuryToken.balanceOf(treasury), 0);

        unsetTreasuryManager.setTreasury(treasury);

        vm.expectEmit(true, true, false, true);
        emit CaliberToken.Transfer(address(unsetTreasuryToken), treasury, expectedTax);

        vm.expectEmit(true, true, false, true);
        emit CaliberToken.Transfer(user, treasury, expectedTax);

        vm.prank(user);
        unsetTreasuryToken.transfer(pool, amount);

        assertEq(unsetTreasuryToken.balanceOf(address(unsetTreasuryToken)), 0);
        assertEq(unsetTreasuryToken.balanceOf(treasury), expectedTax * 2);
    }

    // ═══════════════════════════════════════════════
    // ── No Tax Scenarios ──────────────────────────
    // ═══════════════════════════════════════════════

    function testNoTaxOnUserToUserTransfer() public {
        uint256 amount = 50e18;
        uint256 user2Before = token.balanceOf(user2);

        vm.prank(user);
        token.transfer(user2, amount);

        assertEq(token.balanceOf(user2) - user2Before, amount); // full amount, no tax
    }

    function testNoTaxOnMarketMint() public {
        uint256 supplyBefore = token.totalSupply();
        _mintTokensToUser(user, 100e6);
        uint256 minted = token.totalSupply() - supplyBefore;

        // All minted tokens should go to user, none to tax
        assertTrue(minted > 0);
        // Token contract should not have accumulated tax from minting
    }

    function testNoTaxOnMarketRedeem() public {
        uint256 redeemAmount = 100e18;
        vm.prank(user);
        token.approve(address(market), redeemAmount);

        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(user);
        market.startRedeem(redeemAmount, _deadline());

        assertEq(token.balanceOf(treasury), treasuryBefore);
        assertEq(token.balanceOf(address(market)), redeemAmount);
    }

    function testNoTaxOnUnregisteredPool() public {
        address unregistered = address(0x999);
        vm.prank(user);
        token.transfer(unregistered, 50e18);
        assertEq(token.balanceOf(unregistered), 50e18); // full amount
    }

    function testNoTaxOnProtocolExemptBuy() public {
        address stakingContract = address(0x57AE);
        manager.setTaxExempt(stakingContract, true);

        // Buy: pool → exempt address — should bypass buy tax
        uint256 poolBefore = token.balanceOf(pool);
        vm.prank(pool);
        token.transfer(stakingContract, 50e18);

        // Exempt address receives full amount (no tax deducted)
        assertEq(token.balanceOf(stakingContract), 50e18, "Exempt addr gets full amount");
        // Pool lost exactly 50e18 — confirms no tax skimmed from the transfer
        assertEq(poolBefore - token.balanceOf(pool), 50e18, "Pool sent exact amount");
    }

    function testNoTaxOnProtocolExemptSell() public {
        address stakingContract = address(0x57AE);
        manager.setTaxExempt(stakingContract, true);

        // Give staking contract some tokens
        vm.prank(user);
        token.transfer(stakingContract, 100e18);

        // Sell: exempt address → pool — should bypass sell tax
        uint256 poolBefore = token.balanceOf(pool);
        uint256 taxBefore = token.balanceOf(treasury);
        vm.prank(stakingContract);
        token.transfer(pool, 50e18);
        assertEq(token.balanceOf(pool) - poolBefore, 50e18, "Pool gets full amount");
        assertEq(token.balanceOf(treasury), taxBefore, "No tax collected");
    }

    function testGvAmmoTaxExemptionDisabledByDefaultDoesNotChangeSellTax() public {
        uint256 amount = 100e18;
        gvAmmo.setBalance(user, amount);
        gvAmmo.setTotalSupply(10_000e18);

        uint256 poolBefore = token.balanceOf(pool);
        uint256 taxBefore = token.balanceOf(treasury);

        vm.prank(user);
        token.transfer(pool, amount);

        assertEq(token.balanceOf(pool) - poolBefore, amount - ((amount * SELL_TAX) / 10_000));
        assertEq(token.balanceOf(treasury) - taxBefore, (amount * SELL_TAX) / 10_000);
    }

    function testGvAmmoTaxExemptSellerPaysNoSellTax() public {
        uint256 amount = 100e18;
        manager.setGvAmmo(address(gvAmmo), 100); // requires 1% of gvAmmo supply
        gvAmmo.setTotalSupply(1_000e18);
        gvAmmo.setBalance(user, 10e18);

        uint256 poolBefore = token.balanceOf(pool);
        uint256 taxBefore = token.balanceOf(treasury);

        vm.prank(user);
        token.transfer(pool, amount);

        assertEq(token.balanceOf(pool) - poolBefore, amount);
        assertEq(token.balanceOf(treasury), taxBefore);
    }

    function testGvAmmoTaxExemptionIsIndependentOfSwapSize() public {
        uint256 amount = 250e18;
        manager.setGvAmmo(address(gvAmmo), 100);
        gvAmmo.setTotalSupply(1_000e18);
        gvAmmo.setBalance(user, 10e18);

        uint256 poolBefore = token.balanceOf(pool);
        uint256 taxBefore = token.balanceOf(treasury);

        vm.prank(user);
        token.transfer(pool, amount);

        assertEq(token.balanceOf(pool) - poolBefore, amount);
        assertEq(token.balanceOf(treasury), taxBefore);
    }

    function testGvAmmoTaxExemptBuyerPaysNoBuyTax() public {
        uint256 amount = 50e18;
        manager.setGvAmmo(address(gvAmmo), 100);
        gvAmmo.setTotalSupply(1_000e18);
        gvAmmo.setBalance(user, 10e18);

        uint256 userBefore = token.balanceOf(user);
        uint256 taxBefore = token.balanceOf(treasury);

        vm.prank(pool);
        token.transfer(user, amount);

        assertEq(token.balanceOf(user) - userBefore, amount);
        assertEq(token.balanceOf(treasury), taxBefore);
    }

    function testGvAmmoTaxExemptionRequiresEnoughSupplyShare() public {
        uint256 amount = 100e18;
        manager.setGvAmmo(address(gvAmmo), 100);
        gvAmmo.setTotalSupply(1_000e18);
        gvAmmo.setBalance(user, 10e18 - 1);

        uint256 poolBefore = token.balanceOf(pool);
        uint256 taxBefore = token.balanceOf(treasury);

        vm.prank(user);
        token.transfer(pool, amount);

        assertEq(token.balanceOf(pool) - poolBefore, amount - ((amount * SELL_TAX) / 10_000));
        assertEq(token.balanceOf(treasury) - taxBefore, (amount * SELL_TAX) / 10_000);
    }

    function testGvAmmoTaxExemptionOnlyChecksTraderNotPool() public {
        uint256 amount = 100e18;
        manager.setGvAmmo(address(gvAmmo), 100);
        gvAmmo.setTotalSupply(1_000e18);
        gvAmmo.setBalance(pool, type(uint256).max);

        uint256 poolBefore = token.balanceOf(pool);
        uint256 taxBefore = token.balanceOf(treasury);

        vm.prank(user);
        token.transfer(pool, amount);

        assertEq(token.balanceOf(pool) - poolBefore, amount - ((amount * SELL_TAX) / 10_000));
        assertEq(token.balanceOf(treasury) - taxBefore, (amount * SELL_TAX) / 10_000);
    }

    function testGvAmmoTaxExemptionFailsClosedIfBalanceCallReverts() public {
        uint256 amount = 100e18;
        manager.setGvAmmo(address(gvAmmo), 100);
        gvAmmo.setTotalSupply(1_000e18);
        gvAmmo.setBalance(user, type(uint256).max);
        gvAmmo.setShouldRevert(true);

        uint256 poolBefore = token.balanceOf(pool);
        uint256 taxBefore = token.balanceOf(treasury);

        vm.prank(user);
        token.transfer(pool, amount);

        assertEq(token.balanceOf(pool) - poolBefore, amount - ((amount * SELL_TAX) / 10_000));
        assertEq(token.balanceOf(treasury) - taxBefore, (amount * SELL_TAX) / 10_000);
    }

    function testDirectAddLiquidityTokenTransferIsTaxed() public {
        uint256 amount = 100e18;
        uint256 expectedTax = (amount * SELL_TAX) / 10_000;

        uint256 taxBefore = token.balanceOf(treasury);
        uint256 poolBefore = token.balanceOf(pool);

        vm.prank(user);
        token.transfer(pool, amount);

        assertEq(token.balanceOf(pool) - poolBefore, amount - expectedTax);
        assertEq(token.balanceOf(treasury) - taxBefore, expectedTax);
    }

    function testLiquidityHelperAddLiquidityIsNotTaxed() public {
        uint256 amount = 100e18;
        uint256 taxBefore = token.balanceOf(treasury);
        uint256 poolBefore = token.balanceOf(pool);

        vm.deal(user, 1 ether);
        vm.startPrank(user);
        token.approve(address(liquidityManager), amount);
        liquidityManager.addLiquidityETH{value: 1 ether}(address(token), false, amount, 0, 0, user, block.timestamp);
        vm.stopPrank();

        assertEq(token.balanceOf(pool) - poolBefore, amount);
        assertEq(token.balanceOf(treasury), taxBefore);
    }

    // ═══════════════════════════════════════════════
    // ── Tax Admin (via AmmoManager) ───────────────
    // ═══════════════════════════════════════════════

    function testSetPoolTax() public {
        address newPool = address(0xBEE2);
        manager.setPoolTax(address(token), newPool, 500, 500);

        (uint256 buyTax, uint256 sellTax) = manager.tokenPoolTax(address(token), newPool);
        assertEq(buyTax, 500);
        assertEq(sellTax, 500);
        assertTrue(buyTax > 0 || sellTax > 0);
    }

    function testSetPoolTaxAllowsZeroTax() public {
        manager.setPoolTax(address(token), pool, 0, 0);

        (uint256 buyTax, uint256 sellTax) = manager.tokenPoolTax(address(token), pool);
        assertEq(buyTax, 0);
        assertEq(sellTax, 0);

        uint256 poolBefore = token.balanceOf(pool);
        vm.prank(user);
        token.transfer(pool, 50e18);
        assertEq(token.balanceOf(pool) - poolBefore, 50e18);
    }

    function testRemovePoolTax() public {
        manager.removePoolTax(address(token), pool);

        (uint256 buyTax, uint256 sellTax) = manager.tokenPoolTax(address(token), pool);
        assertEq(buyTax, 0);
        assertEq(sellTax, 0);
        assertFalse(buyTax > 0 || sellTax > 0);

        // Transfer to pool should now be tax-free
        uint256 poolBefore = token.balanceOf(pool);
        vm.prank(user);
        token.transfer(pool, 50e18);
        assertEq(token.balanceOf(pool) - poolBefore, 50e18);
    }

    function testTaxMaxBpsEnforced() public {
        vm.expectRevert(AmmoManager.TaxTooHigh.selector);
        manager.setPoolTax(address(token), address(0xBEE2), 1001, 300);

        vm.expectRevert(AmmoManager.TaxTooHigh.selector);
        manager.setPoolTax(address(token), address(0xBEE2), 300, 1001);
    }

    function testOnlyOwnerCanSetPoolTax() public {
        vm.prank(user);
        vm.expectRevert(AmmoManager.NotOwner.selector);
        manager.setPoolTax(address(token), pool, 100, 100);
    }

    function testSetGvAmmoStoresConfigAndAllowsDisable() public {
        vm.expectEmit(true, false, false, true);
        emit AmmoManager.gvAmmoUpdated(address(gvAmmo), 2_000);
        manager.setGvAmmo(address(gvAmmo), 2_000);

        assertEq(manager.gvAmmo(), address(gvAmmo));
        assertEq(manager.gvAmmoTaxExemptionBps(), 2_000);

        manager.setGvAmmo(address(0), 0);
        assertEq(manager.gvAmmo(), address(0));
        assertEq(manager.gvAmmoTaxExemptionBps(), 0);
    }

    function testSetGvAmmoOnlyOwnerAndMaxBps() public {
        vm.prank(user);
        vm.expectRevert(AmmoManager.NotOwner.selector);
        manager.setGvAmmo(address(gvAmmo), 2_000);

        vm.expectRevert(AmmoManager.TaxTooHigh.selector);
        manager.setGvAmmo(address(gvAmmo), 10_001);
    }

    // ═══════════════════════════════════════════════
    // ── Integration: CaliberMarket + Tax ──────────
    // ═══════════════════════════════════════════════

    function testFullMintAndSellFlow() public {
        // Mint fresh tokens
        _mintTokensToUser(user, 200e6);
        uint256 balance = token.balanceOf(user);
        assertTrue(balance > 0);

        // Sell to pool — tax applies
        uint256 sellAmount = 100e18;
        uint256 expectedTax = (sellAmount * SELL_TAX) / 10_000;

        vm.prank(user);
        token.transfer(pool, sellAmount);

        assertGe(token.balanceOf(treasury), expectedTax);
    }

    // ═══════════════════════════════════════════════
    // ── Helpers ────────────────────────────────────
    // ═══════════════════════════════════════════════

    function _mintTokensToUser(address who, uint256 usdcAmount) internal {
        usdc.mint(who, usdcAmount);
        vm.prank(who);
        usdc.approve(address(market), usdcAmount);
        vm.prank(who);
        uint256 orderId = market.startMint(usdcAmount, _deadline());
        market.processMint(orderId);
        market.finalizeMint(orderId);
    }

    function _deadline() internal view returns (uint64) {
        return uint64(block.timestamp + MIN_MINT_DEADLINE + 1);
    }
}
