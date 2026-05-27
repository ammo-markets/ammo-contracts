// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAmmoManager
/// @notice Interface for the global ops/admin, role registry, and centralized tax configuration.
interface IAmmoManager {
    struct TaxConfig {
        uint256 buyTax;
        uint256 sellTax;
    }

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error TaxTooHigh();

    event OwnershipTransferStarted(address indexed currentOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event KeeperUpdated(address indexed keeper, bool allowed);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event MarketDailyMintCapUpdated(address indexed market, uint256 oldCap, uint256 newCap);
    event PoolTaxSet(address indexed token, address indexed pool, uint256 buyTax, uint256 sellTax);
    event TaxExemptUpdated(address indexed account, bool exempt);

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function guardian() external view returns (address);
    function feeRecipient() external view returns (address);
    function treasury() external view returns (address);
    function keepers(address account) external view returns (bool);
    function marketDailyMintCapUsdc(address market) external view returns (uint256);
    function isKeeper(address account) external view returns (bool);
    function isOwner(address account) external view returns (bool);
    function wavax() external view returns (address);
    function tokenPoolTax(address token, address pool) external view returns (uint256 buyTax, uint256 sellTax);
    function taxExempt(address account) external view returns (bool);

    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function setGuardian(address guardian_) external;
    function setKeeper(address keeper, bool allowed) external;
    function setFeeRecipient(address newRecipient) external;
    function setTreasury(address newTreasury) external;
    function setMarketDailyMintCap(address market, uint256 capUsdc) external;
    function setPoolTax(address token, address pool, uint256 buyBps, uint256 sellBps) external;
    function removePoolTax(address token, address pool) external;
    function setTaxExempt(address account, bool exempt) external;
}
