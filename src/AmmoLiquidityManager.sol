// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IDexRouter} from "./interfaces/IDexRouter.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/// @notice Tax-exempt helper for adding and removing CaliberToken liquidity through the configured DEX router.
/// @dev Mark this contract tax-exempt in AmmoManager before use. Direct router LP adds/removes remain taxable.
contract AmmoLiquidityManager {
    IDexRouter public immutable router;
    address public immutable wavax;

    error ZeroAddress();
    error InvalidAmount();
    error TransferFailed();

    constructor(address router_) {
        if (router_ == address(0)) revert ZeroAddress();
        router = IDexRouter(router_);
        wavax = IDexRouter(router_).WETH();
        if (wavax == address(0)) revert ZeroAddress();
    }

    /// @dev Required so IWETH.withdraw can refund native AVAX into this contract during removeLiquidityETH.
    receive() external payable {}

    function addLiquidityETH(
        address token,
        bool stable,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amountTokenDesired == 0 || msg.value == 0) revert InvalidAmount();

        uint256 ethBefore = address(this).balance - msg.value;
        _safeTransferFrom(IERC20(token), msg.sender, address(this), amountTokenDesired);
        _forceApprove(IERC20(token), address(router), amountTokenDesired);

        (amountToken, amountETH, liquidity) = router.addLiquidityETH{value: msg.value}(
            token, stable, amountTokenDesired, amountTokenMin, amountETHMin, to, deadline
        );

        _forceApprove(IERC20(token), address(router), 0);
        _refundToken(IERC20(token), msg.sender, amountTokenDesired - amountToken);
        _refundETH(msg.sender, address(this).balance - ethBefore);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        if (tokenA == address(0) || tokenB == address(0) || to == address(0)) revert ZeroAddress();
        if (amountADesired == 0 || amountBDesired == 0) revert InvalidAmount();

        IERC20 erc20A = IERC20(tokenA);
        IERC20 erc20B = IERC20(tokenB);

        _safeTransferFrom(erc20A, msg.sender, address(this), amountADesired);
        _safeTransferFrom(erc20B, msg.sender, address(this), amountBDesired);
        _forceApprove(erc20A, address(router), amountADesired);
        _forceApprove(erc20B, address(router), amountBDesired);

        (amountA, amountB, liquidity) = router.addLiquidity(
            tokenA, tokenB, stable, amountADesired, amountBDesired, amountAMin, amountBMin, to, deadline
        );

        _forceApprove(erc20A, address(router), 0);
        _forceApprove(erc20B, address(router), 0);
        _refundToken(erc20A, msg.sender, amountADesired - amountA);
        _refundToken(erc20B, msg.sender, amountBDesired - amountB);
    }

    /// @notice Remove CaliberToken/WAVAX liquidity and return CaliberToken + native AVAX to the user.
    /// @dev    Uses router.removeLiquidity (not removeLiquidityETH) so the pair burns underlying
    ///         directly to this helper (exempt), avoiding the pair→router taxed transfer that the
    ///         router's own ETH wrapper performs. The helper then unwraps WAVAX itself and forwards.
    /// @param token             CaliberToken address.
    /// @param stable            Whether the AMMO/WAVAX pair is the stable variant (almost always false).
    /// @param liquidity         LP token amount to burn. User must have approved this helper for `liquidity`.
    /// @param amountTokenMin    Minimum CaliberToken to receive (slippage bound from frontend quote).
    /// @param amountETHMin      Minimum native AVAX to receive (slippage bound from frontend quote).
    /// @param to                Recipient of the unwound CaliberToken and native AVAX.
    /// @param deadline          Unix timestamp after which the call reverts.
    function removeLiquidityETH(
        address token,
        bool stable,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH) {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (liquidity == 0) revert InvalidAmount();

        // The LP token IS the pair contract in Solidly-style AMMs.
        address pair = router.pairFor(token, wavax, stable);
        if (pair == address(0)) revert ZeroAddress();

        IERC20 lp = IERC20(pair);

        // Pull LP tokens from caller into this exempt helper.
        _safeTransferFrom(lp, msg.sender, address(this), liquidity);
        _forceApprove(lp, address(router), liquidity);

        // Burn LP via the router. `to = address(this)` makes the pair send AMMO +
        // WAVAX directly to this exempt helper — the pair→helper transfer for AMMO
        // is the leg the router's own removeLiquidityETH would have routed
        // through itself, triggering the buy tax. By taking that hop in-house we
        // keep an exempt party on the receiving side.
        (amountToken, amountETH) = router.removeLiquidity(
            token, wavax, stable, liquidity, amountTokenMin, amountETHMin, address(this), deadline
        );

        _forceApprove(lp, address(router), 0);

        // Unwrap WAVAX → native AVAX. IWETH.withdraw sends native to msg.sender,
        // which is this contract — caught by the receive() fallback.
        IWETH(wavax).withdraw(amountETH);

        // Forward both legs to `to`. helper→to for AMMO is untaxed (helper
        // exempt; `to` is not a pool); native AVAX is forwarded via low-level call.
        _safeTransfer(IERC20(token), to, amountToken);
        _refundETH(to, amountETH);
    }

    function _refundToken(IERC20 token, address to, uint256 amount) internal {
        if (amount > 0) _safeTransfer(token, to, amount);
    }

    function _refundETH(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success,) = to.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    function _forceApprove(IERC20 token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
