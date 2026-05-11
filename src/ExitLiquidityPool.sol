// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./AmmoManager.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @notice Shared USDC liquidity pool used by all caliber markets to settle exits.
contract ExitLiquidityPool {
    AmmoManager public immutable manager;
    IERC20 public immutable usdc;

    address public liquiditySource;
    address public factory;
    mapping(address => bool) public authorizedMarkets;
    uint256 private _locked;

    error NotOwner();
    error NotMarket();
    error ZeroAddress();
    error InvalidAmount();
    error FactoryAlreadySet();
    error Reentrancy();

    event LiquiditySourceUpdated(address indexed oldSource, address indexed newSource);
    event FactorySet(address indexed factory);
    event MarketAuthorizationUpdated(address indexed market, bool allowed);
    event Deposited(address indexed from, uint256 amount);
    event ExitPaid(address indexed market, address indexed recipient, uint256 amount, uint256 pulledFromSource);

    modifier onlyOwner() {
        if (!manager.isOwner(msg.sender)) revert NotOwner();
        _;
    }

    modifier onlyOwnerOrFactory() {
        if (!manager.isOwner(msg.sender) && msg.sender != factory) revert NotOwner();
        _;
    }

    modifier onlyMarket() {
        if (!authorizedMarkets[msg.sender]) revert NotMarket();
        _;
    }

    modifier nonReentrant() {
        if (_locked == 1) revert Reentrancy();
        _locked = 1;
        _;
        _locked = 0;
    }

    constructor(address manager_, address usdc_, address liquiditySource_) {
        if (manager_ == address(0) || usdc_ == address(0) || liquiditySource_ == address(0)) revert ZeroAddress();
        manager = AmmoManager(manager_);
        usdc = IERC20(usdc_);
        liquiditySource = liquiditySource_;
    }

    function setLiquiditySource(address newSource) external onlyOwner {
        if (newSource == address(0)) revert ZeroAddress();
        address old = liquiditySource;
        liquiditySource = newSource;
        emit LiquiditySourceUpdated(old, newSource);
    }

    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = factory_;
        emit FactorySet(factory_);
    }

    function setMarket(address market, bool allowed) external onlyOwnerOrFactory {
        if (market == address(0)) revert ZeroAddress();
        authorizedMarkets[market] = allowed;
        emit MarketAuthorizationUpdated(market, allowed);
    }

    function deposit(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _safeTransferFrom(usdc, msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    function payExit(address recipient, uint256 amount) external onlyMarket nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        uint256 balance = usdc.balanceOf(address(this));
        uint256 pulled;
        if (balance < amount) {
            pulled = amount - balance;
            _safeTransferFrom(usdc, liquiditySource, address(this), pulled);
        }

        _safeTransfer(usdc, recipient, amount);
        emit ExitPaid(msg.sender, recipient, amount, pulled);
    }

    function availableLiquidity() external view returns (uint256) {
        uint256 sourceBalance = usdc.balanceOf(liquiditySource);
        uint256 sourceAllowance = usdc.allowance(liquiditySource, address(this));
        uint256 sourceAvailable = sourceBalance < sourceAllowance ? sourceBalance : sourceAllowance;
        return usdc.balanceOf(address(this)) + sourceAvailable;
    }

    function shortfallFor(uint256 amount) external view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(this));
        return amount > balance ? amount - balance : 0;
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
