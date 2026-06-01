// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/MockUSDC.sol";
import "../src/PriceOracle.sol";
import "../src/AmmoManager.sol";
import "../src/AmmoFactory.sol";

/// @notice Single deploy script for the full Ammo Exchange protocol on Fuji testnet.
/// @dev Deploys MockUSDC, AmmoManager (with roles), PriceOracle, AmmoFactory,
///      and 2 FMJ calibers. All testnet roles are set to the deployer.
contract DeployFuji is Script {
    /// @dev Fuji WAVAX. The DEX router is intentionally left unset on Fuji
    ///      because the production Pharaoh router is not deployed there.
    address constant FUJI_WAVAX = 0xd00ae08403B9bbb9124bB305C09058E32C39A48c;
    address constant DEX_ROUTER = address(0);

    MockUSDC public usdc;
    AmmoManager public manager;
    PriceOracle public oracle;
    AmmoFactory public factory;

    uint256 constant INITIAL_DAILY_MINT_CAP = 50_000e6;

    struct CaliberDeployment {
        address market;
        address token;
    }

    CaliberDeployment public deployed9mmPractice;
    CaliberDeployment public deployed556NatoPractice;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy MockUSDC
        usdc = new MockUSDC();

        // 2. Deploy AmmoManager (constructor sets owner=msg.sender, keepers[msg.sender]=true, feeRecipient=msg.sender)
        manager = new AmmoManager(msg.sender, FUJI_WAVAX);
        manager.setTreasury(msg.sender);
        manager.setGuardian(msg.sender);

        // 3. Deploy PriceOracle
        oracle = new PriceOracle(address(manager));

        // 4. Deploy AmmoFactory with oracle
        factory = new AmmoFactory(address(manager), address(usdc), 6, address(oracle));

        // 5. Set oracle factory (enables auto-registration of markets)
        oracle.setFactory(address(factory));

        // 6. Create launch FMJ calibers (factory auto-registers each with oracle)
        _deploy9mmPractice();
        _deploy556NatoPractice();

        // 7. Set initial prices via batch update
        _setInitialPrices();

        vm.stopBroadcast();

        _logAddresses();
    }

    function _deploy9mmPractice() internal {
        (address market, address token) =
            factory.createCaliber(bytes32("9MM_PRACTICE"), "Ammo Markets 9MM-FMJ", "9MM-FMJ", 50);
        manager.setMarketDailyMintCap(market, INITIAL_DAILY_MINT_CAP);
        deployed9mmPractice = CaliberDeployment(market, token);
    }

    function _deploy556NatoPractice() internal {
        (address market, address token) =
            factory.createCaliber(bytes32("556_NATO_PRACTICE"), "Ammo Markets 5.56-FMJ", "5.56-FMJ", 50);
        manager.setMarketDailyMintCap(market, INITIAL_DAILY_MINT_CAP);
        deployed556NatoPractice = CaliberDeployment(market, token);
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

    function _logAddresses() internal view {
        console.log("=== Deployed Addresses ===");
        console.log("MockUSDC:", address(usdc));
        console.log("AmmoManager:", address(manager));
        console.log("PriceOracle:", address(oracle));
        console.log("AmmoFactory:", address(factory));
        console.log("WAVAX:", FUJI_WAVAX);
        console.log("Router:", DEX_ROUTER);
        console.log("--- 9MM_PRACTICE ---");
        console.log("Market:", deployed9mmPractice.market);
        console.log("Token:", deployed9mmPractice.token);
        console.log("--- 556_NATO_PRACTICE ---");
        console.log("Market:", deployed556NatoPractice.market);
        console.log("Token:", deployed556NatoPractice.token);
    }
}
