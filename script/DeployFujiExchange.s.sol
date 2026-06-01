// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/external/exchange/Router.sol";
import "../src/external/exchange/dev/DevAccessHub.sol";
import "../src/external/exchange/factories/PairFactory.sol";

/// @notice Deploys a Pharaoh-compatible legacy AMM stack for Fuji development.
/// @dev This intentionally deploys only the pieces Ammo needs for swap and LP
///      testing: a minimal AccessHub shim, PairFactory, and Router.
contract DeployFujiExchange is Script {
    address constant FUJI_WAVAX = 0xd00ae08403B9bbb9124bB305C09058E32C39A48c;

    DevAccessHub public accessHub;
    PairFactory public pairFactory;
    Router public router;

    function run() external {
        vm.startBroadcast();

        accessHub = new DevAccessHub(msg.sender, msg.sender);
        pairFactory = new PairFactory(accessHub);
        router = new Router(address(pairFactory), FUJI_WAVAX);

        vm.stopBroadcast();

        console.log("=== Fuji Exchange Dev Stack ===");
        console.log("DevAccessHub:", address(accessHub));
        console.log("PairFactory:", address(pairFactory));
        console.log("Router:", address(router));
        console.log("WAVAX:", FUJI_WAVAX);
        console.logBytes32(pairFactory.pairCodeHash());
    }
}
