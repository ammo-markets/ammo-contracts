// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./AmmoToken.sol";
import "./AmmoManager.sol";
import "./IPriceOracle.sol";
import {IExitLiquidityPool} from "./interfaces/IExitLiquidityPool.sol";
import {IProtocolEmissionController} from "./interfaces/IProtocolEmissionController.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @notice Per-caliber market with 2-step mint, real-world redeem, and USDC exit flows.
/// @dev Deployed by AmmoFactory. Each instance manages exactly one caliber.
contract CaliberMarket {
    enum OrderStatus {
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
        address exitLiquidityPool;
        bytes32 caliberId;
        string tokenName;
        string tokenSymbol;
        uint256 mintFeeBps;
        uint256 redeemFeeBps;
        uint256 exitFeeBps;
        uint256 minMintRounds;
    }

    struct MintOrder {
        address user;
        uint256 usdcAmount;
        uint256 requestPrice;
        uint256 feeBps;
        uint256 minMintAtStart;
        uint64 deadline;
        uint64 createdAt;
        uint64 finalizedAt;
        OrderStatus status;
    }

    struct RedeemOrder {
        address user;
        uint256 tokenAmount;
        uint256 feeBps;
        uint64 deadline;
        uint64 createdAt;
        uint64 finalizedAt;
        OrderStatus status;
    }

    struct ExitOrder {
        address user;
        uint256 tokenAmount;
        uint256 requestPrice;
        uint256 payoutUsdc;
        uint256 exitFeeUsdc;
        uint256 feeBps;
        uint64 deadline;
        uint64 createdAt;
        uint64 finalizedAt;
        OrderStatus status;
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
    error DeadlineExpired();
    error DeadlineNotSet();
    error InvalidStatus();
    error Reentrancy();
    error TreasuryNotSet();

    event MintRequested(
        uint256 indexed orderId,
        address indexed user,
        uint256 usdcAmount,
        uint256 requestPrice,
        uint64 deadline
    );
    event MintFinalized(
        uint256 indexed orderId,
        address indexed user,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 priceUsed,
        uint256 refundAmount
    );
    event MintCanceled(uint256 indexed orderId, address indexed user, uint256 refundAmount, uint8 reasonCode);
    event RedeemRequested(uint256 indexed orderId, address indexed user, uint256 tokenAmount, uint64 deadline);
    event RedeemFinalized(uint256 indexed orderId, address indexed user, uint256 burnedTokens, uint256 feeTokens);
    event RedeemCanceled(uint256 indexed orderId, address indexed user, uint256 unlockedTokens, uint8 reasonCode);
    event ExitRequested(
        uint256 indexed orderId,
        address indexed user,
        uint256 tokenAmount,
        uint256 requestPrice,
        uint256 payoutUsdc,
        uint256 exitFeeUsdc,
        uint64 deadline
    );
    event ExitFinalized(
        uint256 indexed orderId,
        address indexed user,
        uint256 burnedTokens,
        uint256 payoutUsdc,
        uint256 exitFeeUsdc
    );
    event ExitCanceled(uint256 indexed orderId, address indexed user, uint256 unlockedTokens, uint8 reasonCode);
    event MintFeeUpdated(uint256 oldBps, uint256 newBps);
    event RedeemFeeUpdated(uint256 oldBps, uint256 newBps);
    event ExitFeeUpdated(uint256 oldBps, uint256 newBps);
    event MinMintUpdated(uint256 oldMin, uint256 newMin);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    uint256 public constant MAX_STALENESS = 6 hours;
    uint256 public constant AMMO_SQUARED_EXIT_BPS = 9_500;

    AmmoManager public immutable manager;
    IERC20 public immutable usdc;
    uint8 public immutable usdcDecimals;
    IPriceOracle public immutable oracle;
    IProtocolEmissionController public immutable emissionController;
    IExitLiquidityPool public immutable exitLiquidityPool;
    AmmoToken public immutable token;
    bytes32 public immutable caliberId;

    uint256 public mintFeeBps;
    uint256 public redeemFeeBps;
    uint256 public exitFeeBps;
    uint256 public minMintRounds;
    bool public paused;
    uint256 public nextMintOrderId = 1;
    uint256 public nextRedeemOrderId = 1;
    uint256 public nextExitOrderId = 1;
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
        if (
            config.manager == address(0) || config.usdc == address(0) || config.oracle == address(0)
                || config.emissionController == address(0) || config.exitLiquidityPool == address(0)
        ) {
            revert ZeroAddress();
        }
        if (config.usdcDecimals > 18) revert InvalidAmount();
        if (config.mintFeeBps > 10_000 || config.redeemFeeBps > 10_000 || config.exitFeeBps > 10_000) {
            revert InvalidBps();
        }

        manager = AmmoManager(config.manager);
        usdc = IERC20(config.usdc);
        usdcDecimals = config.usdcDecimals;
        oracle = IPriceOracle(config.oracle);
        emissionController = IProtocolEmissionController(config.emissionController);
        exitLiquidityPool = IExitLiquidityPool(config.exitLiquidityPool);
        caliberId = config.caliberId;
        mintFeeBps = config.mintFeeBps;
        redeemFeeBps = config.redeemFeeBps;
        exitFeeBps = config.exitFeeBps;
        minMintRounds = config.minMintRounds;

        token = new AmmoToken(config.tokenName, config.tokenSymbol, address(this), config.manager);
    }

    // ── Mint ────────────────────────────────────────

    function startMint(uint256 usdcAmount, uint64 deadline) external whenNotPaused nonReentrant returns (uint256 orderId) {
        if (usdcAmount == 0) revert InvalidAmount();

        (uint256 price,) = _freshPrice();
        uint256 feeAmount = (usdcAmount * mintFeeBps) / 10_000;
        uint256 netUsdc = usdcAmount - feeAmount;
        uint256 tokenAmount = _tokensForUsdc(netUsdc, price);
        if (tokenAmount < minMintRounds * 1e18) revert MinMintNotMet();

        _safeTransferFrom(usdc, msg.sender, address(this), usdcAmount);

        orderId = nextMintOrderId++;
        mintOrders[orderId] = MintOrder({
            user: msg.sender,
            usdcAmount: usdcAmount,
            requestPrice: price,
            feeBps: mintFeeBps,
            minMintAtStart: minMintRounds,
            deadline: deadline,
            createdAt: uint64(block.timestamp),
            finalizedAt: 0,
            status: OrderStatus.Requested
        });

        emit MintRequested(orderId, msg.sender, usdcAmount, price, deadline);
    }

    function finalizeMint(uint256 orderId) external onlyKeeper whenNotPaused nonReentrant {
        MintOrder storage order = mintOrders[orderId];
        if (order.status != OrderStatus.Requested) revert InvalidStatus();
        if (order.deadline != 0 && block.timestamp > order.deadline) revert DeadlineExpired();

        address treasury = manager.treasury();
        if (treasury == address(0)) revert TreasuryNotSet();

        uint256 feeAmount = (order.usdcAmount * order.feeBps) / 10_000;
        uint256 netUsdc = order.usdcAmount - feeAmount;
        uint256 tokenAmount = _tokensForUsdc(netUsdc, order.requestPrice);
        if (tokenAmount < order.minMintAtStart * 1e18) revert MinMintNotMet();

        uint256 actualUsdc = _usdcForTokens(tokenAmount, order.requestPrice);
        uint256 refund = netUsdc - actualUsdc;

        order.status = OrderStatus.Finalized;
        order.finalizedAt = uint64(block.timestamp);

        if (feeAmount > 0) {
            _safeTransfer(usdc, manager.feeRecipient(), feeAmount);
        }
        _safeTransfer(usdc, treasury, actualUsdc);
        if (refund > 0) {
            _safeTransfer(usdc, order.user, refund);
        }

        token.mint(order.user, tokenAmount);
        emissionController.recordCaliberMint(order.usdcAmount);

        emit MintFinalized(orderId, order.user, order.usdcAmount, tokenAmount, order.requestPrice, refund);
    }

    function cancelMint(uint256 orderId, uint8 reasonCode) external nonReentrant {
        MintOrder storage order = mintOrders[orderId];
        if (order.status != OrderStatus.Requested) revert InvalidStatus();
        _requireKeeperOrExpiredUser(order.user, order.deadline);

        order.status = OrderStatus.Canceled;
        order.finalizedAt = uint64(block.timestamp);

        _safeTransfer(usdc, order.user, order.usdcAmount);
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
        token.transferFrom(msg.sender, address(this), tokenAmount);

        orderId = nextRedeemOrderId++;
        redeemOrders[orderId] = RedeemOrder({
            user: msg.sender,
            tokenAmount: tokenAmount,
            feeBps: redeemFeeBps,
            deadline: deadline,
            createdAt: uint64(block.timestamp),
            finalizedAt: 0,
            status: OrderStatus.Requested
        });

        emit RedeemRequested(orderId, msg.sender, tokenAmount, deadline);
    }

    function finalizeRedeem(uint256 orderId) external onlyKeeper whenNotPaused nonReentrant {
        RedeemOrder storage order = redeemOrders[orderId];
        if (order.status != OrderStatus.Requested) revert InvalidStatus();
        if (order.deadline != 0 && block.timestamp > order.deadline) revert DeadlineExpired();

        uint256 feeAmount = (order.tokenAmount * order.feeBps) / 10_000;
        uint256 netTokens = order.tokenAmount - feeAmount;

        order.status = OrderStatus.Finalized;
        order.finalizedAt = uint64(block.timestamp);

        token.burn(address(this), netTokens);
        if (feeAmount > 0) {
            token.transfer(manager.feeRecipient(), feeAmount);
        }

        emit RedeemFinalized(orderId, order.user, netTokens, feeAmount);
    }

    function cancelRedeem(uint256 orderId, uint8 reasonCode) external nonReentrant {
        RedeemOrder storage order = redeemOrders[orderId];
        if (order.status != OrderStatus.Requested) revert InvalidStatus();
        _requireKeeperOrExpiredUser(order.user, order.deadline);

        order.status = OrderStatus.Canceled;
        order.finalizedAt = uint64(block.timestamp);

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

        (uint256 price,) = _freshPrice();
        (uint256 payoutUsdc, uint256 feeUsdc) = _exitQuote(tokenAmount, price, exitFeeBps);

        token.transferFrom(msg.sender, address(this), tokenAmount);

        orderId = nextExitOrderId++;
        exitOrders[orderId] = ExitOrder({
            user: msg.sender,
            tokenAmount: tokenAmount,
            requestPrice: price,
            payoutUsdc: payoutUsdc,
            exitFeeUsdc: feeUsdc,
            feeBps: exitFeeBps,
            deadline: deadline,
            createdAt: uint64(block.timestamp),
            finalizedAt: 0,
            status: OrderStatus.Requested
        });

        emit ExitRequested(orderId, msg.sender, tokenAmount, price, payoutUsdc, feeUsdc, deadline);
    }

    function finalizeExit(uint256 orderId) external onlyKeeper whenNotPaused nonReentrant {
        ExitOrder storage order = exitOrders[orderId];
        if (order.status != OrderStatus.Requested) revert InvalidStatus();
        if (order.deadline != 0 && block.timestamp > order.deadline) revert DeadlineExpired();

        order.status = OrderStatus.Finalized;
        order.finalizedAt = uint64(block.timestamp);

        exitLiquidityPool.payExit(order.user, order.payoutUsdc);
        if (order.exitFeeUsdc > 0) {
            exitLiquidityPool.payExit(manager.feeRecipient(), order.exitFeeUsdc);
        }
        token.burn(address(this), order.tokenAmount);

        emit ExitFinalized(orderId, order.user, order.tokenAmount, order.payoutUsdc, order.exitFeeUsdc);
    }

    function cancelExit(uint256 orderId, uint8 reasonCode) external nonReentrant {
        ExitOrder storage order = exitOrders[orderId];
        if (order.status != OrderStatus.Requested) revert InvalidStatus();
        _requireKeeperOrExpiredUser(order.user, order.deadline);

        order.status = OrderStatus.Canceled;
        order.finalizedAt = uint64(block.timestamp);

        token.transfer(order.user, order.tokenAmount);
        emit ExitCanceled(orderId, order.user, order.tokenAmount, reasonCode);
    }

    // ── Admin ───────────────────────────────────────

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

    function setExitFee(uint256 bps) external onlyOwner {
        if (bps > 10_000) revert InvalidBps();
        uint256 old = exitFeeBps;
        exitFeeBps = bps;
        emit ExitFeeUpdated(old, bps);
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

    // ── Internal helpers ────────────────────────────

    function _freshPrice() internal view returns (uint256 price, uint256 updatedAt) {
        (price, updatedAt) = oracle.getPriceData();
        if (price == 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > MAX_STALENESS) revert StalePrice();
    }

    function _tokensForUsdc(uint256 usdcAmount, uint256 price) internal view returns (uint256) {
        uint256 scale = 10 ** (18 - usdcDecimals);
        return (usdcAmount * scale * 1e18) / price;
    }

    function _usdcForTokens(uint256 tokenAmount, uint256 price) internal view returns (uint256) {
        uint256 scale = 10 ** (18 - usdcDecimals);
        return (tokenAmount * price) / (scale * 1e18);
    }

    function _exitQuote(uint256 tokenAmount, uint256 price, uint256 feeBps)
        internal
        view
        returns (uint256 payoutUsdc, uint256 feeUsdc)
    {
        uint256 grossUsdc = _usdcForTokens(tokenAmount, price);
        uint256 discountedUsdc = (grossUsdc * AMMO_SQUARED_EXIT_BPS) / 10_000;
        feeUsdc = (discountedUsdc * feeBps) / 10_000;
        payoutUsdc = discountedUsdc - feeUsdc;
    }

    function _requireKeeperOrExpiredUser(address user, uint64 deadline) internal view {
        if (!manager.isKeeper(msg.sender)) {
            if (msg.sender != user) revert NotKeeper();
            if (deadline == 0) revert DeadlineNotSet();
            if (block.timestamp <= deadline) revert DeadlineExpired();
        }
    }

    function _checkOwner() internal view {
        if (!manager.isOwner(msg.sender)) revert NotOwner();
    }

    function _checkKeeper() internal view {
        if (!manager.isKeeper(msg.sender)) revert NotKeeper();
    }

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
