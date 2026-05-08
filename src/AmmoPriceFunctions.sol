// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_3_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {
    AutomationCompatibleInterface
} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {PriceOracle} from "./PriceOracle.sol";

/// @title AmmoPriceFunctions
/// @notice Chainlink Functions + Automation consumer that fetches ammo prices
///         from the protocol API and pushes them on-chain via PriceOracle.
/// @dev Replaces the centralized keeper (Bun worker) for the on-chain price push.
///      Worker still scrapes prices into DB → API → Chainlink DON → this contract → PriceOracle.
contract AmmoPriceFunctions is FunctionsClient, AutomationCompatibleInterface {
    using FunctionsRequest for FunctionsRequest.Request;

    // ── Immutables ───────────────────────────────────
    PriceOracle public immutable oracle;
    address public immutable owner;

    // ── Configuration ────────────────────────────────
    uint64 public subscriptionId;
    bytes32 public donId;
    uint32 public callbackGasLimit;
    uint256 public updateInterval;
    string public apiBaseUrl;
    string public jsSource;

    // ── Market/caliber mapping ───────────────────────
    address[] public marketAddresses;
    string[] public caliberKeys;

    // ── State ────────────────────────────────────────
    uint256 public lastUpkeepTimestamp;
    bytes32 public lastRequestId;

    // ── Errors ───────────────────────────────────────
    error NotOwner();
    error EmptySource();
    error EmptyApiBaseUrl();
    error ArrayLengthMismatch();

    // ── Events ───────────────────────────────────────
    event PriceUpdateRequested(bytes32 indexed requestId);
    event PriceUpdateFulfilled(bytes32 indexed requestId, uint256[] prices);
    event PriceUpdateFailed(bytes32 indexed requestId, bytes error);
    event ApiBaseUrlUpdated(string newUrl);
    event SourceUpdated();
    event UpdateIntervalUpdated(uint256 newInterval);
    event ConfigUpdated(uint64 subscriptionId, bytes32 donId, uint32 callbackGasLimit);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param router_ Chainlink Functions router address
    /// @param subscriptionId_ Chainlink Functions subscription ID
    /// @param donId_ Chainlink Functions DON ID
    /// @param oracle_ PriceOracle contract address
    /// @param markets_ Ordered array of CaliberMarket addresses
    /// @param caliberKeys_ Ordered array of caliber key strings (e.g., "9MM_PRACTICE")
    constructor(
        address router_,
        uint64 subscriptionId_,
        bytes32 donId_,
        address oracle_,
        address[] memory markets_,
        string[] memory caliberKeys_
    ) FunctionsClient(router_) {
        if (markets_.length != caliberKeys_.length) revert ArrayLengthMismatch();

        owner = msg.sender;
        oracle = PriceOracle(oracle_);
        subscriptionId = subscriptionId_;
        donId = donId_;
        callbackGasLimit = 300_000;
        updateInterval = 4 hours;
        marketAddresses = markets_;
        caliberKeys = caliberKeys_;
    }

    // ── Automation ───────────────────────────────────

    /// @notice Called by Chainlink Automation to check if upkeep is needed.
    /// @return upkeepNeeded True if enough time has elapsed since last update.
    /// @return performData Empty bytes (no extra data needed).
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        upkeepNeeded = (block.timestamp - lastUpkeepTimestamp) >= updateInterval;
        performData = "";
    }

    /// @notice Called by Chainlink Automation when checkUpkeep returns true.
    ///         Sends a Functions request to the DON.
    function performUpkeep(bytes calldata) external override {
        if ((block.timestamp - lastUpkeepTimestamp) < updateInterval) return;

        lastUpkeepTimestamp = block.timestamp;
        _sendPriceRequest();
    }

    // ── Internal ─────────────────────────────────────

    function _sendPriceRequest() internal {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(jsSource);

        // args[0] = API base URL, args[1..N] = caliber keys
        string[] memory args = new string[](1 + caliberKeys.length);
        args[0] = apiBaseUrl;
        for (uint256 i; i < caliberKeys.length; ++i) {
            args[i + 1] = caliberKeys[i];
        }
        req.setArgs(args);

        bytes32 requestId = _sendRequest(req.encodeCBOR(), subscriptionId, callbackGasLimit, donId);

        lastRequestId = requestId;
        emit PriceUpdateRequested(requestId);
    }

    /// @notice Callback from Chainlink DON with the price data.
    /// @dev Decodes uint256[] and calls oracle.setBatchPrices(). On error, emits
    ///      an event but does NOT revert — reverting would waste the DON's gas
    ///      and the request can't be retried anyway.
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        if (err.length > 0) {
            emit PriceUpdateFailed(requestId, err);
            return;
        }

        uint256[] memory prices = abi.decode(response, (uint256[]));
        oracle.setBatchPrices(marketAddresses, prices);
        emit PriceUpdateFulfilled(requestId, prices);
    }

    // ── Admin ────────────────────────────────────────

    function setApiBaseUrl(string calldata url) external onlyOwner {
        if (bytes(url).length == 0) revert EmptyApiBaseUrl();
        apiBaseUrl = url;
        emit ApiBaseUrlUpdated(url);
    }

    function setSource(string calldata source) external onlyOwner {
        if (bytes(source).length == 0) revert EmptySource();
        jsSource = source;
        emit SourceUpdated();
    }

    function setUpdateInterval(uint256 interval) external onlyOwner {
        updateInterval = interval;
        emit UpdateIntervalUpdated(interval);
    }

    function setConfig(uint64 subscriptionId_, bytes32 donId_, uint32 callbackGasLimit_) external onlyOwner {
        subscriptionId = subscriptionId_;
        donId = donId_;
        callbackGasLimit = callbackGasLimit_;
        emit ConfigUpdated(subscriptionId_, donId_, callbackGasLimit_);
    }

    /// @notice Returns the number of calibers tracked.
    function caliberCount() external view returns (uint256) {
        return caliberKeys.length;
    }
}
