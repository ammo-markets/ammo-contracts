/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface IGvToken {
    /* ========== STRUCTS ========== */
    struct Deposit {
        uint128 amount;
        uint128 start;
    }
    /* ========== EVENTS ========== */
    event Deposited(address indexed user, uint256 amount);
    event RedeemRequest(address indexed user, uint256 amount, uint256 endTime);
    event RedeemFinalize(address indexed user, uint256 amount);

    function deposit(uint256 amount) external;

    function withdrawRequest(uint256 amount) external;

    function withdrawFinalize() external;

    function setDelay(uint256 time) external;

    function setTotalSupply(uint256 newTotalSupply) external;

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);

    function getUserDeposits(address user)
        external
        view
        returns (Deposit[] memory);

    function totalSupply() external view returns (uint256);

    function balanceOf(address user) external view returns (uint256);
}
