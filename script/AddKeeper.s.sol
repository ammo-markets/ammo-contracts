// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AmmoManager.sol";

/// @notice Authorize a keeper on the shared Fuji AmmoManager.
/// @dev Broadcaster (--private-key) must be the AmmoManager owner.
contract AddKeeper is Script {
    AmmoManager constant MANAGER = AmmoManager(0x26d9f8D0f3F4dFCc67245BaAfCe1Bf8c3E352985);
    address constant KEEPER = 0xFa760444A229e78A50Ca9b3779f4ce4CcE10E170;

    function run() external {
        console.log("AmmoManager:", address(MANAGER));
        console.log("Keeper:     ", KEEPER);
        console.log("Was keeper? ", MANAGER.isKeeper(KEEPER));

        vm.startBroadcast();
        MANAGER.setKeeper(KEEPER, true);
        vm.stopBroadcast();

        console.log("Is keeper?  ", MANAGER.isKeeper(KEEPER));
    }
}
