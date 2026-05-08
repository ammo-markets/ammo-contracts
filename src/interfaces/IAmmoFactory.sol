// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAmmoFactory
/// @notice Interface for the factory that deploys per-caliber CaliberMarket + AmmoToken pairs.
interface IAmmoFactory {
    // ── Structs ──────────────────────────────────────

    struct CaliberInfo {
        address market;
        address token;
    }

    // ── Errors ───────────────────────────────────────

    error NotOwner();
    error CaliberExists();
    error ZeroAddress();

    // ── Events ───────────────────────────────────────

    event CaliberCreated(bytes32 indexed caliberId, address indexed market, address indexed token);

    // ── View functions ───────────────────────────────

    function manager() external view returns (address);
    function usdc() external view returns (address);
    function usdcDecimals() external view returns (uint8);
    function calibers(bytes32 caliberId) external view returns (address market, address token);
    function caliberIds(uint256 index) external view returns (bytes32);
    function getCaliberCount() external view returns (uint256);

    // ── State-changing functions ─────────────────────

    /// @notice Deploy a new caliber market + token pair.
    /// @return market The deployed CaliberMarket address.
    /// @return token  The deployed AmmoToken address (created by the market).
    function createCaliber(
        bytes32 caliberId,
        string calldata name,
        string calldata symbol,
        address oracle,
        uint256 mintFeeBps,
        uint256 redeemFeeBps,
        uint256 minMintRounds
    ) external returns (address market, address token);
}
