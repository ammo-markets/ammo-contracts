// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../AmmoManager.sol";
import "../CaliberToken.sol";
import "../IPriceOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICaliberMarket {
    enum OrderStatus {
        None,
        Requested,
        Processing,
        Finalized,
        Canceled
    }

    struct MarketConfig {
        address manager;
        address usdc;
        uint8 usdcDecimals;
        address oracle;
        bytes32 caliberId;
        string tokenName;
        string tokenSymbol;
        uint256 minMintRounds;
    }

    struct MintOrder {
        address user;
        uint256 usdcAmount;
        uint256 requestPrice;
        uint64 deadline;
        uint64 createdAt;
        OrderStatus status;
    }

    struct RedeemOrder {
        address user;
        uint256 tokenAmount;
        uint64 deadline;
        uint64 createdAt;
        OrderStatus status;
    }

    struct ExitOrder {
        address user;
        uint256 tokenAmount;
        uint256 requestPrice;
        uint256 payoutUsdc;
        uint64 deadline;
        uint64 createdAt;
        OrderStatus status;
    }

    error NotOwner();
    error NotKeeper();
    error InvalidUser();
    error MarketPaused();
    error ZeroAddress();
    error InvalidAmount();
    error InvalidPrice();
    error MinMintNotMet();
    error StalePrice();
    error DeadlineExpired();
    error DeadlineNotExpired();
    error DeadlineTooShort();
    error InvalidStatus();
    error Reentrancy();
    error TreasuryNotSet();
    error DailyMintCapExceeded();

    event MintRequested(
        uint256 indexed orderId, address indexed user, uint256 usdcAmount, uint256 requestPrice, uint64 deadline
    );
    event MintFinalized(
        uint256 indexed orderId,
        address indexed user,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 priceUsed
    );
    event MintProcessing(uint256 indexed orderId, address indexed user, uint256 treasuryAmount);
    event MintCanceled(uint256 indexed orderId, address indexed user, uint256 refundAmount, uint8 reasonCode);
    event RedeemRequested(uint256 indexed orderId, address indexed user, uint256 tokenAmount, uint64 deadline);
    event RedeemFinalized(uint256 indexed orderId, address indexed user, uint256 burnedTokens);
    event RedeemCanceled(uint256 indexed orderId, address indexed user, uint256 unlockedTokens, uint8 reasonCode);
    event ExitRequested(
        uint256 indexed orderId,
        address indexed user,
        uint256 tokenAmount,
        uint256 requestPrice,
        uint256 payoutUsdc,
        uint64 deadline
    );
    event ExitFinalized(uint256 indexed orderId, address indexed user, uint256 burnedTokens, uint256 payoutUsdc);
    event ExitCanceled(uint256 indexed orderId, address indexed user, uint256 unlockedTokens, uint8 reasonCode);
    event MinMintUpdated(uint256 oldMin, uint256 newMin);
    event DailyMintUsed(uint256 indexed day, uint256 usdcAmount, uint256 usedUsdc, uint256 capUsdc);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    function manager() external view returns (AmmoManager);
    function usdc() external view returns (IERC20);
    function usdcDecimals() external view returns (uint8);
    function usdcScale() external view returns (uint256);
    function oracle() external view returns (IPriceOracle);
    function token() external view returns (CaliberToken);
    function caliberId() external view returns (bytes32);
    function minMintRounds() external view returns (uint256);
    function paused() external view returns (bool);
    function nextMintOrderId() external view returns (uint256);
    function nextRedeemOrderId() external view returns (uint256);
    function nextExitOrderId() external view returns (uint256);
    function dailyMintDay() external view returns (uint256);
    function dailyMintUsedUsdc() external view returns (uint256);
    function mintOrders(uint256 orderId)
        external
        view
        returns (
            address user,
            uint256 usdcAmount,
            uint256 requestPrice,
            uint64 deadline,
            uint64 createdAt,
            OrderStatus status
        );
    function redeemOrders(uint256 orderId)
        external
        view
        returns (
            address user,
            uint256 tokenAmount,
            uint64 deadline,
            uint64 createdAt,
            OrderStatus status
        );
    function exitOrders(uint256 orderId)
        external
        view
        returns (
            address user,
            uint256 tokenAmount,
            uint256 requestPrice,
            uint256 payoutUsdc,
            uint64 deadline,
            uint64 createdAt,
            OrderStatus status
        );

    function startMint(uint256 usdcAmount, uint64 deadline) external returns (uint256 orderId);
    function processMint(uint256 orderId) external;
    function finalizeMint(uint256 orderId) external;
    function cancelMint(uint256 orderId, uint8 reasonCode) external;

    function startRedeem(uint256 tokenAmount, uint64 deadline) external returns (uint256 orderId);
    function finalizeRedeem(uint256 orderId) external;
    function cancelRedeem(uint256 orderId, uint8 reasonCode) external;

    function requestExit(uint256 tokenAmount, uint64 deadline) external returns (uint256 orderId);
    function finalizeExit(uint256 orderId) external;
    function cancelExit(uint256 orderId, uint8 reasonCode) external;

    function setMinMint(uint256 newMin) external;
    function pause() external;
    function unpause() external;
}
