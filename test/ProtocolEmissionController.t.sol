// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AmmoFactory.sol";
import "../src/AmmoManager.sol";
import "../src/AmmoMarketLPFarm.sol";
import "../src/CaliberMarket.sol";
import "../src/PriceOracle.sol";
import "../src/ProtocolEmissionController.sol";
import "../src/ProtocolToken.sol";
import "./MockERC20.sol";

contract ProtocolEmissionControllerTest is Test {
    AmmoManager manager;
    AmmoFactory factory;
    PriceOracle oracle;
    ProtocolToken protocolToken;
    ProtocolEmissionController controller;
    MockERC20 usdc;
    MockERC20 lpToken;

    address treasury = address(0x73EA5);
    address feeRecipient = address(0xFEE1);
    address user = address(0xBEEF);
    address wavax = address(0xAA0C);

    uint256 constant FARM_CAP = 365_000_000e18;
    uint256 constant TREASURY_CAP = (FARM_CAP * 40) / 60;
    uint256 constant VOLUME_TARGET = 10_000_000e6;
    uint256 constant ORACLE_PRICE = 25e16;

    function setUp() public {
        manager = new AmmoManager(feeRecipient, wavax);
        manager.setTreasury(treasury);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        lpToken = new MockERC20("LP", "LP", 18);
        oracle = new PriceOracle(address(manager));
        factory = new AmmoFactory(address(manager), address(usdc), 6, address(oracle));

        protocolToken = new ProtocolToken("Ammo Protocol", "AMMO", address(manager));
        controller = new ProtocolEmissionController(
            address(manager), address(factory), address(protocolToken), FARM_CAP, TREASURY_CAP, VOLUME_TARGET
        );

        protocolToken.setMinterOnce(address(controller));
        factory.setEmissionControllerOnce(address(controller));
        oracle.setFactory(address(factory));
    }

    function testCaliberMintMintsTreasuryShareFromUsdcVolume() public {
        (address market,) = factory.createCaliber(bytes32("9MM"), "Ammo 9MM", "MO9MM", 150, 150, 0);
        oracle.setPrice(market, ORACLE_PRICE);

        usdc.mint(user, 100e6);
        vm.prank(user);
        usdc.approve(market, 100e6);

        vm.prank(user);
        CaliberMarket(market).mint(100e6);

        uint256 expectedTreasuryMint = (TREASURY_CAP * 100e6) / VOLUME_TARGET;
        assertEq(controller.globalUsdcVolume(), 100e6);
        assertEq(controller.treasuryMinted(), expectedTreasuryMint);
        assertEq(protocolToken.balanceOf(treasury), expectedTreasuryMint);
    }

    function testTreasuryMintCapsAtVolumeTarget() public {
        (address market,) = factory.createCaliber(bytes32("9MM"), "Ammo 9MM", "MO9MM", 150, 150, 0);
        oracle.setPrice(market, ORACLE_PRICE);

        usdc.mint(user, VOLUME_TARGET + 1e6);
        vm.prank(user);
        usdc.approve(market, VOLUME_TARGET + 1e6);

        vm.prank(user);
        CaliberMarket(market).mint(VOLUME_TARGET + 1e6);

        assertEq(controller.treasuryMinted(), TREASURY_CAP);
        assertEq(protocolToken.balanceOf(treasury), TREASURY_CAP);
    }

    function testAdditionalCaliberMintAfterTreasuryCapDoesNotRevertOrMintMore() public {
        (address market,) = factory.createCaliber(bytes32("9MM"), "Ammo 9MM", "MO9MM", 150, 150, 0);
        oracle.setPrice(market, ORACLE_PRICE);

        usdc.mint(user, VOLUME_TARGET + 101e6);
        vm.prank(user);
        usdc.approve(market, VOLUME_TARGET + 101e6);

        vm.prank(user);
        CaliberMarket(market).mint(VOLUME_TARGET + 1e6);

        assertEq(controller.treasuryMinted(), TREASURY_CAP);
        assertEq(protocolToken.balanceOf(treasury), TREASURY_CAP);

        vm.prank(user);
        CaliberMarket(market).mint(100e6);

        assertEq(controller.globalUsdcVolume(), VOLUME_TARGET + 1e6);
        assertEq(controller.treasuryMinted(), TREASURY_CAP);
        assertEq(protocolToken.balanceOf(treasury), TREASURY_CAP);
    }

    function testPostCapControllerRecordDoesNotRequireTreasuryAddress() public {
        (address market,) = factory.createCaliber(bytes32("9MM"), "Ammo 9MM", "MO9MM", 150, 150, 0);
        oracle.setPrice(market, ORACLE_PRICE);

        usdc.mint(user, VOLUME_TARGET + 101e6);
        vm.prank(user);
        usdc.approve(market, VOLUME_TARGET + 101e6);

        vm.prank(user);
        CaliberMarket(market).mint(VOLUME_TARGET + 1e6);

        vm.store(address(manager), bytes32(uint256(4)), bytes32(uint256(0)));
        assertEq(manager.treasury(), address(0));

        vm.prank(market);
        controller.recordCaliberMint(100e6);

        assertEq(controller.globalUsdcVolume(), VOLUME_TARGET + 1e6);
        assertEq(controller.treasuryMinted(), TREASURY_CAP);
        assertEq(protocolToken.balanceOf(treasury), TREASURY_CAP);
    }

    function testOnlyRegisteredMarketsCanRecordCaliberVolume() public {
        vm.expectRevert(ProtocolEmissionController.NotCaliberMarket.selector);
        controller.recordCaliberMint(100e6);
    }

    function testFarmMintsLazilyOnHarvestThroughController() public {
        AmmoMarketLPFarm farm = new AmmoMarketLPFarm(
            address(manager), address(controller), address(protocolToken), 10 days, 1_000e18, 5_000e18
        );
        controller.setFarmOnce(address(farm));
        farm.addPool(bytes32("9MM"), address(lpToken));

        lpToken.mint(user, 10e18);
        vm.startPrank(user);
        lpToken.approve(address(farm), 10e18);
        farm.deposit(0, 10e18);
        vm.warp(block.timestamp + 1 days);

        assertEq(protocolToken.balanceOf(user), 0);

        farm.harvest(0);
        vm.stopPrank();

        assertEq(protocolToken.balanceOf(user), 950e18);
        assertEq(controller.farmMinted(), 950e18);
    }

    function testFarmCanOnlyBeSetOnce() public {
        controller.setFarmOnce(address(0xF00D));

        vm.expectRevert(ProtocolEmissionController.FarmAlreadySet.selector);
        controller.setFarmOnce(address(0xBEEF));
    }

    function testProtocolTokenMinterCanOnlyBeSetOnce() public {
        ProtocolToken token = new ProtocolToken("Test", "TEST", address(manager));
        token.setMinterOnce(address(controller));

        vm.expectRevert(ProtocolToken.MinterAlreadySet.selector);
        token.setMinterOnce(address(0xBEEF));
    }
}
