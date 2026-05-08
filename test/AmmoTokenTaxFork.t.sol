// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AmmoLiquidityManager.sol";
import "../src/AmmoManager.sol";
import "../src/AmmoToken.sol";
import "../src/CaliberMarket.sol";
import {IDexRouter} from "../src/interfaces/IDexRouter.sol";
import "./MockERC20.sol";
import "./MockEmissionController.sol";
import "./MockPriceOracle.sol";

interface IPairFactoryFork {
    function getPair(address tokenA, address tokenB, bool stable) external view returns (address pair);
    function isPair(address pair) external view returns (bool);
}

/// @notice Fork test for AmmoToken tax collection and tax selling through the production DEX router.
/// @dev Set AVALANCHE_RPC_URL to run:
///      forge test --match-contract AmmoTokenTaxForkTest -vv
contract AmmoTokenTaxForkTest is Test {
    address constant PAIR_FACTORY = 0x85448bF2F589ab1F56225DF5167c63f57758f8c1;
    address constant DEX_ROUTER = 0x9CEE04bDcE127DA7E448A333f006DEFb3d5e38cC;

    uint256 constant BUY_TAX = 300;
    uint256 constant SELL_TAX = 300;

    AmmoManager manager;
    CaliberMarket market;
    AmmoToken token;
    AmmoLiquidityManager liquidityManager;
    MockERC20 usdc;
    MockEmissionController emissionController;
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
        emissionController = new MockEmissionController(address(new MockERC20("Protocol", "AMMO", 18)));

        manager = new AmmoManager(feeRecipient, wavax);
        manager.setTreasury(treasury);
        manager.setDexRouter(DEX_ROUTER);
        manager.setKeeper(address(this), true);

        liquidityManager = new AmmoLiquidityManager(DEX_ROUTER);
        manager.setTaxExempt(address(liquidityManager), true);

        market = new CaliberMarket(
            CaliberMarket.MarketConfig({
                manager: address(manager),
                usdc: address(usdc),
                usdcDecimals: 6,
                oracle: address(oracle),
                emissionController: address(emissionController),
                caliberId: bytes32("9MM_TEST"),
                tokenName: "Ammo 9MM",
                tokenSymbol: "9MM-T",
                mintFeeBps: 150,
                redeemFeeBps: 150,
                minMintRounds: 0
            })
        );
        token = market.token();

        _mintTokensTo(user, 10_000e6);
        _mintTokensTo(liquidityProvider, 50_000e6);
        _addInitialLiquidity();

        manager.setPoolTax(address(token), pair, BUY_TAX, SELL_TAX);
        manager.setSwapPath(address(token), wavax, false);
        manager.setTaxSwapThreshold(address(token), 1e18);
    }

    function testForkUsesProvidedDexAddresses() public view {
        assertEq(IDexRouter(DEX_ROUTER).factory(), PAIR_FACTORY);
        assertEq(IPairFactoryFork(PAIR_FACTORY).getPair(address(token), wavax, false), pair);
        assertTrue(IPairFactoryFork(PAIR_FACTORY).isPair(pair));
    }

    function testForkSellTaxCollectedWithoutAutoSwapDuringSell() public {
        uint256 sellAmount = 100e18;
        uint256 expectedTax = (sellAmount * SELL_TAX) / 10_000;

        vm.startPrank(user);
        token.approve(DEX_ROUTER, sellAmount);
        IDexRouter.route[] memory routes = _route(address(token), wavax);
        IDexRouter(DEX_ROUTER)
            .swapExactTokensForETHSupportingFeeOnTransferTokens(sellAmount, 0, routes, user, block.timestamp);
        vm.stopPrank();

        assertApproxEqAbs(token.balanceOf(address(token)), expectedTax, 1, "sell tax collected");
        assertEq(treasury.balance, 0, "sell should not auto-swap taxes");
    }

    function testForkBuyTaxCollectedWithoutAutoSwapDuringBuy() public {
        uint256 taxBefore = token.balanceOf(address(token));
        uint256 userBefore = token.balanceOf(user);
        uint256 buyAmount = 1 ether;

        vm.deal(user, buyAmount);
        vm.prank(user);
        IDexRouter.route[] memory routes = _route(wavax, address(token));
        IDexRouter(DEX_ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: buyAmount}(
            0, routes, user, block.timestamp
        );

        assertGt(token.balanceOf(user), userBefore, "user should receive tokens");
        assertGt(token.balanceOf(address(token)), taxBefore, "buy tax collected");
        assertEq(treasury.balance, 0, "buy should not auto-swap taxes");
    }

    function testForkRegularTransferFlushesAccumulatedTaxes() public {
        vm.startPrank(user);
        token.approve(DEX_ROUTER, 200e18);
        IDexRouter.route[] memory routes = _route(address(token), wavax);
        IDexRouter(DEX_ROUTER)
            .swapExactTokensForETHSupportingFeeOnTransferTokens(200e18, 0, routes, user, block.timestamp);
        vm.stopPrank();

        assertGe(token.balanceOf(address(token)), manager.taxSwapThresholds(address(token)));

        uint256 treasuryBefore = treasury.balance;
        vm.prank(user);
        token.transfer(address(0xABCD), 1e18);

        assertGt(treasury.balance, treasuryBefore, "treasury should receive native AVAX");
        assertEq(token.balanceOf(address(token)), 0, "tax balance should be sold");
    }

    function testForkLiquidityHelperAddLiquidityIsNotTaxed() public {
        uint256 amount = 100e18;
        uint256 taxBefore = token.balanceOf(address(token));
        uint256 pairBefore = token.balanceOf(pair);

        vm.deal(user, 1 ether);
        vm.startPrank(user);
        token.approve(address(liquidityManager), amount);
        liquidityManager.addLiquidityETH{value: 1 ether}(address(token), false, amount, 0, 0, user, block.timestamp);
        vm.stopPrank();

        assertEq(token.balanceOf(address(token)), taxBefore, "helper should not collect tax");
        assertEq(token.balanceOf(pair) - pairBefore, amount, "pair should receive full token amount");
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
        market.mint(usdcAmount);
        vm.stopPrank();
    }

    function _route(address from, address to) internal pure returns (IDexRouter.route[] memory routes) {
        routes = new IDexRouter.route[](1);
        routes[0] = IDexRouter.route({from: from, to: to, stable: false});
    }

    receive() external payable {}
}
