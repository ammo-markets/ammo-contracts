// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal Pharaoh AccessHub surface required by PairFactory.
/// @dev The production Pharaoh AccessHub has many governance methods. For Fuji
///      dev deployments we only need these read methods during factory setup and
///      admin checks.
interface IAccessHub {
    function voter() external view returns (address);
    function treasury() external view returns (address);
    function feeRecipientFactory() external view returns (address);
}
