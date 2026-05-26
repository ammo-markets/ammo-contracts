// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AmmoManager.sol";
import "../src/CaliberToken.sol";
import "../src/CaliberMarket.sol";
import "../src/external/gvToken/GvToken.sol";
import "./MockERC20.sol";
import "./MockEmissionController.sol";
import "./MockPriceOracle.sol";

contract GvAmmoTest is Test {
    uint256 constant ORACLE_PRICE = 1e18;
    bytes32 constant CALIBER_9MM = bytes32("9MM");

    AmmoManager manager;
    CaliberMarket market;
    CaliberToken ammo;
    GvToken gvAmmo;
    MockERC20 usdc;
    MockPriceOracle oracle;
    MockEmissionController emissionController;

    address user = address(0xA11CE);
    address treasury = address(0x73EA5);
    address feeRecipient = address(0xFEE1);
    address wavax = address(0xAA0C);

    event Deposited(address indexed user, uint256 amount);
    event RedeemRequest(address indexed user, uint256 amount, uint256 endTime);
    event RedeemFinalize(address indexed user, uint256 amount);

    function setUp() public {
        vm.warp(10 weeks);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockPriceOracle(ORACLE_PRICE);
        emissionController = new MockEmissionController(address(new MockERC20("Protocol", "AMMO", 18)));

        manager = new AmmoManager(feeRecipient, wavax);
        manager.setTreasury(treasury);

        market = new CaliberMarket(
            CaliberMarket.MarketConfig({
                manager: address(manager),
                usdc: address(usdc),
                usdcDecimals: 6,
                oracle: address(oracle),
                emissionController: address(emissionController),
                caliberId: CALIBER_9MM,
                tokenName: "Ammo 9MM",
                tokenSymbol: "MO9MM",
                minMintRounds: 1
            })
        );
        ammo = market.token();
        manager.setMarketDailyMintCap(address(market), type(uint256).max);

        gvAmmo = new GvToken();
        gvAmmo.initialize(address(ammo));
        gvAmmo.setDelay(1 weeks);

        _mintAmmo(user, 1_000e6);
    }

    function testInitializeConfiguresGvAmmoMetadataAndDependencies() public view {
        assertEq(gvAmmo.name(), "Growing Vote Ease");
        assertEq(gvAmmo.symbol(), "gvEase");
        assertEq(gvAmmo.decimals(), 18);
        assertEq(address(gvAmmo.stakingToken()), address(ammo));
        assertEq(gvAmmo.withdrawalDelay(), 1 weeks);
    }

    function testDepositAmmoMintsGrowingVotingPower() public {
        uint256 amount = 100e18;
        _approveGvAmmo(user, amount);

        vm.expectEmit(true, false, false, true);
        emit Deposited(user, amount);

        vm.prank(user);
        gvAmmo.deposit(amount);

        assertEq(ammo.balanceOf(address(gvAmmo)), amount);
        assertEq(gvAmmo.totalDeposit(user), amount);
        assertEq(gvAmmo.totalDeposited(), amount);
        assertEq(gvAmmo.totalSupply(), amount);
        assertEq(gvAmmo.balanceOf(user), amount);

        vm.warp(block.timestamp + 26 weeks);
        assertEq(gvAmmo.balanceOf(user), amount + (amount / 2));

        vm.warp(block.timestamp + 26 weeks);
        assertEq(gvAmmo.balanceOf(user), amount * 2);
    }

    function testWithdrawRequestAndFinalizeReturnsAmmoAfterDelay() public {
        uint256 depositAmount = 100e18;
        uint256 withdrawAmount = 40e18;
        _depositFrom(user, depositAmount);

        uint256 endTime = block.timestamp + 1 weeks;
        vm.expectEmit(true, false, false, true);
        emit RedeemRequest(user, withdrawAmount, endTime);

        vm.prank(user);
        gvAmmo.withdrawRequest(withdrawAmount);

        (uint128 requestedAmount, uint128 requestEndTime) = gvAmmo.withdrawRequests(user);
        assertEq(requestedAmount, withdrawAmount);
        assertEq(requestEndTime, endTime);
        assertEq(gvAmmo.totalDeposit(user), depositAmount - withdrawAmount);
        assertEq(gvAmmo.totalDeposited(), depositAmount - withdrawAmount);

        vm.prank(user);
        vm.expectRevert("withdrawal not yet allowed");
        gvAmmo.withdrawFinalize();

        vm.warp(endTime);
        uint256 userAmmoBefore = ammo.balanceOf(user);

        vm.expectEmit(true, false, false, true);
        emit RedeemFinalize(user, withdrawAmount);

        vm.prank(user);
        gvAmmo.withdrawFinalize();

        assertEq(ammo.balanceOf(user), userAmmoBefore + withdrawAmount);
        (requestedAmount, requestEndTime) = gvAmmo.withdrawRequests(user);
        assertEq(requestedAmount, 0);
        assertEq(requestEndTime, 0);
    }

    function _depositFrom(address account, uint256 amount) internal {
        _approveGvAmmo(account, amount);
        vm.prank(account);
        gvAmmo.deposit(amount);
    }

    function _approveGvAmmo(address account, uint256 amount) internal {
        vm.prank(account);
        ammo.approve(address(gvAmmo), amount);
    }

    function _mintAmmo(address account, uint256 usdcAmount) internal {
        usdc.mint(account, usdcAmount);
        vm.prank(account);
        usdc.approve(address(market), usdcAmount);
        vm.prank(account);
        uint256 orderId = market.startMint(usdcAmount, 0);
        market.finalizeMint(orderId);
    }
}
