// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./AmmoToken.sol";
import "./AmmoManager.sol";
import "./IPriceOracle.sol";
import {IProtocolEmissionController} from "./interfaces/IProtocolEmissionController.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @notice Per-caliber market with 1-step instant mint and 2-step keeper-finalized redeem.
/// @dev Deployed by AmmoFactory. Each instance manages exactly one caliber.
///      Mint reads price from a shared PriceOracle; redeem is keeper-finalized.
contract CaliberMarket {
    enum RedeemStatus {
        None,
        Requested,
        Finalized,
        Canceled
    }

    struct MarketConfig {
        address manager;
        address usdc;
        uint8 usdcDecimals;
        address oracle;
        address emissionController;
        bytes32 caliberId;
        string tokenName;
        string tokenSymbol;
        uint256 mintFeeBps;
        uint256 redeemFeeBps;
        uint256 minMintRounds;
    }

    struct RedeemOrder {
        address user;
        uint256 tokenAmount;
        uint256 feeBps;
        uint64 deadline;
        uint64 createdAt;
        uint64 finalizedAt;
        RedeemStatus status;
    }

    error NotOwner();
    error NotKeeper();
    error MarketPaused();
    error ZeroAddress();
    error InvalidAmount();
    error InvalidBps();
    error InvalidPrice();
    error MinMintNotMet();
    error StalePrice();
    error NoTokensMinted();
    error DeadlineExpired();
    error DeadlineNotSet();
    error InvalidStatus();
    error Reentrancy();
    error TreasuryNotSet();

    event Minted(
        address indexed user,
        bytes32 indexed caliberId,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 priceUsed,
        uint256 refundAmount
    );
    event RedeemRequested(uint256 indexed orderId, address indexed user, uint256 tokenAmount, uint64 deadline);
    event RedeemFinalized(uint256 indexed orderId, address indexed user, uint256 burnedTokens, uint256 feeTokens);
    event RedeemCanceled(uint256 indexed orderId, address indexed user, uint256 unlockedTokens, uint8 reasonCode);
    event MintFeeUpdated(uint256 oldBps, uint256 newBps);
    event RedeemFeeUpdated(uint256 oldBps, uint256 newBps);
    event MinMintUpdated(uint256 oldMin, uint256 newMin);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    uint256 public constant MAX_STALENESS = 6 hours;

    AmmoManager public immutable manager;
    IERC20 public immutable usdc;
    uint8 public immutable usdcDecimals;
    IPriceOracle public immutable oracle;
    IProtocolEmissionController public immutable emissionController;
    AmmoToken public immutable token;
    bytes32 public immutable caliberId;

    uint256 public mintFeeBps;
    uint256 public redeemFeeBps;
    uint256 public minMintRounds;
    bool public paused;
    uint256 public nextOrderId = 1;
    uint256 private _locked;

    mapping(uint256 => RedeemOrder) public redeemOrders;

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    modifier onlyKeeper() {
        _checkKeeper();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert MarketPaused();
        _;
    }

    modifier nonReentrant() {
        if (_locked == 1) revert Reentrancy();
        _locked = 1;
        _;
        _locked = 0;
    }

    constructor(MarketConfig memory config) {
        if (
            config.manager == address(0) || config.usdc == address(0) || config.oracle == address(0)
                || config.emissionController == address(0)
        ) {
            revert ZeroAddress();
        }
        if (config.usdcDecimals > 18) revert InvalidAmount();
        if (config.mintFeeBps > 10_000 || config.redeemFeeBps > 10_000) revert InvalidBps();

        manager = AmmoManager(config.manager);
        usdc = IERC20(config.usdc);
        usdcDecimals = config.usdcDecimals;
        oracle = IPriceOracle(config.oracle);
        emissionController = IProtocolEmissionController(config.emissionController);
        caliberId = config.caliberId;
        mintFeeBps = config.mintFeeBps;
        redeemFeeBps = config.redeemFeeBps;
        minMintRounds = config.minMintRounds;

        token = new AmmoToken(config.tokenName, config.tokenSymbol, address(this), config.manager);
    }

    // ── User functions ──────────────────────────────

    /// @notice Mint ammo tokens in a single step using the oracle price.
    /// @param usdcAmount Total USDC to spend (fee is deducted from this).
    function mint(uint256 usdcAmount) external whenNotPaused nonReentrant {
        if (usdcAmount == 0) revert InvalidAmount();

        address treasury = manager.treasury();
        if (treasury == address(0)) revert TreasuryNotSet();

        (uint256 price, uint256 updatedAt) = oracle.getPriceData();
        if (price == 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > MAX_STALENESS) revert StalePrice();

        uint256 feeAmount = (usdcAmount * mintFeeBps) / 10_000;
        uint256 netUsdc = usdcAmount - feeAmount;
        uint256 scale = 10 ** (18 - usdcDecimals);

        // Round DOWN to whole tokens
        uint256 tokenAmount = (netUsdc * scale * 1e18) / price;
        if (tokenAmount < minMintRounds * 1e18) revert MinMintNotMet();

        // Back-calculate exact USDC consumed for whole tokens
        uint256 actualUsdc = (tokenAmount * price) / (scale * 1e18);
        uint256 refund = netUsdc - actualUsdc;

        // Transfer USDC from user
        _safeTransferFrom(usdc, msg.sender, address(this), usdcAmount);

        // Distribute USDC
        if (feeAmount > 0) {
            _safeTransfer(usdc, manager.feeRecipient(), feeAmount);
        }
        _safeTransfer(usdc, treasury, actualUsdc);
        if (refund > 0) {
            _safeTransfer(usdc, msg.sender, refund);
        }

        // Mint tokens
        token.mint(msg.sender, tokenAmount);
        emissionController.recordCaliberMint(usdcAmount);

        emit Minted(msg.sender, caliberId, usdcAmount, tokenAmount, price, refund);
    }

    function startRedeem(uint256 tokenAmount, uint64 deadline)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 orderId)
    {
        if (tokenAmount == 0) revert InvalidAmount();
        token.transferFrom(msg.sender, address(this), tokenAmount);

        orderId = nextOrderId++;
        redeemOrders[orderId] = RedeemOrder({
            user: msg.sender,
            tokenAmount: tokenAmount,
            feeBps: redeemFeeBps,
            deadline: deadline,
            createdAt: uint64(block.timestamp),
            finalizedAt: 0,
            status: RedeemStatus.Requested
        });

        emit RedeemRequested(orderId, msg.sender, tokenAmount, deadline);
    }

    // ── Keeper functions ────────────────────────────

    function finalizeRedeem(uint256 orderId) external onlyKeeper whenNotPaused {
        RedeemOrder storage order = redeemOrders[orderId];
        if (order.status != RedeemStatus.Requested) revert InvalidStatus();
        if (order.deadline != 0 && block.timestamp > order.deadline) revert DeadlineExpired();

        uint256 feeAmount = (order.tokenAmount * order.feeBps) / 10_000;
        uint256 netTokens = order.tokenAmount - feeAmount;

        order.status = RedeemStatus.Finalized;
        order.finalizedAt = uint64(block.timestamp);

        token.burn(address(this), netTokens);
        if (feeAmount > 0) {
            token.transfer(manager.feeRecipient(), feeAmount);
        }

        emit RedeemFinalized(orderId, order.user, netTokens, feeAmount);
    }

    function cancelRedeem(uint256 orderId, uint8 reasonCode) external {
        RedeemOrder storage order = redeemOrders[orderId];
        if (order.status != RedeemStatus.Requested) revert InvalidStatus();

        // Keeper can cancel anytime; user can self-rescue after deadline
        if (!manager.isKeeper(msg.sender)) {
            if (msg.sender != order.user) revert NotKeeper();
            if (order.deadline == 0) revert DeadlineNotSet();
            if (block.timestamp <= order.deadline) revert DeadlineExpired();
        }

        order.status = RedeemStatus.Canceled;
        order.finalizedAt = uint64(block.timestamp);

        token.transfer(order.user, order.tokenAmount);

        emit RedeemCanceled(orderId, order.user, order.tokenAmount, reasonCode);
    }

    // ── Admin functions ─────────────────────────────

    function setMintFee(uint256 bps) external onlyOwner {
        if (bps > 10_000) revert InvalidBps();
        uint256 old = mintFeeBps;
        mintFeeBps = bps;
        emit MintFeeUpdated(old, bps);
    }

    function setRedeemFee(uint256 bps) external onlyOwner {
        if (bps > 10_000) revert InvalidBps();
        uint256 old = redeemFeeBps;
        redeemFeeBps = bps;
        emit RedeemFeeUpdated(old, bps);
    }

    function setMinMint(uint256 newMin) external onlyOwner {
        uint256 old = minMintRounds;
        minMintRounds = newMin;
        emit MinMintUpdated(old, newMin);
    }

    function pause() external {
        if (!manager.isOwner(msg.sender) && msg.sender != manager.guardian()) revert NotOwner();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ── Internal access-control helpers ──────────────

    function _checkOwner() internal view {
        if (!manager.isOwner(msg.sender)) revert NotOwner();
    }

    function _checkKeeper() internal view {
        if (!manager.isKeeper(msg.sender)) revert NotKeeper();
    }

    // ── Internal safe-transfer helpers ──────────────

    function _safeTransfer(IERC20 tok, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            address(tok).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert InvalidAmount();
    }

    function _safeTransferFrom(IERC20 tok, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            address(tok).call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert InvalidAmount();
    }
}
