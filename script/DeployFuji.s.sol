// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/MockUSDC.sol";
import "../src/PriceOracle.sol";
import "../src/AmmoManager.sol";
import "../src/AmmoFactory.sol";
import "../src/AmmoLiquidityManager.sol";
import "../src/ProtocolEmissionController.sol";
import "../src/ProtocolToken.sol";
import "../src/interfaces/IDexRouter.sol";

/// @notice Single deploy script for the full Ammo Exchange protocol on Fuji testnet.
/// @dev Deploys MockUSDC, AmmoManager (with roles), PriceOracle, AmmoFactory,
///      and 4 calibers. All testnet roles are set to the deployer.
contract DeployFuji is Script {
    /// @dev PairFactory on the target DEX.
    address constant PAIR_FACTORY = 0x85448bF2F589ab1F56225DF5167c63f57758f8c1;
    /// @dev Uniswap type router on the target DEX.
    address constant DEX_ROUTER = 0x9CEE04bDcE127DA7E448A333f006DEFb3d5e38cC;

    MockUSDC public usdc;
    AmmoManager public manager;
    AmmoLiquidityManager public liquidityManager;
    ProtocolToken public protocolToken;
    ProtocolEmissionController public emissionController;
    PriceOracle public oracle;
    AmmoFactory public factory;

    uint256 constant FARM_CAP = 365_000_000e18;
    uint256 constant TREASURY_CAP = (FARM_CAP * 40) / 60;
    uint256 constant TREASURY_VOLUME_TARGET = 10_000_000e6;

    struct CaliberDeployment {
        address market;
        address token;
    }

    CaliberDeployment public deployed9mmPractice;
    CaliberDeployment public deployed9mmSelfDefense;
    CaliberDeployment public deployed556SelfDefense;
    CaliberDeployment public deployed556NatoPractice;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy MockUSDC
        usdc = new MockUSDC();

        address wrappedNative = IDexRouter(DEX_ROUTER).WETH();

        // 2. Deploy AmmoManager (constructor sets owner=msg.sender, keepers[msg.sender]=true, feeRecipient=msg.sender)
        manager = new AmmoManager(msg.sender, wrappedNative);
        manager.setTreasury(msg.sender);
        manager.setGuardian(msg.sender);
        manager.setDexRouter(DEX_ROUTER);

        // 3. Deploy tax-exempt liquidity helper
        liquidityManager = new AmmoLiquidityManager(DEX_ROUTER);
        manager.setTaxExempt(address(liquidityManager), true);

        // 4. Deploy PriceOracle
        oracle = new PriceOracle(address(manager));

        // 5. Deploy AmmoFactory with oracle
        factory = new AmmoFactory(address(manager), address(usdc), 6, address(oracle));

        // 6. Deploy protocol emission stack and lock the mint path
        protocolToken = new ProtocolToken("Ammo Protocol", "AMMO", address(manager));
        emissionController = new ProtocolEmissionController(
            address(manager), address(factory), address(protocolToken), FARM_CAP, TREASURY_CAP, TREASURY_VOLUME_TARGET
        );
        protocolToken.setMinterOnce(address(emissionController));
        factory.setEmissionControllerOnce(address(emissionController));

        // 7. Set oracle factory (enables auto-registration of markets)
        oracle.setFactory(address(factory));

        // 8. Create 4 calibers (factory auto-registers each with oracle)
        _deploy9mmPractice();
        _deploy9mmSelfDefense();
        _deploy556SelfDefense();
        _deploy556NatoPractice();

        // 9. Set initial prices via batch update
        _setInitialPrices();

        vm.stopBroadcast();

        _logAddresses();
    }

    function _deploy9mmPractice() internal {
        (address market, address token) =
            factory.createCaliber(bytes32("9MM_PRACTICE"), "Ammo Exchange 9mm Practice", "9MM-P", 150, 150, 50);
        deployed9mmPractice = CaliberDeployment(market, token);
    }

    function _deploy9mmSelfDefense() internal {
        (address market, address token) =
            factory.createCaliber(bytes32("9MM_SELF_DEFENSE"), "Ammo Exchange 9mm Self Defense", "9MM-SD", 150, 150, 50);
        deployed9mmSelfDefense = CaliberDeployment(market, token);
    }

    function _deploy556SelfDefense() internal {
        (address market, address token) = factory.createCaliber(
            bytes32("556_SELF_DEFENSE"), "Ammo Exchange 5.56 Self Defense", "556-SD", 150, 150, 50
        );
        deployed556SelfDefense = CaliberDeployment(market, token);
    }

    function _deploy556NatoPractice() internal {
        (address market, address token) = factory.createCaliber(
            bytes32("556_NATO_PRACTICE"), "Ammo Exchange 5.56 NATO Practice", "556-P", 150, 150, 50
        );
        deployed556NatoPractice = CaliberDeployment(market, token);
    }

    function _setInitialPrices() internal {
        address[] memory markets = new address[](4);
        uint256[] memory prices = new uint256[](4);

        markets[0] = deployed9mmPractice.market;
        markets[1] = deployed9mmSelfDefense.market;
        markets[2] = deployed556SelfDefense.market;
        markets[3] = deployed556NatoPractice.market;

        prices[0] = 21e16; // $0.21
        prices[1] = 45e16; // $0.45
        prices[2] = 55e16; // $0.55
        prices[3] = 40e16; // $0.40

        oracle.setBatchPrices(markets, prices);
    }

    function _logAddresses() internal view {
        console.log("=== Deployed Addresses ===");
        console.log("MockUSDC:", address(usdc));
        console.log("AmmoManager:", address(manager));
        console.log("AmmoLiquidityManager:", address(liquidityManager));
        console.log("ProtocolToken:", address(protocolToken));
        console.log("ProtocolEmissionController:", address(emissionController));
        console.log("PriceOracle:", address(oracle));
        console.log("AmmoFactory:", address(factory));
        console.log("PairFactory:", PAIR_FACTORY);
        console.log("Router:", DEX_ROUTER);
        console.log("--- 9MM_PRACTICE ---");
        console.log("Market:", deployed9mmPractice.market);
        console.log("Token:", deployed9mmPractice.token);
        console.log("--- 9MM_SELF_DEFENSE ---");
        console.log("Market:", deployed9mmSelfDefense.market);
        console.log("Token:", deployed9mmSelfDefense.token);
        console.log("--- 556_SELF_DEFENSE ---");
        console.log("Market:", deployed556SelfDefense.market);
        console.log("Token:", deployed556SelfDefense.token);
        console.log("--- 556_NATO_PRACTICE ---");
        console.log("Market:", deployed556NatoPractice.market);
        console.log("Token:", deployed556NatoPractice.token);
    }
}
