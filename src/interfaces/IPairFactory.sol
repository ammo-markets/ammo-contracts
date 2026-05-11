// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Solidly-style factory interface for resolving pair addresses.
/// @dev `getPair` returns address(0) when no pair exists, which lets callers
///      no-op cleanly without separate existence checks.
interface IPairFactory {
    function getPair(address tokenA, address tokenB, bool stable) external view returns (address pair);
}
