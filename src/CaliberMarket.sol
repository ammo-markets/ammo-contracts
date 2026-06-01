// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./CaliberToken.sol";
import "./AmmoManager.sol";
import "./IPriceOracle.sol";
import "./interfaces/ICaliberMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Per-caliber market with 3-step mint, real-world redeem, and USDC exit flows.
/// @dev Deployed by AmmoFactory. Each instance manages exactly one caliber.
contract CaliberMarket is ICaliberMarket {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_STALENESS = 6 hours;
    uint256 public constant MIN_MINT_DEADLINE = 24 hours;
    uint256 public constant AMMO_SQUARED_EXIT_BPS = 9_500;
    uint256 public constant BPS_DIVISOR = 10_000;

    AmmoManager public immutable manager;
    IERC20 public immutable usdc;
    uint8 public immutable usdcDecimals;
    uint256 public immutable usdcScale;
    IPriceOracle public immutable oracle;
    CaliberToken public immutable token;
    bytes32 public immutable caliberId;

    uint256 public minMintRounds;
    bool public paused;
    uint256 public nextMintOrderId = 1;
    uint256 public nextRedeemOrderId = 1;
    uint256 public nextExitOrderId = 1;
    uint256 public dailyMintDay;
    uint256 public dailyMintUsedUsdc;
    uint256 private _locked;

    mapping(uint256 => MintOrder) public mintOrders;
    mapping(uint256 => RedeemOrder) public redeemOrders;
    mapping(uint256 => ExitOrder) public exitOrders;

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
        if (config.manager == address(0) || config.usdc == address(0) || config.oracle == address(0)) {
            revert ZeroAddress();
        }
        if (config.usdcDecimals > 18) revert InvalidAmount();

        manager = AmmoManager(config.manager);
        usdc = IERC20(config.usdc);
        usdcDecimals = config.usdcDecimals;
        usdcScale = 10 ** (18 - config.usdcDecimals);
        oracle = IPriceOracle(config.oracle);
        caliberId = config.caliberId;
        minMintRounds = config.minMintRounds;

        token = new CaliberToken(config.tokenName, config.tokenSymbol, address(this), config.manager);
    }

    // ── Mint ────────────────────────────────────────

    function startMint(uint256 usdcAmount, uint64 deadline)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 orderId)
    {
        if (usdcAmount == 0) revert InvalidAmount();
        _requireMinimumDeadline(deadline);

        (uint256 price,) = _freshPrice();
        uint256 tokenAmount = _tokensForUsdc(usdcAmount, price);
        if (tokenAmount < minMintRounds * 1e18) revert MinMintNotMet();

        _consumeDailyMintCapacity(usdcAmount);
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        orderId = nextMintOrderId++;
        mintOrders[orderId] = MintOrder({
            user: msg.sender,
            usdcAmount: usdcAmount,
            requestPrice: price,
            deadline: deadline,
            createdAt: uint64(block.timestamp),
            status: OrderStatus.Requested
        });

        emit MintRequested(orderId, msg.sender, usdcAmount, price, deadline);
    }

    /// @notice Sweep a requested order's USDC to the treasury so the team has working capital
    ///         to buy the physical ammo before the mint is finalized.
    /// @dev Requested → Processing. The full user deposit is swept to treasury, so finalizeMint
    ///      never has to move USDC. Once an order is Processing it is committed: it can no longer
    ///      be canceled by anyone (see cancelMint).
    function processMint(uint256 orderId) external onlyKeeper whenNotPaused nonReentrant {
        MintOrder storage order = mintOrders[orderId];
        if (order.status != OrderStatus.Requested) revert InvalidStatus();
        if (block.timestamp > order.deadline) revert DeadlineExpired();

        address treasury = manager.treasury();
        if (treasury == address(0)) revert TreasuryNotSet();

        order.status = OrderStatus.Processing;

        usdc.safeTransfer(treasury, order.usdcAmount);

        emit MintProcessing(orderId, order.user, order.usdcAmount);
    }

    /// @notice Confirm an order is backed by real ammo and mint the caliber tokens.
    /// @dev Processing → Finalized. Funds already left for the treasury in processMint, so this
    ///      only mints tokens. No deadline check: once funds are committed
    ///      the order must be either finalized or keeper-canceled, never left to expire.
    function finalizeMint(uint256 orderId) external onlyKeeper whenNotPaused nonReentrant {
        MintOrder storage order = mintOrders[orderId];
        if (order.status != OrderStatus.Processing) revert InvalidStatus();

        uint256 tokenAmount = _tokensForUsdc(order.usdcAmount, order.requestPrice);
        order.status = OrderStatus.Finalized;

        token.mint(order.user, tokenAmount);

        emit MintFinalized(orderId, order.user, order.usdcAmount, tokenAmount, order.requestPrice);
    }

    /// @notice Cancel a mint, refunding escrow before processing or caller-funded USDC after processing.
    /// @dev Requested orders refund from this contract's escrow: a keeper may cancel before deadline,
    ///      while anyone may cancel after deadline. Processing orders are open to cancel because
    ///      the caller funds the refund directly via transferFrom(msg.sender, order.user, amount).
    function cancelMint(uint256 orderId, uint8 reasonCode) external nonReentrant {
        MintOrder storage order = mintOrders[orderId];
        OrderStatus status = order.status;
        if (status == OrderStatus.Requested) {
            if (block.timestamp <= order.deadline && !manager.isKeeper(msg.sender)) revert NotKeeper();
            _releaseDailyMintCapacity(order.usdcAmount, order.createdAt);
            order.status = OrderStatus.Canceled;
            usdc.safeTransfer(order.user, order.usdcAmount);
        } else if (status == OrderStatus.Processing) {
            order.status = OrderStatus.Canceled;
            usdc.safeTransferFrom(msg.sender, order.user, order.usdcAmount);
        } else {
            revert InvalidStatus();
        }
        emit MintCanceled(orderId, order.user, order.usdcAmount, reasonCode);
    }

    // ── Redeem ──────────────────────────────────────

    function startRedeem(uint256 tokenAmount, uint64 deadline)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 orderId)
    {
        if (tokenAmount == 0) revert InvalidAmount();
        _requireMinimumDeadline(deadline);
        token.transferFrom(msg.sender, address(this), tokenAmount);

        orderId = nextRedeemOrderId++;
        redeemOrders[orderId] = RedeemOrder({
            user: msg.sender,
            tokenAmount: tokenAmount,
            deadline: deadline,
            createdAt: uint64(block.timestamp),
            status: OrderStatus.Requested
        });

        emit RedeemRequested(orderId, msg.sender, tokenAmount, deadline);
    }

    function finalizeRedeem(uint256 orderId) external onlyKeeper whenNotPaused nonReentrant {
        RedeemOrder storage order = redeemOrders[orderId];
        if (order.status != OrderStatus.Requested) revert InvalidStatus();
        if (block.timestamp > order.deadline) revert DeadlineExpired();

        order.status = OrderStatus.Finalized;

        token.burn(address(this), order.tokenAmount);

        emit RedeemFinalized(orderId, order.user, order.tokenAmount);
    }

    function cancelRedeem(uint256 orderId, uint8 reasonCode) external nonReentrant {
        RedeemOrder storage order = redeemOrders[orderId];
        if (order.status != OrderStatus.Requested) revert InvalidStatus();
        _requireKeeperOrExpiredOrder(order.user, order.deadline);

        order.status = OrderStatus.Canceled;

        token.transfer(order.user, order.tokenAmount);
        emit RedeemCanceled(orderId, order.user, order.tokenAmount, reasonCode);
    }

    // ── Exit ────────────────────────────────────────

    function requestExit(uint256 tokenAmount, uint64 deadline)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 orderId)
    {
        if (tokenAmount == 0) revert InvalidAmount();
        _requireMinimumDeadline(deadline);

        (uint256 price,) = _freshPrice();
        uint256 payoutUsdc = _exitQuote(tokenAmount, price);

        token.transferFrom(msg.sender, address(this), tokenAmount);

        orderId = nextExitOrderId++;
        exitOrders[orderId] = ExitOrder({
            user: msg.sender,
            tokenAmount: tokenAmount,
            requestPrice: price,
            payoutUsdc: payoutUsdc,
            deadline: deadline,
            createdAt: uint64(block.timestamp),
            status: OrderStatus.Requested
        });

        emit ExitRequested(orderId, msg.sender, tokenAmount, price, payoutUsdc, deadline);
    }

    function finalizeExit(uint256 orderId) external onlyKeeper whenNotPaused nonReentrant {
        ExitOrder storage order = exitOrders[orderId];
        if (order.status != OrderStatus.Requested) revert InvalidStatus();
        if (block.timestamp > order.deadline) revert DeadlineExpired();

        order.status = OrderStatus.Finalized;

        usdc.safeTransferFrom(msg.sender, order.user, order.payoutUsdc);
        token.burn(address(this), order.tokenAmount);

        emit ExitFinalized(orderId, order.user, order.tokenAmount, order.payoutUsdc);
    }

    function cancelExit(uint256 orderId, uint8 reasonCode) external nonReentrant {
        ExitOrder storage order = exitOrders[orderId];
        if (order.status != OrderStatus.Requested) revert InvalidStatus();
        _requireKeeperOrExpiredOrder(order.user, order.deadline);

        order.status = OrderStatus.Canceled;

        token.transfer(order.user, order.tokenAmount);
        emit ExitCanceled(orderId, order.user, order.tokenAmount, reasonCode);
    }

    // ── Admin ───────────────────────────────────────

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

    // ── Internal helpers ────────────────────────────

    function _freshPrice() internal view returns (uint256 price, uint256 updatedAt) {
        (price, updatedAt) = oracle.getPriceData();
        if (price == 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > MAX_STALENESS) revert StalePrice();
    }

    function _tokensForUsdc(uint256 usdcAmount, uint256 price) internal view returns (uint256) {
        return (usdcAmount * usdcScale * 1e18) / price;
    }

    function _usdcForTokens(uint256 tokenAmount, uint256 price) internal view returns (uint256) {
        return (tokenAmount * price) / (usdcScale * 1e18);
    }

    function _exitQuote(uint256 tokenAmount, uint256 price) internal view returns (uint256 payoutUsdc) {
        uint256 grossUsdc = _usdcForTokens(tokenAmount, price);
        payoutUsdc = (grossUsdc * AMMO_SQUARED_EXIT_BPS) / BPS_DIVISOR;
    }

    function _consumeDailyMintCapacity(uint256 usdcAmount) internal {
        uint256 cap = manager.marketDailyMintCapUsdc(address(this));
        if (cap == 0) revert DailyMintCapExceeded();

        uint256 day = block.timestamp / 1 days;
        uint256 used = dailyMintDay == day ? dailyMintUsedUsdc : 0;
        uint256 newUsed = used + usdcAmount;
        if (newUsed > cap) revert DailyMintCapExceeded();

        dailyMintDay = day;
        dailyMintUsedUsdc = newUsed;
        emit DailyMintUsed(day, usdcAmount, newUsed, cap);
    }

    function _releaseDailyMintCapacity(uint256 usdcAmount, uint64 createdAt) internal {
        uint256 orderDay = uint256(createdAt) / 1 days;
        if (dailyMintDay != orderDay) return;

        uint256 used = dailyMintUsedUsdc;
        dailyMintUsedUsdc = usdcAmount >= used ? 0 : used - usdcAmount;
    }

    function _requireMinimumDeadline(uint64 deadline) internal view {
        if (deadline <= block.timestamp + MIN_MINT_DEADLINE) revert DeadlineTooShort();
    }

    function _requireKeeperOrExpiredOrder(address user, uint64 deadline) internal view {
        if (!manager.isKeeper(msg.sender)) {
            if (msg.sender != user) revert InvalidUser();
            if (block.timestamp <= deadline) revert DeadlineNotExpired();
        }
    }

    function _checkOwner() internal view {
        if (!manager.isOwner(msg.sender)) revert NotOwner();
    }

    function _checkKeeper() internal view {
        if (!manager.isKeeper(msg.sender)) revert NotKeeper();
    }
}
