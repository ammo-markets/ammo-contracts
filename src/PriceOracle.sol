// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IPriceOracle.sol";
import "./AmmoManager.sol";

/// @notice Shared price oracle for all caliber markets.
/// @dev Stores per-market price data. Markets call getPriceData() and receive
///      their own price keyed on msg.sender. Only the factory can register
///      markets; only keepers can update prices.
contract PriceOracle is IPriceOracle {
    struct MarketData {
        uint256 price;
        uint256 updatedAt;
        bool registered;
    }

    AmmoManager public immutable manager;

    mapping(address => MarketData) public markets;
    address public factory;

    error NotOwner();
    error NotKeeper();
    error NotFactory();
    error FactoryAlreadySet();
    error ZeroAddress();
    error NotRegistered();
    error ArrayLengthMismatch();

    event PriceUpdated(address indexed market, uint256 oldPrice, uint256 newPrice, uint256 updatedAt);
    event FactorySet(address indexed factory);
    event MarketRegistered(address indexed market);

    constructor(address manager_) {
        if (manager_ == address(0)) revert ZeroAddress();
        manager = AmmoManager(manager_);
    }

    // ── Factory management ───────────────────────────

    /// @notice Set the factory address. Can only be called once by the owner.
    function setFactory(address factory_) external {
        if (!manager.isOwner(msg.sender)) revert NotOwner();
        if (factory != address(0)) revert FactoryAlreadySet();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    /// @notice Register a market. Only callable by the factory.
    function registerMarket(address market) external {
        if (msg.sender != factory) revert NotFactory();
        markets[market].registered = true;
        emit MarketRegistered(market);
    }

    // ── Price updates (keeper-only) ──────────────────

    /// @notice Set the price for a single market.
    function setPrice(address market, uint256 priceX18) external {
        if (!manager.isKeeper(msg.sender)) revert NotKeeper();
        if (!markets[market].registered) revert NotRegistered();

        uint256 oldPrice = markets[market].price;
        markets[market].price = priceX18;
        markets[market].updatedAt = block.timestamp;

        emit PriceUpdated(market, oldPrice, priceX18, block.timestamp);
    }

    /// @notice Set prices for multiple markets in a single transaction.
    function setBatchPrices(address[] calldata marketAddrs, uint256[] calldata pricesX18) external {
        if (!manager.isKeeper(msg.sender)) revert NotKeeper();
        if (marketAddrs.length != pricesX18.length) revert ArrayLengthMismatch();

        for (uint256 i; i < marketAddrs.length; ++i) {
            if (!markets[marketAddrs[i]].registered) revert NotRegistered();

            uint256 oldPrice = markets[marketAddrs[i]].price;
            markets[marketAddrs[i]].price = pricesX18[i];
            markets[marketAddrs[i]].updatedAt = block.timestamp;

            emit PriceUpdated(marketAddrs[i], oldPrice, pricesX18[i], block.timestamp);
        }
    }

    // ── Price reads (per msg.sender) ─────────────────

    /// @notice Returns price data for the calling market.
    /// @dev Reverts if msg.sender is not a registered market.
    function getPriceData() external view override returns (uint256 priceX18, uint256 updatedAt) {
        MarketData storage data = markets[msg.sender];
        if (!data.registered) revert NotRegistered();
        return (data.price, data.updatedAt);
    }
}
