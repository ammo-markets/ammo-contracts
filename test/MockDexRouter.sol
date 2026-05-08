// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDexRouter} from "../src/interfaces/IDexRouter.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @notice Mock Solidly-style router for testing AmmoToken tax auto-swaps.
/// @dev Simulates swapExactTokensForETHSupportingFeeOnTransferTokens.
///      Must be funded with AVAX via vm.deal() in tests.
contract MockDexRouter {
    uint256 public lastAmountIn;
    address public lastRecipient;
    uint256 public callCount;
    address public immutable WETH;

    bool public shouldRevert;

    constructor(address weth_) {
        WETH = weth_;
    }

    function factory() external pure returns (address) {
        return address(0xFACE);
    }

    function pairFor(address, address, bool) external pure returns (address pair) {
        return address(0xDEE1);
    }

    /// @notice Set to true to make swaps revert (for testing failure handling).
    function setShouldRevert(bool revert_) external {
        shouldRevert = revert_;
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256, /* amountOutMin */
        IDexRouter.route[] calldata routes,
        address to,
        uint256 /* deadline */
    ) external {
        if (shouldRevert) revert("MockDexRouter: forced revert");

        address tokenIn = routes[0].from;
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        uint256 amountOut = amountIn / 1000;
        if (amountOut == 0) amountOut = 1;

        (bool success,) = to.call{value: amountOut}("");
        require(success, "MockDexRouter: AVAX transfer failed");

        lastAmountIn = amountIn;
        lastRecipient = to;
        callCount++;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256,
        uint256,
        address to,
        uint256
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        IERC20(tokenA).transferFrom(msg.sender, address(0xDEE1), amountADesired);
        IERC20(tokenB).transferFrom(msg.sender, address(0xDEE1), amountBDesired);
        amountA = amountADesired;
        amountB = amountBDesired;
        liquidity = amountADesired + amountBDesired;
        to;
    }

    function addLiquidityETH(address token, bool, uint256 amountTokenDesired, uint256, uint256, address to, uint256)
        external
        payable
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        IERC20(token).transferFrom(msg.sender, address(0xDEE1), amountTokenDesired);
        amountToken = amountTokenDesired;
        amountETH = msg.value;
        liquidity = amountTokenDesired + msg.value;
        to;
    }

    receive() external payable {}
}
