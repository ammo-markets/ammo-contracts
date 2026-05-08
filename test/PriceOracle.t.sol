// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AmmoManager.sol";
import "../src/PriceOracle.sol";

contract PriceOracleTest is Test {
    AmmoManager manager;
    PriceOracle oracle;

    address owner = address(this);
    address keeper = address(0xCA11);
    address factoryAddr = address(0xFAC7);
    address marketA = address(0xA);
    address marketB = address(0xB);
    address random = address(0xDEAD);

    function setUp() public {
        manager = new AmmoManager(owner, address(0xAA0C));
        manager.setKeeper(keeper, true);

        oracle = new PriceOracle(address(manager));
        oracle.setFactory(factoryAddr);

        // Register markets via factory
        vm.startPrank(factoryAddr);
        oracle.registerMarket(marketA);
        oracle.registerMarket(marketB);
        vm.stopPrank();
    }

    // ── setFactory ───────────────────────────────────

    function testSetFactoryOnlyOwner() public {
        PriceOracle fresh = new PriceOracle(address(manager));

        vm.prank(random);
        vm.expectRevert(PriceOracle.NotOwner.selector);
        fresh.setFactory(factoryAddr);
    }

    function testSetFactoryOnlyOnce() public {
        vm.expectRevert(PriceOracle.FactoryAlreadySet.selector);
        oracle.setFactory(address(0x999));
    }

    function testSetFactoryRejectsZero() public {
        PriceOracle fresh = new PriceOracle(address(manager));

        vm.expectRevert(PriceOracle.ZeroAddress.selector);
        fresh.setFactory(address(0));
    }

    // ── registerMarket ───────────────────────────────

    function testRegisterMarketOnlyFactory() public {
        vm.prank(random);
        vm.expectRevert(PriceOracle.NotFactory.selector);
        oracle.registerMarket(address(0xC));
    }

    function testRegisterMarketSetsRegistered() public {
        address newMarket = address(0xC);
        vm.prank(factoryAddr);
        oracle.registerMarket(newMarket);

        (,, bool registered) = oracle.markets(newMarket);
        assertTrue(registered);
    }

    // ── setPrice ─────────────────────────────────────

    function testSetPriceOnlyKeeper() public {
        vm.prank(random);
        vm.expectRevert(PriceOracle.NotKeeper.selector);
        oracle.setPrice(marketA, 21e16);
    }

    function testSetPriceRevertsUnregistered() public {
        vm.prank(keeper);
        vm.expectRevert(PriceOracle.NotRegistered.selector);
        oracle.setPrice(address(0xDDD), 21e16);
    }

    function testSetPriceUpdatesData() public {
        vm.prank(keeper);
        oracle.setPrice(marketA, 21e16);

        (uint256 price, uint256 updatedAt, bool registered) = oracle.markets(marketA);
        assertEq(price, 21e16);
        assertEq(updatedAt, block.timestamp);
        assertTrue(registered);
    }

    function testSetPriceEmitsEvent() public {
        vm.prank(keeper);
        oracle.setPrice(marketA, 21e16);

        vm.prank(keeper);
        vm.expectEmit(true, false, false, true);
        emit PriceOracle.PriceUpdated(marketA, 21e16, 50e16, block.timestamp);
        oracle.setPrice(marketA, 50e16);
    }

    // ── setBatchPrices ───────────────────────────────

    function testSetBatchPricesOnlyKeeper() public {
        address[] memory addrs = new address[](1);
        uint256[] memory prices = new uint256[](1);
        addrs[0] = marketA;
        prices[0] = 21e16;

        vm.prank(random);
        vm.expectRevert(PriceOracle.NotKeeper.selector);
        oracle.setBatchPrices(addrs, prices);
    }

    function testSetBatchPricesArrayMismatch() public {
        address[] memory addrs = new address[](2);
        uint256[] memory prices = new uint256[](1);
        addrs[0] = marketA;
        addrs[1] = marketB;
        prices[0] = 21e16;

        vm.prank(keeper);
        vm.expectRevert(PriceOracle.ArrayLengthMismatch.selector);
        oracle.setBatchPrices(addrs, prices);
    }

    function testSetBatchPricesUpdatesAll() public {
        address[] memory addrs = new address[](2);
        uint256[] memory prices = new uint256[](2);
        addrs[0] = marketA;
        addrs[1] = marketB;
        prices[0] = 21e16;
        prices[1] = 45e16;

        vm.prank(keeper);
        oracle.setBatchPrices(addrs, prices);

        (uint256 priceA,,) = oracle.markets(marketA);
        (uint256 priceB,,) = oracle.markets(marketB);
        assertEq(priceA, 21e16);
        assertEq(priceB, 45e16);
    }

    function testSetBatchPricesRevertsUnregistered() public {
        address[] memory addrs = new address[](1);
        uint256[] memory prices = new uint256[](1);
        addrs[0] = address(0xDDD);
        prices[0] = 21e16;

        vm.prank(keeper);
        vm.expectRevert(PriceOracle.NotRegistered.selector);
        oracle.setBatchPrices(addrs, prices);
    }

    // ── getPriceData ─────────────────────────────────

    function testGetPriceDataReturnsCorrectValues() public {
        vm.prank(keeper);
        oracle.setPrice(marketA, 21e16);

        vm.prank(marketA);
        (uint256 price, uint256 updatedAt) = oracle.getPriceData();
        assertEq(price, 21e16);
        assertEq(updatedAt, block.timestamp);
    }

    function testGetPriceDataRevertsUnregistered() public {
        vm.prank(random);
        vm.expectRevert(PriceOracle.NotRegistered.selector);
        oracle.getPriceData();
    }

    function testGetPriceDataPerMarket() public {
        vm.prank(keeper);
        oracle.setPrice(marketA, 21e16);
        vm.prank(keeper);
        oracle.setPrice(marketB, 45e16);

        vm.prank(marketA);
        (uint256 priceA,) = oracle.getPriceData();
        assertEq(priceA, 21e16);

        vm.prank(marketB);
        (uint256 priceB,) = oracle.getPriceData();
        assertEq(priceB, 45e16);
    }
}
