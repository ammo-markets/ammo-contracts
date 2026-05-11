// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IExitLiquidityPool {
    function setMarket(address market, bool allowed) external;
    function payExit(address recipient, uint256 amount) external;
}
