// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAmmoToken
/// @notice Interface for the ERC20 token with market-restricted mint/burn and fee-on-transfer tax.
interface IAmmoToken {
    // ── Errors ───────────────────────────────────────

    error NotMarket();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    // ── Events ───────────────���───────────────────────

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event TaxesSold(uint256 tokensSold, address indexed recipient);

    // ── View functions ───────────────────────────────

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function market() external view returns (address);
    function manager() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);

    // ── State-changing functions ─────────────────────

    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}
