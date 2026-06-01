// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAccessHub} from "../interfaces/IAccessHub.sol";

/// @notice Minimal AccessHub shim for Fuji/local Pharaoh-style legacy AMM tests.
/// @dev It intentionally avoids Pharaoh's full governance stack. PairFactory only
///      needs these addresses for initialization and admin gating.
contract DevAccessHub is IAccessHub {
    address public owner;
    address public override voter;
    address public override treasury;
    address public override feeRecipientFactory;

    error NotOwner();
    error ZeroAddress();

    event OwnerUpdated(address indexed owner);
    event VoterUpdated(address indexed voter);
    event TreasuryUpdated(address indexed treasury);
    event FeeRecipientFactoryUpdated(address indexed feeRecipientFactory);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, address treasury_) {
        if (owner_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        owner = owner_;
        voter = owner_;
        treasury = treasury_;
        feeRecipientFactory = treasury_;

        emit OwnerUpdated(owner_);
        emit VoterUpdated(owner_);
        emit TreasuryUpdated(treasury_);
        emit FeeRecipientFactoryUpdated(treasury_);
    }

    function setOwner(address owner_) external onlyOwner {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnerUpdated(owner_);
    }

    function setVoter(address voter_) external onlyOwner {
        if (voter_ == address(0)) revert ZeroAddress();
        voter = voter_;
        emit VoterUpdated(voter_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setFeeRecipientFactory(address feeRecipientFactory_) external onlyOwner {
        if (feeRecipientFactory_ == address(0)) revert ZeroAddress();
        feeRecipientFactory = feeRecipientFactory_;
        emit FeeRecipientFactoryUpdated(feeRecipientFactory_);
    }
}
