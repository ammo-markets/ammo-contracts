// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDexRouter} from "../src/interfaces/IDexRouter.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @notice Mock Solidly-style router that doubles as factory and pair for tests.
/// @dev Production wires _sellTaxes through router.factory() -> getPair() -> pair.current().
///      Collapsing all three into one mock keeps fixtures small; the router returns
///      its own address as both the factory and the pair, and exposes `current()`
///      driven by `quoteAmountOutDivisor` so tests can configure TWAP responses.
///      Must be funded with AVAX via vm.deal() in tests.
contract MockDexRouter {
    uint256 public lastAmountIn;
    uint256 public lastAmountOutMin;
    address public lastRecipient;
    uint256 public callCount;
    address public immutable WETH;
    uint256 public quoteAmountOutDivisor = 1000;
    uint256 public swapAmountOutDivisor = 1000;

    bool public shouldRevert;
    bool public shouldRevertQuote;
    bool public shouldRevertFactory;
    bool public shouldRevertPairLookup;

    constructor(address weth_) {
        WETH = weth_;
    }

    function factory() external view returns (address) {
        if (shouldRevertFactory) revert("MockDexRouter: forced factory revert");
        return address(this);
    }

    /// @notice Acts as `IPairFactory.getPair`. Returns address(this) so tests can
    ///         resolve the pair through the same mock; tests that need to simulate
    ///         a missing pair can set `shouldRevertQuote = true` instead.
    function getPair(address, address, bool) external view returns (address) {
        if (shouldRevertPairLookup) revert("MockDexRouter: forced pair lookup revert");
        return address(this);
    }

    /// @notice Acts as `ISolidlyPair.current`. Returns a deterministic TWAP-style
    ///         quote driven by `quoteAmountOutDivisor`, so tests can pin exactly
    ///         what `amountOutMin` the contract will compute. The first arg is
    ///         the unused tokenIn address.
    function current(address, uint256 amountIn) external view returns (uint256) {
        if (shouldRevertQuote) revert("MockDexRouter: forced TWAP revert");
        return _amountOut(amountIn, quoteAmountOutDivisor);
    }

    function pairFor(address, address, bool) external pure returns (address pair) {
        return address(0xDEE1);
    }

    /// @notice Set to true to make swaps revert (for testing failure handling).
    function setShouldRevert(bool revert_) external {
        shouldRevert = revert_;
    }

    function setShouldRevertQuote(bool revert_) external {
        shouldRevertQuote = revert_;
    }

    function setShouldRevertFactory(bool revert_) external {
        shouldRevertFactory = revert_;
    }

    function setShouldRevertPairLookup(bool revert_) external {
        shouldRevertPairLookup = revert_;
    }

    function setAmountOutDivisor(uint256 divisor) external {
        quoteAmountOutDivisor = divisor;
        swapAmountOutDivisor = divisor;
    }

    function setQuoteAmountOutDivisor(uint256 divisor) external {
        quoteAmountOutDivisor = divisor;
    }

    function setSwapAmountOutDivisor(uint256 divisor) external {
        swapAmountOutDivisor = divisor;
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        IDexRouter.route[] calldata routes,
        address to,
        uint256 /* deadline */
    ) external {
        if (shouldRevert) revert("MockDexRouter: forced revert");

        address tokenIn = routes[0].from;
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        uint256 amountOut = _amountOut(amountIn, swapAmountOutDivisor);
        if (amountOut < amountOutMin) revert("MockDexRouter: insufficient output");

        (bool success,) = to.call{value: amountOut}("");
        require(success, "MockDexRouter: AVAX transfer failed");

        lastAmountIn = amountIn;
        lastAmountOutMin = amountOutMin;
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

    function _amountOut(uint256 amountIn, uint256 divisor) internal pure returns (uint256 amountOut) {
        amountOut = amountIn / divisor;
        if (amountOut == 0) amountOut = 1;
    }
}
