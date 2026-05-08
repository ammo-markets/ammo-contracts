// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../src/interfaces/IProtocolEmissionController.sol";
import "./MockERC20.sol";

contract MockEmissionController is IProtocolEmissionController {
    MockERC20 public immutable reward;
    uint256 public farmMinted;
    uint256 public caliberVolume;

    constructor(address reward_) {
        reward = MockERC20(reward_);
    }

    function mintFarmReward(address to, uint256 amount) external {
        farmMinted += amount;
        reward.mint(to, amount);
    }

    function recordCaliberMint(uint256 usdcAmount) external {
        caliberVolume += usdcAmount;
    }
}
