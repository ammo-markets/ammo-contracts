// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AmmoManager} from "./AmmoManager.sol";
import {AmmoFactory} from "./AmmoFactory.sol";
import {ProtocolToken} from "./ProtocolToken.sol";

/// @notice Single supply firewall for protocol-token emissions.
/// @dev LP farming rewards are minted lazily on harvest. Treasury rewards are
///      minted linearly against aggregate gross Caliber mint volume.
contract ProtocolEmissionController {
    uint256 public constant BPS_DENOMINATOR = 10_000;

    AmmoManager public immutable manager;
    AmmoFactory public immutable factory;
    ProtocolToken public immutable protocolToken;

    uint256 public immutable farmCap;
    uint256 public immutable treasuryCap;
    uint256 public immutable volumeTarget;

    address public farm;
    uint256 public farmMinted;
    uint256 public treasuryMinted;
    uint256 public globalUsdcVolume;

    error NotOwner();
    error NotFarm();
    error NotCaliberMarket();
    error ZeroAddress();
    error InvalidAmount();
    error FarmAlreadySet();
    error FarmCapExceeded();

    event FarmSet(address indexed farm);
    event FarmRewardMinted(address indexed to, uint256 amount, uint256 totalFarmMinted);
    event CaliberMintRecorded(
        address indexed market,
        uint256 usdcAmount,
        uint256 globalUsdcVolume,
        uint256 treasuryMintedNow,
        uint256 totalTreasuryMinted
    );

    modifier onlyOwner() {
        if (!manager.isOwner(msg.sender)) revert NotOwner();
        _;
    }

    constructor(
        address manager_,
        address factory_,
        address protocolToken_,
        uint256 farmCap_,
        uint256 treasuryCap_,
        uint256 volumeTarget_
    ) {
        if (manager_ == address(0) || factory_ == address(0) || protocolToken_ == address(0)) {
            revert ZeroAddress();
        }
        if (farmCap_ == 0 || treasuryCap_ == 0 || volumeTarget_ == 0) revert InvalidAmount();

        manager = AmmoManager(manager_);
        factory = AmmoFactory(factory_);
        protocolToken = ProtocolToken(protocolToken_);
        farmCap = farmCap_;
        treasuryCap = treasuryCap_;
        volumeTarget = volumeTarget_;
    }

    function setFarmOnce(address farm_) external onlyOwner {
        if (farm_ == address(0)) revert ZeroAddress();
        if (farm != address(0)) revert FarmAlreadySet();
        farm = farm_;
        emit FarmSet(farm_);
    }

    function mintFarmReward(address to, uint256 amount) external {
        if (msg.sender != farm) revert NotFarm();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) return;

        uint256 newFarmMinted = farmMinted + amount;
        if (newFarmMinted > farmCap) revert FarmCapExceeded();

        farmMinted = newFarmMinted;
        protocolToken.mint(to, amount);
        emit FarmRewardMinted(to, amount, newFarmMinted);
    }

    function recordCaliberMint(uint256 usdcAmount) external {
        if (!factory.isMarket(msg.sender)) revert NotCaliberMarket();
        if (usdcAmount == 0) revert InvalidAmount();
        if (treasuryMinted >= treasuryCap) return;

        globalUsdcVolume += usdcAmount;

        uint256 cappedVolume = globalUsdcVolume;
        if (cappedVolume > volumeTarget) {
            cappedVolume = volumeTarget;
        }

        uint256 targetTreasuryMinted = (treasuryCap * cappedVolume) / volumeTarget;
        if (targetTreasuryMinted <= treasuryMinted) return;

        uint256 mintNow = targetTreasuryMinted - treasuryMinted;
        address treasury = manager.treasury();
        if (treasury == address(0)) revert ZeroAddress();
        treasuryMinted = targetTreasuryMinted;
        protocolToken.mint(treasury, mintNow);

        emit CaliberMintRecorded(msg.sender, usdcAmount, globalUsdcVolume, mintNow, treasuryMinted);
    }
}
