// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICaliberMarket {
    enum OrderStatus {
        None,
        Requested,
        Finalized,
        Canceled
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

    function manager() external view returns (address);
    function usdc() external view returns (address);
    function usdcDecimals() external view returns (uint8);
    function oracle() external view returns (address);
    function emissionController() external view returns (address);
    function exitLiquidityPool() external view returns (address);
    function token() external view returns (address);
    function caliberId() external view returns (bytes32);
    function mintFeeBps() external view returns (uint256);
    function redeemFeeBps() external view returns (uint256);
    function exitFeeBps() external view returns (uint256);
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
            uint256 feeBps,
            uint256 minMintAtStart,
            uint64 deadline,
            uint64 createdAt,
            uint64 finalizedAt,
            OrderStatus status
        );
    function redeemOrders(uint256 orderId)
        external
        view
        returns (
            address user,
            uint256 tokenAmount,
            uint256 feeBps,
            uint64 deadline,
            uint64 createdAt,
            uint64 finalizedAt,
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
            uint256 exitFeeUsdc,
            uint256 feeBps,
            uint64 deadline,
            uint64 createdAt,
            uint64 finalizedAt,
            OrderStatus status
        );

    function startMint(uint256 usdcAmount, uint64 deadline) external returns (uint256 orderId);
    function finalizeMint(uint256 orderId) external;
    function cancelMint(uint256 orderId, uint8 reasonCode) external;

    function startRedeem(uint256 tokenAmount, uint64 deadline) external returns (uint256 orderId);
    function finalizeRedeem(uint256 orderId) external;
    function cancelRedeem(uint256 orderId, uint8 reasonCode) external;

    function requestExit(uint256 tokenAmount, uint64 deadline) external returns (uint256 orderId);
    function finalizeExit(uint256 orderId) external;
    function cancelExit(uint256 orderId, uint8 reasonCode) external;

    function setMintFee(uint256 bps) external;
    function setRedeemFee(uint256 bps) external;
    function setExitFee(uint256 bps) external;
    function setMinMint(uint256 newMin) external;
    function pause() external;
    function unpause() external;
}
