// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Solidly pair interface for reading the built-in TWAP.
/// @dev `current` returns a manipulation-resistant time-weighted average
///      computed from the pair's internal observation buffer (≥30 minute
///      windows, refreshed automatically on swaps). It reverts when the
///      buffer cannot produce a quote (e.g. same-block as the only
///      observation). Callers MUST wrap in try/catch.
interface ISolidlyPair {
    function current(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut);
}
