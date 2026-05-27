// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AmmoManager} from "./AmmoManager.sol";

/// @notice ERC20 token with fee-on-transfer tax for DEX trades.
/// @dev Mint/burn restricted to its CaliberMarket. Tax config is read from AmmoManager.
///      DEX taxes are sent directly to the protocol treasury.
contract CaliberToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 internal constant _BPS_DIVISOR = 10_000;

    uint256 public totalSupply;
    address public immutable market;
    AmmoManager public immutable manager;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    error NotMarket();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();
    error Denied();

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    modifier onlyMarket() {
        if (msg.sender != market) revert NotMarket();
        _;
    }

    constructor(string memory name_, string memory symbol_, address market_, address manager_) {
        if (market_ == address(0) || manager_ == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        market = market_;
        manager = AmmoManager(manager_);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance();
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external onlyMarket {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyMarket {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    // ── Internal ────────────────────────────────────

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        if (manager.isDenied(from) || manager.isDenied(to)) revert Denied();

        uint256 taxAmount = 0;

        if (!_isLocalExempt(from, to)) {
            bool protocolExempt = manager.taxExempt(from) || manager.taxExempt(to) || _isGvAmmoTaxExempt(from, to);
            if (!protocolExempt) {
                taxAmount = _determineTax(from, to, amount);
            }
        }

        uint256 receiveAmount = amount - taxAmount;
        balanceOf[from] -= amount;
        balanceOf[to] += receiveAmount;
        emit Transfer(from, to, receiveAmount);

        if (taxAmount > 0) _collectTax(from, taxAmount);
    }

    function _collectTax(address from, uint256 taxAmount) internal {
        address treasury_ = manager.treasury();
        if (treasury_ == address(0)) {
            _creditTax(from, address(this), taxAmount);
            return;
        }

        _sweepHeldTax(treasury_);
        _creditTax(from, treasury_, taxAmount);
    }

    function _sweepHeldTax(address treasury_) internal {
        uint256 heldTax = balanceOf[address(this)];
        if (heldTax == 0) return;

        balanceOf[address(this)] = 0;
        _creditTax(address(this), treasury_, heldTax);
    }

    function _creditTax(address from, address to, uint256 amount) internal {
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _determineTax(address from, address to, uint256 amount) internal view returns (uint256) {
        (uint256 buyBps,) = manager.tokenPoolTax(address(this), from);
        if (buyBps > 0) return (amount * buyBps) / _BPS_DIVISOR;

        (, uint256 sellBps) = manager.tokenPoolTax(address(this), to);
        if (sellBps > 0) return (amount * sellBps) / _BPS_DIVISOR;

        return 0;
    }

    function _isGvAmmoTaxExempt(address from, address to) internal view returns (bool) {
        (uint256 buyBps,) = manager.tokenPoolTax(address(this), from);
        if (buyBps > 0) return manager.isGvAmmoTaxExempt(to);

        (, uint256 sellBps) = manager.tokenPoolTax(address(this), to);
        if (sellBps > 0) return manager.isGvAmmoTaxExempt(from);

        return false;
    }

    /// @dev market: CaliberMarket mint/redeem/transfer operations.
    ///      Router transfers are not exempt because sells also arrive as router-mediated
    ///      user-to-pair transfers. Liquidity adds should use an exempt helper contract.
    function _isLocalExempt(address from, address to) internal view returns (bool) {
        return from == market || to == market;
    }
}
