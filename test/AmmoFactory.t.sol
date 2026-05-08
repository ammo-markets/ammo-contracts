// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AmmoManager.sol";
import "../src/AmmoFactory.sol";
import "../src/PriceOracle.sol";
import "../src/CaliberMarket.sol";
import "./MockERC20.sol";
import "./MockEmissionController.sol";

contract AmmoFactoryTest is Test {
    AmmoManager manager;
    AmmoFactory factory;
    PriceOracle oracle;
    MockERC20 usdc;
    MockEmissionController emissionController;

    address feeRecipient = address(0xFEE1);
    address alice = address(0xA11CE);

    bytes32 constant CALIBER_9MM = bytes32("9MM");
    bytes32 constant CALIBER_556 = bytes32("556NATO");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        manager = new AmmoManager(feeRecipient, address(0xAA0C));
        oracle = new PriceOracle(address(manager));
        factory = new AmmoFactory(address(manager), address(usdc), 6, address(oracle));
        emissionController = new MockEmissionController(address(new MockERC20("Protocol", "AMMO", 18)));
        factory.setEmissionControllerOnce(address(emissionController));
        oracle.setFactory(address(factory));
    }

    // ── Create caliber ──────────────────────────────

    function testCreateCaliber() public {
        (address market, address token) = factory.createCaliber(CALIBER_9MM, "Ammo 9MM", "MO9MM", 150, 150, 50);

        assertTrue(market != address(0));
        assertTrue(token != address(0));

        (address storedMarket, address storedToken) = factory.calibers(CALIBER_9MM);
        assertEq(storedMarket, market);
        assertEq(storedToken, token);
        assertEq(factory.getCaliberCount(), 1);

        // Verify market is wired correctly
        CaliberMarket cm = CaliberMarket(market);
        assertEq(address(cm.manager()), address(manager));
        assertEq(address(cm.oracle()), address(oracle));
        assertEq(address(cm.emissionController()), address(emissionController));
        assertEq(cm.caliberId(), CALIBER_9MM);
        assertEq(cm.mintFeeBps(), 150);
        assertEq(cm.minMintRounds(), 50);

        // Verify market is registered with oracle
        (,, bool registered) = oracle.markets(market);
        assertTrue(registered);
        assertTrue(factory.isMarket(market));
    }

    function testCannotResetEmissionController() public {
        vm.expectRevert(AmmoFactory.EmissionControllerAlreadySet.selector);
        factory.setEmissionControllerOnce(address(emissionController));
    }

    function testCreateMultipleCalibers() public {
        factory.createCaliber(CALIBER_9MM, "Ammo 9MM", "MO9MM", 150, 150, 50);
        factory.createCaliber(CALIBER_556, "Ammo 5.56", "MO556", 200, 200, 25);
        assertEq(factory.getCaliberCount(), 2);
    }

    function testCannotCreateDuplicateCaliber() public {
        factory.createCaliber(CALIBER_9MM, "Ammo 9MM", "MO9MM", 150, 150, 50);

        vm.expectRevert(AmmoFactory.CaliberExists.selector);
        factory.createCaliber(CALIBER_9MM, "Ammo 9MM v2", "MO9V2", 150, 150, 50);
    }

    function testOnlyOwnerCanCreateCaliber() public {
        vm.prank(alice);
        vm.expectRevert(AmmoFactory.NotOwner.selector);
        factory.createCaliber(CALIBER_9MM, "Ammo 9MM", "MO9MM", 150, 150, 50);
    }
}
