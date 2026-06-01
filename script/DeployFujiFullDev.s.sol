// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AmmoFactory.sol";
import "../src/AmmoLiquidityManager.sol";
import "../src/AmmoManager.sol";
import "../src/CaliberMarket.sol";
import "../src/CaliberToken.sol";
import "../src/MockUSDC.sol";
import "../src/PriceOracle.sol";
import "../src/external/exchange/Router.sol";
import "../src/external/exchange/dev/DevAccessHub.sol";
import "../src/external/exchange/factories/PairFactory.sol";

/// @notice One-shot Fuji dev deployment for exchange + Ammo + seeded Caliber/WAVAX pairs.
/// @dev This creates enough state for web swap/liquidity integration against
///      real contracts on Fuji: router, factory, markets, tokens, and LP pairs.
contract DeployFujiFullDev is Script {
    address constant FUJI_WAVAX = 0xd00ae08403B9bbb9124bB305C09058E32C39A48c;

    uint256 constant INITIAL_DAILY_MINT_CAP = 50_000e6;

    uint256 constant BUY_TAX_BPS = 300;
    uint256 constant SELL_TAX_BPS = 300;

    uint256 constant MINT_USDC_9MM = 10_000e6;
    uint256 constant MINT_USDC_556 = 10_000e6;
    // Dust LP seed based on DB prices captured 2026-05-28:
    // 9MM_PRACTICE = $0.33, 556_NATO_PRACTICE = $0.64.
    // AVAX was ~$9.15, so 0.1 AVAX ~= $0.915 of paired CaliberToken.
    uint256 constant AVAX_USD_CENTS = 915;
    uint256 constant PRICE_CENTS_9MM = 33;
    uint256 constant PRICE_CENTS_556 = 64;
    uint256 constant LIQ_AVAX_9MM = 0.1 ether;
    uint256 constant LIQ_AVAX_556 = 0.1 ether;
    uint256 constant LIQ_TOKEN_9MM = (LIQ_AVAX_9MM * AVAX_USD_CENTS) / PRICE_CENTS_9MM;
    uint256 constant LIQ_TOKEN_556 = (LIQ_AVAX_556 * AVAX_USD_CENTS) / PRICE_CENTS_556;

    DevAccessHub public accessHub;
    PairFactory public pairFactory;
    Router public router;

    MockUSDC public usdc;
    AmmoManager public manager;
    AmmoLiquidityManager public liquidityManager;
    PriceOracle public oracle;
    AmmoFactory public factory;

    struct CaliberDeployment {
        bytes32 caliberId;
        address market;
        address token;
        address pair;
        uint256 liquidity;
    }

    CaliberDeployment public deployed9mmPractice;
    CaliberDeployment public deployed556NatoPractice;

    function run() external {
        vm.startBroadcast();

        _deployExchange();
        _deployAmmo();
        _createCalibers();
        _setInitialPrices();
        _mintCaliberInventory();
        _seedLiquidity();
        _smokeCheck();

        vm.stopBroadcast();

        _logAddresses();
    }

    function _deployExchange() internal {
        accessHub = new DevAccessHub(msg.sender, msg.sender);
        pairFactory = new PairFactory(accessHub);
        router = new Router(address(pairFactory), FUJI_WAVAX);
    }

    function _deployAmmo() internal {
        usdc = new MockUSDC();

        manager = new AmmoManager(msg.sender, FUJI_WAVAX);
        manager.setTreasury(msg.sender);
        manager.setGuardian(msg.sender);

        liquidityManager = new AmmoLiquidityManager(address(router));
        manager.setTaxExempt(address(liquidityManager), true);

        oracle = new PriceOracle(address(manager));
        factory = new AmmoFactory(address(manager), address(usdc), 6, address(oracle));

        oracle.setFactory(address(factory));
    }

    function _createCalibers() internal {
        deployed9mmPractice = _createCaliber(bytes32("9MM_PRACTICE"), "Ammo Markets 9MM-FMJ", "9MM-FMJ");
        deployed556NatoPractice = _createCaliber(bytes32("556_NATO_PRACTICE"), "Ammo Markets 5.56-FMJ", "5.56-FMJ");
    }

    function _createCaliber(bytes32 caliberId, string memory tokenName, string memory tokenSymbol)
        internal
        returns (CaliberDeployment memory deployment)
    {
        (address market, address token) = factory.createCaliber(caliberId, tokenName, tokenSymbol, 50);
        manager.setMarketDailyMintCap(market, INITIAL_DAILY_MINT_CAP);

        deployment = CaliberDeployment({
            caliberId: caliberId,
            market: market,
            token: token,
            pair: address(0),
            liquidity: 0
        });
    }

    function _setInitialPrices() internal {
        address[] memory markets = new address[](2);
        uint256[] memory prices = new uint256[](2);

        markets[0] = deployed9mmPractice.market;
        markets[1] = deployed556NatoPractice.market;

        prices[0] = 21e16; // $0.21
        prices[1] = 40e16; // $0.40

        oracle.setBatchPrices(markets, prices);
    }

    function _mintCaliberInventory() internal {
        _mintCaliber(deployed9mmPractice.market, MINT_USDC_9MM);
        _mintCaliber(deployed556NatoPractice.market, MINT_USDC_556);
    }

    function _mintCaliber(address market, uint256 usdcAmount) internal {
        usdc.faucet(usdcAmount);
        usdc.approve(market, usdcAmount);
        uint64 deadline = uint64(block.timestamp + CaliberMarket(market).MIN_MINT_DEADLINE() + 1 hours);
        uint256 orderId = CaliberMarket(market).startMint(usdcAmount, deadline);
        CaliberMarket(market).processMint(orderId);
        CaliberMarket(market).finalizeMint(orderId);
    }

    function _seedLiquidity() internal {
        deployed9mmPractice = _seedOne(deployed9mmPractice, LIQ_TOKEN_9MM, LIQ_AVAX_9MM);
        deployed556NatoPractice = _seedOne(deployed556NatoPractice, LIQ_TOKEN_556, LIQ_AVAX_556);
    }

    function _seedOne(CaliberDeployment memory deployment, uint256 tokenAmount, uint256 avaxAmount)
        internal
        returns (CaliberDeployment memory seeded)
    {
        CaliberToken token = CaliberToken(deployment.token);
        token.approve(address(liquidityManager), tokenAmount);

        (,, uint256 liquidity) = liquidityManager.addLiquidityETH{value: avaxAmount}(
            deployment.token, false, tokenAmount, 0, 0, msg.sender, block.timestamp + 30 minutes
        );

        address pair = pairFactory.getPair(deployment.token, FUJI_WAVAX, false);
        manager.setPoolTax(deployment.token, pair, BUY_TAX_BPS, SELL_TAX_BPS);

        seeded = deployment;
        seeded.pair = pair;
        seeded.liquidity = liquidity;
    }

    function _smokeCheck() internal view {
        _checkOne(deployed9mmPractice);
        _checkOne(deployed556NatoPractice);

        require(pairFactory.allPairsLength() == 2, "unexpected pair count");
        require(address(liquidityManager.router()) == address(router), "liquidity router mismatch");
        require(router.factory() == address(pairFactory), "router factory mismatch");
        require(router.WETH() == FUJI_WAVAX, "router WAVAX mismatch");
        require(manager.taxExempt(address(liquidityManager)), "liquidity helper not exempt");
    }

    function _checkOne(CaliberDeployment memory deployment) internal view {
        require(deployment.market != address(0), "market missing");
        require(deployment.token != address(0), "token missing");
        require(deployment.pair != address(0), "pair missing");
        require(deployment.liquidity > 0, "liquidity missing");
        require(pairFactory.isPair(deployment.pair), "factory does not recognize pair");
        require(pairFactory.getPair(deployment.token, FUJI_WAVAX, false) == deployment.pair, "pair lookup mismatch");
        require(CaliberToken(deployment.token).balanceOf(deployment.pair) > 0, "pair token reserve missing");

        (uint256 buyTax, uint256 sellTax) = manager.tokenPoolTax(deployment.token, deployment.pair);
        require(buyTax == BUY_TAX_BPS, "buy tax mismatch");
        require(sellTax == SELL_TAX_BPS, "sell tax mismatch");
    }

    function _logAddresses() internal view {
        console.log("=== Fuji Full Dev Deployment ===");
        console.log("DevAccessHub:", address(accessHub));
        console.log("PairFactory:", address(pairFactory));
        console.log("Router:", address(router));
        console.log("WAVAX:", FUJI_WAVAX);
        console.log("MockUSDC:", address(usdc));
        console.log("AmmoManager:", address(manager));
        console.log("AmmoLiquidityManager:", address(liquidityManager));
        console.log("PriceOracle:", address(oracle));
        console.log("AmmoFactory:", address(factory));
        console.log("BuyTaxBps:", BUY_TAX_BPS);
        console.log("SellTaxBps:", SELL_TAX_BPS);
        _logCaliber("9MM_PRACTICE", deployed9mmPractice);
        _logCaliber("556_NATO_PRACTICE", deployed556NatoPractice);
    }

    function _logCaliber(string memory label, CaliberDeployment memory deployment) internal pure {
        console.log("---", label, "---");
        console.log("Market:", deployment.market);
        console.log("Token:", deployment.token);
        console.log("Pair:", deployment.pair);
        console.log("InitialLiquidity:", deployment.liquidity);
    }
}
