// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface for the canonical WAVAX (or any WETH9-style wrapped native) token.
///         Only the methods AmmoLiquidityManager needs are declared.
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
}
