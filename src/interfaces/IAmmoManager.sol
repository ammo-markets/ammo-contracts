// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAmmoManager
/// @notice Interface for the global ops/admin, role registry, and centralized tax configuration.
/// @dev All CaliberMarket and AmmoToken instances reference this contract.
interface IAmmoManager {
    // ── Structs ─────────────────────────────────────

    struct TaxConfig {
        uint256 buyTax;
        uint256 sellTax;
    }

    struct SwapPath {
        address outputToken;
        bool stable;
    }

    // ── Errors ───────���──────────────────────────────

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error TaxTooHigh();
    error PoolAlreadyTaxed();
    error PoolNotTaxed();

    // ── Events (core) ───────────────────────────────

    event OwnershipTransferStarted(address indexed currentOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event KeeperUpdated(address indexed keeper, bool allowed);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ── Events (tax) ────────────────────────────────

    event DexRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event PoolTaxSet(address indexed token, address indexed pool, uint256 buyTax, uint256 sellTax);
    event PoolTaxRemoved(address indexed token, address indexed pool);
    event SwapPathUpdated(address indexed token, address indexed outputToken, bool stable);
    event TaxSwapThresholdUpdated(address indexed token, uint256 threshold);
    event TaxExemptUpdated(address indexed account, bool exempt);

    // ── View functions (core) ───────────────────────

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function guardian() external view returns (address);
    function feeRecipient() external view returns (address);
    function treasury() external view returns (address);
    function keepers(address account) external view returns (bool);
    function isKeeper(address account) external view returns (bool);
    function isOwner(address account) external view returns (bool);

    // ── View functions (tax) ────────────────────────

    function wavax() external view returns (address);
    function dexRouter() external view returns (address);
    function tokenPoolTax(address token, address pool) external view returns (uint256 buyTax, uint256 sellTax);
    function swapPaths(address token) external view returns (address outputToken, bool stable);
    function taxSwapThresholds(address token) external view returns (uint256);
    function taxExempt(address account) external view returns (bool);
    function getSwapConfig(address token)
        external
        view
        returns (address router, address wavax_, SwapPath memory path, uint256 threshold, address treasury_);
    function getTokenPools(address token) external view returns (address[] memory);

    // ── Ownership (2-step) ──────────────────────────

    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;

    // ── Role management ─────────��───────────────────

    function setGuardian(address guardian_) external;
    function setKeeper(address keeper, bool allowed) external;

    // ── Global config ──────────��────────────────────

    function setFeeRecipient(address newRecipient) external;
    function setTreasury(address newTreasury) external;

    // ── Tax admin ───────────���───────────────────────

    function setDexRouter(address newRouter) external;
    function setPoolTax(address token, address pool, uint256 buyBps, uint256 sellBps) external;
    function removePoolTax(address token, address pool) external;
    function setSwapPath(address token, address outputToken, bool stable) external;
    function setTaxSwapThreshold(address token, uint256 threshold) external;
    function setTaxExempt(address account, bool exempt) external;
}
