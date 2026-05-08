// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Oracle interface for ammo round pricing.
/// @dev Implementations must return the price of one round denominated in USDC,
///      scaled to 18 decimals (1e18 = 1 USDC per round), plus the timestamp
///      of the last price update.
interface IPriceOracle {
    /// @notice Returns the current price and last-update timestamp for msg.sender.
    /// @return priceX18  Price of one round in USDC (1e18 scale).
    /// @return updatedAt Block timestamp of the last price update.
    function getPriceData() external view returns (uint256 priceX18, uint256 updatedAt);
}
