// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AmmoPriceFunctions.sol";
import "../src/AmmoManager.sol";

/// @notice Deploys the AmmoPriceFunctions consumer contract on Fuji and
///         registers it as a keeper on the existing AmmoManager.
/// @dev Reads configuration from environment variables:
///      - CHAINLINK_ROUTER: Chainlink Functions router address (Fuji)
///      - CHAINLINK_SUB_ID: Functions subscription ID
///      - CHAINLINK_DON_ID: DON ID (bytes32)
///      - ORACLE_ADDRESS: Deployed PriceOracle address
///      - MANAGER_ADDRESS: Deployed AmmoManager address
///      - MARKET_9MM_PRACTICE, MARKET_9MM_SELF_DEFENSE,
///        MARKET_556_SELF_DEFENSE, MARKET_556_NATO_PRACTICE: Market addresses
///      - API_BASE_URL: Base URL for the /api/prices endpoint
contract DeployChainlinkFunctions is Script {
    function run() external {
        // ── Read env ─────────────────────────────────
        address router = vm.envAddress("CHAINLINK_ROUTER");
        uint64 subId = uint64(vm.envUint("CHAINLINK_SUB_ID"));
        bytes32 donId = vm.envBytes32("CHAINLINK_DON_ID");
        address oracleAddr = vm.envAddress("ORACLE_ADDRESS");
        address managerAddr = vm.envAddress("MANAGER_ADDRESS");
        string memory apiBaseUrl = vm.envString("API_BASE_URL");

        // Market addresses (must match caliberKeys order)
        address[] memory markets = new address[](4);
        markets[0] = vm.envAddress("MARKET_9MM_PRACTICE");
        markets[1] = vm.envAddress("MARKET_9MM_SELF_DEFENSE");
        markets[2] = vm.envAddress("MARKET_556_SELF_DEFENSE");
        markets[3] = vm.envAddress("MARKET_556_NATO_PRACTICE");

        string[] memory caliberKeys = new string[](4);
        caliberKeys[0] = "9MM_PRACTICE";
        caliberKeys[1] = "9MM_SELF_DEFENSE";
        caliberKeys[2] = "556_SELF_DEFENSE";
        caliberKeys[3] = "556_NATO_PRACTICE";

        // Read JS source from file
        string memory jsSource = vm.readFile("script/chainlink-functions-source.js");

        vm.startBroadcast();

        // 1. Deploy consumer
        AmmoPriceFunctions consumer = new AmmoPriceFunctions(router, subId, donId, oracleAddr, markets, caliberKeys);

        // 2. Set API URL and JS source
        consumer.setApiBaseUrl(apiBaseUrl);
        consumer.setSource(jsSource);

        // 3. Register as keeper on AmmoManager
        AmmoManager manager = AmmoManager(managerAddr);
        manager.setKeeper(address(consumer), true);

        vm.stopBroadcast();

        console.log("AmmoPriceFunctions deployed at:", address(consumer));
        console.log("Registered as keeper on AmmoManager");
        console.log("API Base URL:", apiBaseUrl);
    }
}
