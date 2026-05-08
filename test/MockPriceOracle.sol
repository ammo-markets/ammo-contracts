// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../src/IPriceOracle.sol";

/// @notice Test oracle with settable price and timestamp.
contract MockPriceOracle is IPriceOracle {
    uint256 public price;
    uint256 public updatedAt;

    constructor(uint256 price_) {
        price = price_;
        updatedAt = block.timestamp;
    }

    function setPrice(uint256 price_) external {
        price = price_;
        updatedAt = block.timestamp;
    }

    /// @notice Allows tests to set a specific updatedAt for staleness testing.
    function setUpdatedAt(uint256 updatedAt_) external {
        updatedAt = updatedAt_;
    }

    function getPriceData() external view override returns (uint256, uint256) {
        return (price, updatedAt);
    }
}
