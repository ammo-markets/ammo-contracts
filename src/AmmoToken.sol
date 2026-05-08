// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AmmoManager} from "./AmmoManager.sol";
import {IDexRouter} from "./interfaces/IDexRouter.sol";

/// @notice ERC20 token with fee-on-transfer tax for DEX trades.
/// @dev Mint/burn restricted to its CaliberMarket. Tax config is read from AmmoManager.
///      Accumulated taxes are auto-swapped to native AVAX via the configured DEX router.
contract AmmoToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 internal constant _BPS_DIVISOR = 10_000;

    uint256 public totalSupply;
    address public immutable market;
    AmmoManager public immutable manager;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @dev Reentrancy guard for tax auto-swaps. When true, all tax logic is bypassed.
    bool private _inSwap;

    error NotMarket();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();
    error Denied();

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event TaxesSold(uint256 tokensSold, address indexed recipient);

    modifier onlyMarket() {
        if (msg.sender != market) revert NotMarket();
        _;
    }

    constructor(string memory name_, string memory symbol_, address market_, address manager_) {
        if (market_ == address(0) || manager_ == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        market = market_;
        manager = AmmoManager(manager_);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance();
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external onlyMarket {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyMarket {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    // ── Internal ────────────────────────────────────

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        // Denylist takes precedence over tax/exempt logic. Once denied, an address
        // cannot send or receive — bridges and similar destinations are fully frozen.
        if (manager.isDenied(from) || manager.isDenied(to)) revert Denied();

        uint256 taxAmount = 0;

        if (!_inSwap && !_isLocalExempt(from, to)) {
            bool protocolExempt = manager.taxExempt(from) || manager.taxExempt(to);
            if (protocolExempt) {
                taxAmount = 0;
            } else {
                taxAmount = _determineTax(from, to, amount);

                // Auto-swap only on non-DEX transfers to avoid reentering the router/pair
                // during a buy or sell. DEX trades just accumulate tax; the next regular
                // transfer that crosses threshold flushes it.
                if (taxAmount == 0 && _shouldSwap()) {
                    _sellTaxes();
                }
            }
        }

        uint256 receiveAmount = amount - taxAmount;
        balanceOf[from] -= amount;
        balanceOf[to] += receiveAmount;
        emit Transfer(from, to, receiveAmount);

        if (taxAmount > 0) {
            balanceOf[address(this)] += taxAmount;
            emit Transfer(from, address(this), taxAmount);
        }
    }

    /// @dev Calculate tax amount by reading rates from AmmoManager.
    function _determineTax(address from, address to, uint256 amount) internal view returns (uint256) {
        // Buy: check if `from` is a taxed pool
        (uint256 buyBps,) = manager.tokenPoolTax(address(this), from);
        if (buyBps > 0) return (amount * buyBps) / _BPS_DIVISOR;

        // Sell: check if `to` is a taxed pool (only if not a buy)
        (, uint256 sellBps) = manager.tokenPoolTax(address(this), to);
        if (sellBps > 0) return (amount * sellBps) / _BPS_DIVISOR;

        return 0;
    }

    /// @dev Check token-local exemptions (no storage reads for cheapest checks).
    ///      - market: CaliberMarket mint/redeem/transfer operations
    ///      - address(this): tax swap transfers
    ///      Router transfers are not exempt because sells also arrive as router-mediated
    ///      user-to-pair transfers. Liquidity adds should use an exempt helper contract.
    function _isLocalExempt(address from, address to) internal view returns (bool) {
        return from == market || to == market || from == address(this) || to == address(this);
    }

    /// @dev Check if accumulated tax balance exceeds the auto-swap threshold.
    function _shouldSwap() internal view returns (bool) {
        uint256 threshold = manager.taxSwapThresholds(address(this));
        return threshold > 0 && balanceOf[address(this)] >= threshold;
    }

    /// @dev Swap accumulated tax tokens to native AVAX via the configured DEX router.
    ///      Sends AVAX directly to treasury. Failures are silently caught so user
    ///      trades are never blocked by swap issues.
    function _sellTaxes() internal {
        uint256 tokenBalance = balanceOf[address(this)];
        if (tokenBalance == 0) return;

        (address router, address wavax_, AmmoManager.SwapPath memory swapPath,, address treasury_) =
            manager.getSwapConfig(address(this));

        if (router == address(0) || treasury_ == address(0) || swapPath.outputToken == address(0)) return;
        if (swapPath.outputToken != wavax_) return;

        _inSwap = true;

        // Approve router to pull our tokens
        allowance[address(this)][router] = tokenBalance;
        emit Approval(address(this), router, tokenBalance);

        // Build DEX path: AmmoToken -> WAVAX. The router unwraps WAVAX to native AVAX.
        IDexRouter.route[] memory routes = new IDexRouter.route[](1);
        routes[0] = IDexRouter.route({from: address(this), to: wavax_, stable: swapPath.stable});

        try IDexRouter(router)
            .swapExactTokensForETHSupportingFeeOnTransferTokens(
                tokenBalance,
                0, // amountOutMin: no slippage protection for small tax swaps
                routes,
                treasury_,
                block.timestamp
            ) {
            emit TaxesSold(tokenBalance, treasury_);
            allowance[address(this)][router] = 0;
            emit Approval(address(this), router, 0);
        } catch {
            // Swap failed — reset approval, taxes accumulate for next attempt
            allowance[address(this)][router] = 0;
            emit Approval(address(this), router, 0);
        }

        _inSwap = false;
    }
}
