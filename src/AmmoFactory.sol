// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./AmmoManager.sol";
import "./CaliberMarket.sol";
import "./PriceOracle.sol";

/// @notice Deploys and registers per-caliber CaliberMarket + AmmoToken pairs.
/// @dev Only callable by the AmmoManager owner. Each caliber gets its own
///      isolated market contract and token. The shared oracle is passed at
///      construction and markets are auto-registered with it.
contract AmmoFactory {
    AmmoManager public immutable manager;
    address public immutable usdc;
    uint8 public immutable usdcDecimals;
    address public immutable oracle;
    address public emissionController;

    struct CaliberInfo {
        address market;
        address token;
    }

    mapping(bytes32 => CaliberInfo) public calibers;
    mapping(address => bool) public isMarket;
    bytes32[] public caliberIds;

    error NotOwner();
    error CaliberExists();
    error EmissionControllerNotSet();
    error EmissionControllerAlreadySet();
    error ZeroAddress();

    event CaliberCreated(bytes32 indexed caliberId, address indexed market, address indexed token);
    event EmissionControllerSet(address indexed emissionController);

    modifier onlyOwner() {
        if (!manager.isOwner(msg.sender)) revert NotOwner();
        _;
    }

    constructor(address manager_, address usdc_, uint8 usdcDecimals_, address oracle_) {
        if (manager_ == address(0) || usdc_ == address(0) || oracle_ == address(0)) revert ZeroAddress();
        manager = AmmoManager(manager_);
        usdc = usdc_;
        usdcDecimals = usdcDecimals_;
        oracle = oracle_;
    }

    function setEmissionControllerOnce(address emissionController_) external onlyOwner {
        if (emissionController_ == address(0)) revert ZeroAddress();
        if (emissionController != address(0)) revert EmissionControllerAlreadySet();
        emissionController = emissionController_;
        emit EmissionControllerSet(emissionController_);
    }

    /// @notice Deploy a new caliber market + token pair.
    /// @return market The deployed CaliberMarket address.
    /// @return token  The deployed AmmoToken address (created by the market).
    function createCaliber(
        bytes32 caliberId,
        string calldata name,
        string calldata symbol,
        uint256 mintFeeBps,
        uint256 redeemFeeBps,
        uint256 minMintRounds
    ) external onlyOwner returns (address market, address token) {
        if (calibers[caliberId].market != address(0)) revert CaliberExists();
        address controller = emissionController;
        if (controller == address(0)) revert EmissionControllerNotSet();

        CaliberMarket marketContract = new CaliberMarket(
            CaliberMarket.MarketConfig({
                manager: address(manager),
                usdc: usdc,
                usdcDecimals: usdcDecimals,
                oracle: oracle,
                emissionController: controller,
                caliberId: caliberId,
                tokenName: name,
                tokenSymbol: symbol,
                mintFeeBps: mintFeeBps,
                redeemFeeBps: redeemFeeBps,
                minMintRounds: minMintRounds
            })
        );

        market = address(marketContract);
        token = address(marketContract.token());

        // Auto-register market with the shared oracle
        PriceOracle(oracle).registerMarket(market);

        calibers[caliberId] = CaliberInfo({market: market, token: token});
        isMarket[market] = true;
        caliberIds.push(caliberId);

        emit CaliberCreated(caliberId, market, token);
    }

    /// @notice Number of calibers registered.
    function getCaliberCount() external view returns (uint256) {
        return caliberIds.length;
    }
}
