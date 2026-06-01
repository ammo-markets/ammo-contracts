// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AmmoLiquidityManager.sol";
import "../src/AmmoManager.sol";
import "../src/CaliberToken.sol";
import "../src/CaliberMarket.sol";
import "../src/interfaces/ICaliberMarket.sol";
import {IDexRouter} from "../src/interfaces/IDexRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MockERC20.sol";
import "./MockPriceOracle.sol";

interface IPairFactoryFork {
    function getPair(address tokenA, address tokenB, bool stable) external view returns (address pair);
    function isPair(address pair) external view returns (bool);
}

interface IPharaohRouterFork is IDexRouter {
    function removeLiquidityETH(
        address token,
        bool stable,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);
}

/// @notice Fork test for CaliberToken tax collection on the production DEX router.
/// @dev Set AVALANCHE_RPC_URL to run:
///      forge test --match-contract CaliberTokenTaxForkTest -vv
contract CaliberTokenTaxForkTest is Test {
    address constant PAIR_FACTORY = 0x85448bF2F589ab1F56225DF5167c63f57758f8c1;
    address constant DEX_ROUTER = 0x9CEE04bDcE127DA7E448A333f006DEFb3d5e38cC;

    uint64 constant MIN_MINT_DEADLINE = 24 hours;
    uint256 constant BUY_TAX = 300;
    uint256 constant SELL_TAX = 300;

    AmmoManager manager;
    CaliberMarket market;
    CaliberToken token;
    AmmoLiquidityManager liquidityManager;
    MockERC20 usdc;
    MockPriceOracle oracle;

    address wavax;
    address pair;
    address user = address(0xBEEF);
    address liquidityProvider = address(0xCAFE);
    address treasury = address(0x73EA5);
    address feeRecipient = address(0xFEE1);

    function setUp() public {
        string memory rpcUrl = vm.envOr("AVALANCHE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true, "set AVALANCHE_RPC_URL to run production DEX fork tests");
            return;
        }

        vm.createSelectFork(rpcUrl);

        assertGt(DEX_ROUTER.code.length, 0, "router missing on fork");
        assertGt(PAIR_FACTORY.code.length, 0, "pair factory missing on fork");

        wavax = IDexRouter(DEX_ROUTER).WETH();
        assertGt(wavax.code.length, 0, "router WETH missing on fork");
        assertEq(IDexRouter(DEX_ROUTER).factory(), PAIR_FACTORY, "unexpected router factory");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockPriceOracle(21e16);

        manager = new AmmoManager(feeRecipient, wavax);
        manager.setTreasury(treasury);
        manager.setKeeper(address(this), true);

        liquidityManager = new AmmoLiquidityManager(DEX_ROUTER);
        manager.setTaxExempt(address(liquidityManager), true);

        market = new CaliberMarket(
            ICaliberMarket.MarketConfig({
                manager: address(manager),
                usdc: address(usdc),
                usdcDecimals: 6,
                oracle: address(oracle),
                caliberId: bytes32("9MM_TEST"),
                tokenName: "Ammo 9MM",
                tokenSymbol: "9MM-T",
                minMintRounds: 0
            })
        );
        token = market.token();
        manager.setMarketDailyMintCap(address(market), type(uint256).max);

        _mintTokensTo(user, 10_000e6);
        _mintTokensTo(liquidityProvider, 50_000e6);
        _addInitialLiquidity();

        manager.setPoolTax(address(token), pair, BUY_TAX, SELL_TAX);
    }

    function testForkUsesProvidedDexAddresses() public view {
        assertEq(IDexRouter(DEX_ROUTER).factory(), PAIR_FACTORY);
        assertEq(IPairFactoryFork(PAIR_FACTORY).getPair(address(token), wavax, false), pair);
        assertTrue(IPairFactoryFork(PAIR_FACTORY).isPair(pair));
    }

    function testForkSellTaxSentDirectlyToTreasury() public {
        uint256 sellAmount = 100e18;
        uint256 expectedTax = (sellAmount * SELL_TAX) / 10_000;
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.startPrank(user);
        token.approve(DEX_ROUTER, sellAmount);
        IDexRouter.route[] memory routes = _route(address(token), wavax);
        IDexRouter(DEX_ROUTER)
            .swapExactTokensForETHSupportingFeeOnTransferTokens(sellAmount, 0, routes, user, block.timestamp);
        vm.stopPrank();

        assertApproxEqAbs(token.balanceOf(treasury) - treasuryBefore, expectedTax, 1, "sell tax sent to treasury");
        assertEq(token.balanceOf(address(token)), 0, "token contract holds no tax balance");
    }

    function testForkBuyTaxSentDirectlyToTreasury() public {
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 userBefore = token.balanceOf(user);
        uint256 buyAmount = 1 ether;

        vm.deal(user, buyAmount);
        vm.prank(user);
        IDexRouter.route[] memory routes = _route(wavax, address(token));
        IDexRouter(DEX_ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: buyAmount}(
            0, routes, user, block.timestamp
        );

        assertGt(token.balanceOf(user), userBefore, "user should receive tokens");
        assertGt(token.balanceOf(treasury), treasuryBefore, "buy tax sent to treasury");
        assertEq(token.balanceOf(address(token)), 0, "token contract holds no tax balance");
    }

    function testForkLiquidityHelperAddLiquidityIsNotTaxed() public {
        uint256 amount = 100e18;
        uint256 taxBefore = token.balanceOf(treasury);
        uint256 pairBefore = token.balanceOf(pair);

        vm.deal(user, 1 ether);
        vm.startPrank(user);
        token.approve(address(liquidityManager), amount);
        liquidityManager.addLiquidityETH{value: 1 ether}(address(token), false, amount, 0, 0, user, block.timestamp);
        vm.stopPrank();

        assertEq(token.balanceOf(treasury), taxBefore, "helper should not collect tax");
        assertEq(token.balanceOf(pair) - pairBefore, amount, "pair should receive full token amount");
    }

    function testForkDirectPharaohAddLiquidityETHIsTaxedButDoesNotRevert() public {
        uint256 amount = 100e18;
        uint256 expectedTax = (amount * SELL_TAX) / 10_000;

        uint256 taxBefore = token.balanceOf(treasury);
        uint256 pairTokenBefore = token.balanceOf(pair);
        uint256 pairWavaxBefore = IERC20(wavax).balanceOf(pair);

        vm.deal(user, 1 ether);
        vm.startPrank(user);
        token.approve(DEX_ROUTER, amount);
        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = IDexRouter(DEX_ROUTER)
        .addLiquidityETH{value: 1 ether}(
            address(token), false, amount, 0, 0, user, block.timestamp
        );
        vm.stopPrank();

        assertEq(amountToken, amount, "router reports gross AMMO amount used");
        assertGt(amountETH, 0, "router used native AVAX");
        assertGt(liquidity, 0, "direct add still minted LP");
        assertEq(token.balanceOf(treasury) - taxBefore, expectedTax, "sell tax sent to treasury on direct add");
        assertEq(token.balanceOf(pair) - pairTokenBefore, amount - expectedTax, "pair received net AMMO");
        assertEq(IERC20(wavax).balanceOf(pair) - pairWavaxBefore, amountETH, "pair received router-quoted WAVAX");
    }

    /// @dev End-to-end proof that swaps through the production Pharaoh router are taxed
    ///      exactly as the CaliberToken contract intends — no mocks, no shims. Runs a sell
    ///      and a buy back-to-back, asserting the full accounting identity on each leg:
    ///        user_spent == pair_received + contract_taxed       (sell)
    ///        pair_released == user_received + contract_taxed    (buy)
    function testForkPharaohSwapsAreTaxed() public {
        // ── Sell leg ──────────────────────────────────────────────────────────
        uint256 sellAmount = 100e18;
        uint256 expectedSellTax = (sellAmount * SELL_TAX) / 10_000;

        uint256 userTokenBefore = token.balanceOf(user);
        uint256 pairTokenBefore = token.balanceOf(pair);
        uint256 contractTokenBefore = token.balanceOf(treasury);
        uint256 userAvaxBefore = user.balance;

        vm.startPrank(user);
        token.approve(DEX_ROUTER, sellAmount);
        IDexRouter.route[] memory sellRoutes = _route(address(token), wavax);
        IDexRouter(DEX_ROUTER)
            .swapExactTokensForETHSupportingFeeOnTransferTokens(sellAmount, 0, sellRoutes, user, block.timestamp);
        vm.stopPrank();

        uint256 userTokenSpent = userTokenBefore - token.balanceOf(user);
        uint256 pairTokenReceived = token.balanceOf(pair) - pairTokenBefore;
        uint256 contractTaxFromSell = token.balanceOf(treasury) - contractTokenBefore;

        assertEq(userTokenSpent, sellAmount, "sell: user spent exactly sellAmount");
        assertEq(pairTokenReceived, sellAmount - expectedSellTax, "sell: pair received post-tax amount");
        assertEq(contractTaxFromSell, expectedSellTax, "sell: contract accumulated the sell tax");
        assertEq(userTokenSpent, pairTokenReceived + contractTaxFromSell, "sell: accounting balances to zero");
        assertGt(user.balance - userAvaxBefore, 0, "sell: user received native AVAX");

        // ── Buy leg ───────────────────────────────────────────────────────────
        uint256 buyAvax = 0.5 ether;
        vm.deal(user, buyAvax);

        uint256 userTokenBeforeBuy = token.balanceOf(user);
        uint256 pairTokenBeforeBuy = token.balanceOf(pair);
        uint256 contractTokenBeforeBuy = token.balanceOf(treasury);

        vm.prank(user);
        IDexRouter.route[] memory buyRoutes = _route(wavax, address(token));
        IDexRouter(DEX_ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: buyAvax}(
            0, buyRoutes, user, block.timestamp
        );

        uint256 pairTokenReleased = pairTokenBeforeBuy - token.balanceOf(pair);
        uint256 userTokenReceived = token.balanceOf(user) - userTokenBeforeBuy;
        uint256 contractTaxFromBuy = token.balanceOf(treasury) - contractTokenBeforeBuy;
        uint256 expectedBuyTax = (pairTokenReleased * BUY_TAX) / 10_000;

        assertGt(pairTokenReleased, 0, "buy: pair released non-zero AMMO");
        assertEq(contractTaxFromBuy, expectedBuyTax, "buy: contract accumulated the buy tax");
        assertEq(userTokenReceived, pairTokenReleased - expectedBuyTax, "buy: user received post-tax amount");
        assertEq(pairTokenReleased, userTokenReceived + contractTaxFromBuy, "buy: accounting balances to zero");
    }

    function testForkLiquidityHelperRemoveLiquidityIsNotTaxed() public {
        // 1. Seed `user` with LP through the helper's add path so we have something to remove.
        uint256 addAmount = 100e18;
        vm.deal(user, 1 ether);
        vm.startPrank(user);
        token.approve(address(liquidityManager), addAmount);
        (,, uint256 liquidity) = liquidityManager.addLiquidityETH{value: 1 ether}(
            address(token), false, addAmount, 0, 0, user, block.timestamp
        );
        vm.stopPrank();

        assertGt(liquidity, 0, "user should hold LP after add");
        assertEq(IERC20(pair).balanceOf(user), liquidity, "user owns the freshly minted LP");

        // 2. Snapshot state immediately before the remove.
        uint256 taxBefore = token.balanceOf(treasury);
        uint256 userTokenBefore = token.balanceOf(user);
        uint256 userAvaxBefore = user.balance;

        // 3. Remove all of the user's liquidity via the helper.
        vm.startPrank(user);
        IERC20(pair).approve(address(liquidityManager), liquidity);
        (uint256 returnedToken, uint256 returnedAVAX) =
            liquidityManager.removeLiquidityETH(address(token), false, liquidity, 0, 0, user, block.timestamp);
        vm.stopPrank();

        // 4. Assertions: LP burned, no tax collected, exact AMMO + native AVAX delivered.
        assertEq(IERC20(pair).balanceOf(user), 0, "all LP burned");
        assertEq(token.balanceOf(treasury), taxBefore, "no tax collected during remove");
        assertEq(token.balanceOf(user) - userTokenBefore, returnedToken, "user received full AMMO amount");
        assertEq(user.balance - userAvaxBefore, returnedAVAX, "user received native AVAX (unwrapped)");
        assertGt(returnedToken, 0, "non-zero AMMO returned");
        assertGt(returnedAVAX, 0, "non-zero AVAX returned");

        // 5. Helper holds no residual balances after the operation.
        assertEq(token.balanceOf(address(liquidityManager)), 0, "helper drained of AMMO");
        assertEq(IERC20(wavax).balanceOf(address(liquidityManager)), 0, "helper drained of WAVAX");
        assertEq(address(liquidityManager).balance, 0, "helper drained of native AVAX");
        assertEq(IERC20(pair).allowance(address(liquidityManager), DEX_ROUTER), 0, "helper's LP approval reset to zero");
    }

    function testForkDirectPharaohRemoveLiquidityETHRevertsWhenAmmoLegIsTaxed() public {
        uint256 addAmount = 100e18;
        vm.deal(user, 1 ether);
        vm.startPrank(user);
        token.approve(address(liquidityManager), addAmount);
        (,, uint256 liquidity) = liquidityManager.addLiquidityETH{value: 1 ether}(
            address(token), false, addAmount, 0, 0, user, block.timestamp
        );

        IERC20(pair).approve(DEX_ROUTER, liquidity);
        vm.expectRevert();
        IPharaohRouterFork(DEX_ROUTER).removeLiquidityETH(address(token), false, liquidity, 0, 0, user, block.timestamp);
        vm.stopPrank();
    }

    function _addInitialLiquidity() internal {
        uint256 tokenAmount = 25_000e18;
        uint256 nativeAmount = 100 ether;

        vm.deal(liquidityProvider, nativeAmount);
        vm.startPrank(liquidityProvider);
        token.approve(DEX_ROUTER, tokenAmount);
        IDexRouter(DEX_ROUTER).addLiquidityETH{value: nativeAmount}(
            address(token), false, tokenAmount, 0, 0, liquidityProvider, block.timestamp
        );
        vm.stopPrank();

        pair = IPairFactoryFork(PAIR_FACTORY).getPair(address(token), wavax, false);
        assertTrue(pair != address(0), "pair should exist");
        assertTrue(IPairFactoryFork(PAIR_FACTORY).isPair(pair), "factory should recognize pair");
    }

    function _mintTokensTo(address who, uint256 usdcAmount) internal {
        usdc.mint(who, usdcAmount);
        vm.startPrank(who);
        usdc.approve(address(market), usdcAmount);
        uint256 orderId = market.startMint(usdcAmount, _deadline());
        vm.stopPrank();
        market.processMint(orderId);
        market.finalizeMint(orderId);
    }

    function _deadline() internal view returns (uint64) {
        return uint64(block.timestamp + MIN_MINT_DEADLINE + 1);
    }

    function _route(address from, address to) internal pure returns (IDexRouter.route[] memory routes) {
        routes = new IDexRouter.route[](1);
        routes[0] = IDexRouter.route({from: from, to: to, stable: false});
    }

    receive() external payable {}
}
