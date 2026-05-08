// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AmmoManager.sol";
import "../src/PriceOracle.sol";
import "../src/AmmoPriceFunctions.sol";

/// @dev Minimal mock of the Chainlink Functions router so we can deploy
///      AmmoPriceFunctions without a real router. We only need the
///      handleOracleFulfillment entry point for fulfillment tests.
contract MockFunctionsRouter {
    function sendRequest(uint64, bytes calldata, uint16, uint32, bytes32) external pure returns (bytes32) {
        return keccak256("mock-request");
    }
}

contract AmmoPriceFunctionsTest is Test {
    AmmoManager manager;
    PriceOracle oracle;
    MockFunctionsRouter router;
    AmmoPriceFunctions consumer;

    address owner = address(this);
    address random = address(0xDEAD);
    address factoryAddr = address(0xFAC7);
    address marketA = address(0xA);
    address marketB = address(0xB);

    function setUp() public {
        // Protocol setup
        manager = new AmmoManager(owner, address(0xAA0C));
        oracle = new PriceOracle(address(manager));
        oracle.setFactory(factoryAddr);

        vm.startPrank(factoryAddr);
        oracle.registerMarket(marketA);
        oracle.registerMarket(marketB);
        vm.stopPrank();

        // Chainlink setup
        router = new MockFunctionsRouter();

        address[] memory markets = new address[](2);
        markets[0] = marketA;
        markets[1] = marketB;

        string[] memory keys = new string[](2);
        keys[0] = "9MM_PRACTICE";
        keys[1] = "9MM_SELF_DEFENSE";

        consumer = new AmmoPriceFunctions(
            address(router),
            1, // subscriptionId
            bytes32("fuji-don"), // donId
            address(oracle),
            markets,
            keys
        );

        // Set JS source and API URL (needed for performUpkeep)
        consumer.setApiBaseUrl("https://example.com");
        consumer.setSource("return Functions.encodeUint256Array([]);");

        // Register consumer as keeper so it can call setBatchPrices
        manager.setKeeper(address(consumer), true);
    }

    // ── Constructor ──────────────────────────────────

    function testConstructorArrayMismatch() public {
        address[] memory markets = new address[](2);
        markets[0] = marketA;
        markets[1] = marketB;

        string[] memory keys = new string[](1);
        keys[0] = "9MM_PRACTICE";

        vm.expectRevert(AmmoPriceFunctions.ArrayLengthMismatch.selector);
        new AmmoPriceFunctions(address(router), 1, bytes32("don"), address(oracle), markets, keys);
    }

    function testConstructorSetsState() public {
        assertEq(address(consumer.oracle()), address(oracle));
        assertEq(consumer.owner(), owner);
        assertEq(consumer.subscriptionId(), 1);
        assertEq(consumer.callbackGasLimit(), 300_000);
        assertEq(consumer.updateInterval(), 4 hours);
        assertEq(consumer.caliberCount(), 2);
    }

    // ── checkUpkeep ──────────────────────────────────

    function testCheckUpkeepReturnsTrueWhenIntervalElapsed() public {
        // Warp past the update interval so (block.timestamp - 0) >= 1 hour
        vm.warp(4 hours + 1);
        (bool needed,) = consumer.checkUpkeep("");
        assertTrue(needed);
    }

    function testCheckUpkeepReturnsFalseBeforeInterval() public {
        vm.warp(4 hours + 1);
        consumer.performUpkeep("");

        // Still within interval
        (bool needed,) = consumer.checkUpkeep("");
        assertFalse(needed);
    }

    function testCheckUpkeepReturnsTrueAfterInterval() public {
        vm.warp(4 hours + 1);
        consumer.performUpkeep("");

        // Warp past interval
        vm.warp(block.timestamp + 4 hours + 1);

        (bool needed,) = consumer.checkUpkeep("");
        assertTrue(needed);
    }

    // ── performUpkeep ────────────────────────────────

    function testPerformUpkeepUpdatesTimestamp() public {
        vm.warp(4 hours + 1);
        uint256 ts = block.timestamp;
        consumer.performUpkeep("");
        assertEq(consumer.lastUpkeepTimestamp(), ts);
    }

    function testPerformUpkeepNoOpBeforeInterval() public {
        vm.warp(4 hours + 1);
        consumer.performUpkeep("");
        bytes32 firstRequestId = consumer.lastRequestId();

        // Try again immediately — should be a no-op
        consumer.performUpkeep("");
        assertEq(consumer.lastRequestId(), firstRequestId);
    }

    // ── fulfillRequest (via handleOracleFulfillment) ─

    function testFulfillRequestUpdatesPrices() public {
        // Trigger a request first
        vm.warp(4 hours + 1);
        consumer.performUpkeep("");
        bytes32 requestId = consumer.lastRequestId();

        // Simulate DON fulfillment
        uint256[] memory prices = new uint256[](2);
        prices[0] = 21e16; // 9MM_PRACTICE
        prices[1] = 45e16; // 9MM_SELF_DEFENSE

        bytes memory response = abi.encode(prices);

        vm.prank(address(router));
        consumer.handleOracleFulfillment(requestId, response, "");

        // Verify oracle was updated
        (uint256 priceA,,) = oracle.markets(marketA);
        (uint256 priceB,,) = oracle.markets(marketB);
        assertEq(priceA, 21e16);
        assertEq(priceB, 45e16);
    }

    function testFulfillRequestEmitsEventOnSuccess() public {
        vm.warp(4 hours + 1);
        consumer.performUpkeep("");
        bytes32 requestId = consumer.lastRequestId();

        uint256[] memory prices = new uint256[](2);
        prices[0] = 21e16;
        prices[1] = 45e16;

        vm.expectEmit(true, false, false, true);
        emit AmmoPriceFunctions.PriceUpdateFulfilled(requestId, prices);

        vm.prank(address(router));
        consumer.handleOracleFulfillment(requestId, abi.encode(prices), "");
    }

    function testFulfillRequestEmitsEventOnError() public {
        vm.warp(4 hours + 1);
        consumer.performUpkeep("");
        bytes32 requestId = consumer.lastRequestId();

        bytes memory errMsg = bytes("DON execution failed");

        vm.expectEmit(true, false, false, true);
        emit AmmoPriceFunctions.PriceUpdateFailed(requestId, errMsg);

        vm.prank(address(router));
        consumer.handleOracleFulfillment(requestId, "", errMsg);

        // Oracle should NOT have been updated
        (uint256 priceA,,) = oracle.markets(marketA);
        assertEq(priceA, 0);
    }

    function testFulfillRequestOnlyRouter() public {
        vm.warp(4 hours + 1);
        consumer.performUpkeep("");
        bytes32 requestId = consumer.lastRequestId();

        vm.prank(random);
        vm.expectRevert();
        consumer.handleOracleFulfillment(requestId, "", "");
    }

    // ── Admin functions ──────────────────────────────

    function testSetApiBaseUrlOnlyOwner() public {
        vm.prank(random);
        vm.expectRevert(AmmoPriceFunctions.NotOwner.selector);
        consumer.setApiBaseUrl("https://evil.com");
    }

    function testSetApiBaseUrlRejectsEmpty() public {
        vm.expectRevert(AmmoPriceFunctions.EmptyApiBaseUrl.selector);
        consumer.setApiBaseUrl("");
    }

    function testSetApiBaseUrlUpdates() public {
        consumer.setApiBaseUrl("https://new.example.com");
        assertEq(consumer.apiBaseUrl(), "https://new.example.com");
    }

    function testSetSourceOnlyOwner() public {
        vm.prank(random);
        vm.expectRevert(AmmoPriceFunctions.NotOwner.selector);
        consumer.setSource("evil code");
    }

    function testSetSourceRejectsEmpty() public {
        vm.expectRevert(AmmoPriceFunctions.EmptySource.selector);
        consumer.setSource("");
    }

    function testSetUpdateIntervalOnlyOwner() public {
        vm.prank(random);
        vm.expectRevert(AmmoPriceFunctions.NotOwner.selector);
        consumer.setUpdateInterval(30 minutes);
    }

    function testSetUpdateIntervalUpdates() public {
        consumer.setUpdateInterval(30 minutes);
        assertEq(consumer.updateInterval(), 30 minutes);
    }

    function testSetConfigOnlyOwner() public {
        vm.prank(random);
        vm.expectRevert(AmmoPriceFunctions.NotOwner.selector);
        consumer.setConfig(2, bytes32("new-don"), 500_000);
    }

    function testSetConfigUpdates() public {
        consumer.setConfig(42, bytes32("new-don"), 500_000);
        assertEq(consumer.subscriptionId(), 42);
        assertEq(consumer.donId(), bytes32("new-don"));
        assertEq(consumer.callbackGasLimit(), 500_000);
    }
}
