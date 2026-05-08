// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IProtocolEmissionController {
    function mintFarmReward(address to, uint256 amount) external;
    function recordCaliberMint(uint256 usdcAmount) external;
}
