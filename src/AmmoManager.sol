// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGvAmmo {
    function balanceOf(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);
}

/// @notice Global ops/admin, role registry, and centralized tax configuration for the Ammo Exchange protocol.
/// @dev All CaliberMarket and CaliberToken instances reference this contract for access control and tax config.
///      Owner should be a multisig in production.
contract AmmoManager {
    // ── Structs ─────────────────────────────────────

    struct TaxConfig {
        uint256 buyTax; // bps (100 = 1%)
        uint256 sellTax; // bps (100 = 1%)
    }

    struct SwapPath {
        address outputToken;
        bool stable;
    }

    // ── Constants ───────────────────────────────────

    uint256 public constant MAX_TAX_BPS = 1_000; // 10% max
    uint256 public constant MAX_TAX_SWAP_SLIPPAGE_BPS = 5_000; // 50% max

    // ── Core protocol state ─────────────────────────

    address public owner;
    address public pendingOwner;
    address public guardian;
    address public feeRecipient;
    address public treasury;

    mapping(address => bool) public keepers;

    /// @notice Per-market maximum gross USDC/USDT mint requests accepted per chain day.
    /// @dev Stored in the payment token's native decimals. A zero cap disables mint requests.
    mapping(address => uint256) public marketDailyMintCapUsdc;

    // ── Tax state (centralized) ─────────────────────

    /// @notice Wrapped native token address (immutable per chain).
    address public immutable wavax;

    /// @notice Solidly-style DEX router address (protocol-wide, mutable).
    address public dexRouter;

    /// @notice Per-token per-pool tax rates. token => pool => TaxConfig
    mapping(address => mapping(address => TaxConfig)) public tokenPoolTax;

    /// @notice Per-token swap path configuration for auto-selling taxes.
    mapping(address => SwapPath) public swapPaths;

    /// @notice Per-token minimum accumulated tax balance before auto-swap triggers.
    mapping(address => uint256) public taxSwapThresholds;

    /// @notice Slippage tolerance for automatic tax swaps in basis points.
    /// @dev Compared against the pair's 30-minute TWAP, so the tolerance must
    ///      cover normal TWAP-vs-spot drift (bigger than spot-vs-spot drift).
    uint256 public taxSwapSlippageBps = 1_000;

    /// @notice Protocol-wide tax-exempt addresses (staking, vesting, etc.).
    mapping(address => bool) public taxExempt;

    /// @notice Optional gvAMMO token used to exempt sufficiently staked users from DEX transfer tax.
    address public gvAmmo;

    /// @notice Required share of gvAMMO total supply, in basis points.
    uint256 public gvAmmoTaxExemptionBps;

    /// @notice Protocol-wide transfer denylist. CaliberTokens revert any transfer
    ///         where `from` or `to` is denied. Used to block bridges and other
    ///         destinations the protocol does not allow ammo tokens to leave through.
    mapping(address => bool) public isDenied;

    // ── Errors ──────────────────────────────────────

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error TaxTooHigh();

    // ── Events (core) ───────────────────────────────

    event OwnershipTransferStarted(address indexed currentOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event KeeperUpdated(address indexed keeper, bool allowed);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event MarketDailyMintCapUpdated(address indexed market, uint256 oldCap, uint256 newCap);

    // ── Events (tax) ────────────────────────────────

    event DexRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event PoolTaxSet(address indexed token, address indexed pool, uint256 buyTax, uint256 sellTax);
    event SwapPathUpdated(address indexed token, address indexed outputToken, bool stable);
    event TaxSwapThresholdUpdated(address indexed token, uint256 threshold);
    event TaxSwapSlippageUpdated(uint256 oldBps, uint256 newBps);
    event TaxExemptUpdated(address indexed account, bool exempt);
    event gvAmmoUpdated(address indexed gvAmmo, uint256 thresholdBps);
    event DeniedUpdated(address indexed account, bool denied);

    // ── Modifiers ───────────────────────────────────

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    // ── Constructor ─────────────────────────────────

    constructor(address feeRecipient_, address wavax_) {
        if (feeRecipient_ == address(0) || wavax_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        feeRecipient = feeRecipient_;
        wavax = wavax_;
        keepers[msg.sender] = true;
        emit KeeperUpdated(msg.sender, true);
    }

    // ══════════════════════════════════════════════════
    // ── Core Protocol Admin ──────────────────────────
    // ══════════════════════════════════════════════════

    // ── Ownership (2-step) ──────────────────────────

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, msg.sender);
    }

    // ── Role management ─────────────────────────────

    function setGuardian(address guardian_) external onlyOwner {
        address old = guardian;
        guardian = guardian_;
        emit GuardianUpdated(old, guardian_);
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        keepers[keeper] = allowed;
        emit KeeperUpdated(keeper, allowed);
    }

    // ── Global config ───────────────────────────────

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        address old = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    /// @notice Set the daily gross mint-request cap for a CaliberMarket.
    /// @dev Cap is in the market's payment token native decimals. A zero cap disables mint requests.
    function setMarketDailyMintCap(address market, uint256 capUsdc) external onlyOwner {
        if (market == address(0)) revert ZeroAddress();
        uint256 old = marketDailyMintCapUsdc[market];
        marketDailyMintCapUsdc[market] = capUsdc;
        emit MarketDailyMintCapUpdated(market, old, capUsdc);
    }

    // ══════════════════════════════════════════════════
    // ── Tax Admin ────────────────────────────────────
    // ══════════════════════════════════════════════════

    /// @notice Set the DEX router address for the entire protocol.
    function setDexRouter(address newRouter) external onlyOwner {
        address old = dexRouter;
        dexRouter = newRouter;
        emit DexRouterUpdated(old, newRouter);
    }

    /// @notice Set buy/sell tax rates for a specific token's DEX pool.
    /// @param token The CaliberToken address.
    /// @param pool The DEX pair address.
    /// @param buyBps Buy tax in basis points (max 1000 = 10%).
    /// @param sellBps Sell tax in basis points (max 1000 = 10%).
    function setPoolTax(address token, address pool, uint256 buyBps, uint256 sellBps) external onlyOwner {
        _setPoolTax(token, pool, buyBps, sellBps);
    }

    /// @notice Remove tax from a specific token's DEX pool.
    function removePoolTax(address token, address pool) external onlyOwner {
        _setPoolTax(token, pool, 0, 0);
    }

    /// @notice Configure the DEX swap path for a token's auto-swap.
    /// @param token The CaliberToken address.
    /// @param outputToken The token to receive before the router unwraps to native ETH/AVAX.
    /// @param stable Whether to route through the stable pair.
    function setSwapPath(address token, address outputToken, bool stable) external onlyOwner {
        if (token == address(0) || outputToken == address(0)) revert ZeroAddress();
        swapPaths[token] = SwapPath({outputToken: outputToken, stable: stable});
        emit SwapPathUpdated(token, outputToken, stable);
    }

    /// @notice Set the minimum accumulated tax balance before auto-swap triggers.
    function setTaxSwapThreshold(address token, uint256 threshold) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        taxSwapThresholds[token] = threshold;
        emit TaxSwapThresholdUpdated(token, threshold);
    }

    /// @notice Set automatic tax-swap slippage tolerance in basis points.
    function setTaxSwapSlippageBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_TAX_SWAP_SLIPPAGE_BPS) revert TaxTooHigh();
        uint256 old = taxSwapSlippageBps;
        taxSwapSlippageBps = newBps;
        emit TaxSwapSlippageUpdated(old, newBps);
    }

    /// @notice Add or remove a protocol-wide tax exemption.
    function setTaxExempt(address account, bool exempt) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        taxExempt[account] = exempt;
        emit TaxExemptUpdated(account, exempt);
    }

    /// @notice Configure gvAMMO-based DEX tax exemption. Set gvAMMO or bps to zero to disable.
    function setGvAmmo(address gvAmmo_, uint256 thresholdBps) external onlyOwner {
        if (thresholdBps > 10_000) revert TaxTooHigh();
        gvAmmo = gvAmmo_;
        gvAmmoTaxExemptionBps = thresholdBps;
        emit gvAmmoUpdated(gvAmmo_, thresholdBps);
    }

    /// @notice Add or remove a protocol-wide transfer denial. Denied addresses
    ///         cannot be the `from` or `to` of any CaliberToken transfer. Used to
    ///         block bridges and other destinations the protocol does not allow
    ///         ammo tokens to leave through.
    function setDenied(address account, bool denied) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        isDenied[account] = denied;
        emit DeniedUpdated(account, denied);
    }

    // ══════════════════════════════════════════════════
    // ── Tax View Functions (called by CaliberToken) ─────
    // ══════════════════════════════════════════════════

    /// @notice Get all swap configuration a token needs to execute _sellTaxes().
    function getSwapConfig(address token)
        external
        view
        returns (
            address router,
            address wavax_,
            SwapPath memory path,
            uint256 threshold,
            uint256 slippageBps,
            address treasury_
        )
    {
        return (dexRouter, wavax, swapPaths[token], taxSwapThresholds[token], taxSwapSlippageBps, treasury);
    }

    /// @notice Whether an account owns enough gvAMMO voting power share to avoid DEX tax.
    function isGvAmmoTaxExempt(address account) external view returns (bool) {
        address gvAmmo_ = gvAmmo;
        uint256 thresholdBps = gvAmmoTaxExemptionBps;
        if (gvAmmo_ == address(0) || thresholdBps == 0) return false;

        try IGvAmmo(gvAmmo_).balanceOf(account) returns (uint256 gvBalance) {
            if (gvBalance == 0) return false;
            try IGvAmmo(gvAmmo_).totalSupply() returns (uint256 gvSupply) {
                if (gvSupply == 0) return false;
                return (gvBalance * 10_000) >= (gvSupply * thresholdBps);
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    // ══════════════════════════════════════════════════
    // ── View Helpers (called by CaliberMarket) ───────
    // ══════════════════════════════════════════════════

    function _checkOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    function _setPoolTax(address token, address pool, uint256 buyBps, uint256 sellBps) internal {
        if (token == address(0) || pool == address(0)) revert ZeroAddress();
        if (buyBps > MAX_TAX_BPS || sellBps > MAX_TAX_BPS) revert TaxTooHigh();

        TaxConfig storage config = tokenPoolTax[token][pool];
        config.buyTax = buyBps;
        config.sellTax = sellBps;

        emit PoolTaxSet(token, pool, buyBps, sellBps);
    }

    function isKeeper(address account) external view returns (bool) {
        return keepers[account];
    }

    function isOwner(address account) external view returns (bool) {
        return account == owner;
    }
}
