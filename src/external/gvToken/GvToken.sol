/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// solhint-disable not-rely-on-time
// solhint-disable reason-string
// solhint-disable max-states-count
// solhint-disable no-inline-assembly
// solhint-disable no-empty-blocks

contract GvToken is UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /* ========== STRUCTS ========== */
    struct MetaData {
        string name;
        string symbol;
        uint256 decimals;
    }
    struct Deposit {
        uint128 amount;
        uint128 start;
    }
    struct WithdrawRequest {
        uint128 amount;
        uint128 endTime;
    }
    struct SupplyPointer {
        uint128 amount;
        uint128 storedAt;
    }
    /* ========== CONSTANTS ========== */
    uint32 public constant MAX_GROW = 52 weeks;
    uint32 public constant WEEK = 1 weeks;
    uint256 internal constant MULTIPLIER = 1e18;

    /* ========== STATE ========== */
    IERC20Upgradeable public stakingToken;
    /// @notice total amount of EASE deposited
    uint256 public totalDeposited;
    /// @notice Time delay for withdrawals which will be set by governance
    uint256 public withdrawalDelay;

    /// @notice total supply of gvToken
    uint256 private _totalSupply;
    MetaData private metadata;
    /// @notice Request by users for withdrawals.
    mapping(address => WithdrawRequest) public withdrawRequests;
    /// @notice User deposits of ease tokens
    mapping(address => Deposit[]) private _deposits;
    /// @notice total amount of ease deposited on user behalf
    mapping(address => uint256) private _totalDeposit;

    /* ========== EVENTS ========== */
    event Deposited(address indexed user, uint256 amount);
    event RedeemRequest(address indexed user, uint256 amount, uint256 endTime);
    event RedeemFinalize(address indexed user, uint256 amount);

    /* ========== INITIALIZE ========== */
    /// @notice Initialize a new gvToken.
    /// @param _stakingToken Address of a token to be deposited in exchange
    /// of Growing vote token.
    function initialize(address _stakingToken) external initializer {
        __ERC1967Upgrade_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
        stakingToken = IERC20Upgradeable(_stakingToken);
        metadata = MetaData("Growing Vote Ease", "gvEase", 18);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    /// @notice Deposit ease and recieve gvEASE
    /// @param amount Amount of ease to deposit.
    function deposit(uint256 amount) external {
        _deposit(msg.sender, amount, block.timestamp);
    }

    /// @notice Request redemption of gvToken back to ease
    /// Has a withdrawal delay which will work in 2 parts(request and finalize)
    /// @param amount The amount of tokens in EASE to withdraw
    function withdrawRequest(uint256 amount) external {
        address user = msg.sender;
        require(amount <= _totalDeposit[user], "not enough deposit!");
        WithdrawRequest memory currRequest = withdrawRequests[user];

        (uint256 depositBalance, uint256 earnedPower) = _balanceOf(user);

        uint256 gvAmtToWithdraw = _gvTokenValue(
            amount,
            depositBalance,
            earnedPower
        );
        _updateDeposits(user, amount);

        _updateTotalSupply(gvAmtToWithdraw);

        uint256 endTime = block.timestamp + withdrawalDelay;
        currRequest.endTime = uint32(endTime);
        currRequest.amount += uint128(amount);
        withdrawRequests[user] = currRequest;

        emit RedeemRequest(user, amount, endTime);
    }

    /// @notice Used to exchange gvToken back to ease token and transfers
    /// pending EASE withdrawal amount to the user if withdrawal delay is over
    function withdrawFinalize() external {
        // Finalize withdraw of a user
        address user = msg.sender;

        WithdrawRequest memory userReq = withdrawRequests[user];
        delete withdrawRequests[user];
        require(
            userReq.endTime <= block.timestamp,
            "withdrawal not yet allowed"
        );

        stakingToken.safeTransfer(user, userReq.amount);

        emit RedeemFinalize(user, userReq.amount);
    }

    /* ========== ONLY GOV ========== */

    /// @notice Change withdrawal delay
    /// @param time Delay time in seconds
    function setDelay(uint256 time) external onlyOwner {
        time = (time / 1 weeks) * 1 weeks;
        require(time >= 1 weeks, "min delay 7 days");
        withdrawalDelay = time;
    }

    /// @notice Update total supply for ecosystem wide grown part
    /// @param newTotalSupply New total supply.(should be > existing supply)
    function setTotalSupply(uint256 newTotalSupply) external onlyOwner {
        uint256 totalEaseDeposit = totalDeposited;

        require(
            newTotalSupply >= totalEaseDeposit &&
                newTotalSupply <= (totalEaseDeposit * 2),
            "not in range"
        );
        // making sure governance can only update for the vote grown part
        require(newTotalSupply > _totalSupply, "existing > new amount");

        _totalSupply = newTotalSupply;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice EIP-20 token name for this token
    function name() external view returns (string memory) {
        return metadata.name;
    }

    /// @notice EIP-20 token symbol for this token
    function symbol() external view returns (string memory) {
        return metadata.symbol;
    }

    /// @notice EIP-20 token decimals for this token
    function decimals() external view returns (uint8) {
        return uint8(metadata.decimals);
    }

    /// @notice Get total ease deposited by user
    /// @param user The address of the account to get total deposit
    /// @return total ease deposited by the user
    function totalDeposit(address user) external view returns (uint256) {
        return _totalDeposit[user];
    }

    /// @notice Get deposits of a user
    /// @param user The address of the account to get the deposits of
    /// @return Details of deposits in an array
    function getUserDeposits(address user)
        external
        view
        returns (Deposit[] memory)
    {
        return _deposits[user];
    }

    /// @notice Total number of tokens in circulation
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @notice Get the number of tokens held by the `account`
    /// @param user The address of the account to get the balance of
    /// @return The number of tokens held
    function balanceOf(address user) public view returns (uint256) {
        (uint256 depositAmount, uint256 powerEarned) = _balanceOf(user);
        return depositAmount + powerEarned;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _authorizeUpgrade(address) internal override onlyOwner {}

    ///@notice Deposit EASE to obtain gvToken that grows upto
    ///twice the amount of ease being deposited.
    ///@param user Wallet address to deposit for
    ///@param amount Amount of EASE to deposit
    ///@param depositStart Start time of deposit(current timestamp
    /// for regular deposit and ahead timestart for vArmor holders)

    function _deposit(
        address user,
        uint256 amount,
        uint256 depositStart
    ) internal {
        require(amount > 0, "cannot deposit 0!");

        stakingToken.safeTransferFrom(user, address(this), amount);

        _updateBalances(user, amount, depositStart);

        emit Deposited(user, amount);
    }

    function _updateBalances(
        address user,
        uint256 amount,
        uint256 depositStart
    ) internal {
        Deposit memory newDeposit = Deposit(
            uint128(amount),
            uint32(depositStart)
        );

        totalDeposited += newDeposit.amount;
        _totalSupply += newDeposit.amount;
        _totalDeposit[user] += newDeposit.amount;
        _deposits[user].push(newDeposit);
    }

    ///@notice Loops through deposits of user from last index and pop's off the
    ///ones that are included in withdraw amount
    function _updateDeposits(address user, uint256 withdrawAmount) internal {
        Deposit memory remainder;
        uint256 totalAmount;
        // current deposit details
        Deposit memory userDeposit;

        totalDeposited -= withdrawAmount;
        _totalDeposit[user] -= withdrawAmount;
        // index to loop from
        uint256 i = _deposits[user].length;
        for (i; i > 0; i--) {
            userDeposit = _deposits[user][i - 1];
            totalAmount += userDeposit.amount;
            // remove last deposit
            _deposits[user].pop();

            // Let's say user tries to withdraw 100 EASE and they have
            // multiple ease deposits [75, 30] EASE when our loop is
            // at index 0 total amount will be 105, that means we need
            // to push the remainder to deposits array
            if (totalAmount >= withdrawAmount) {
                remainder.amount = uint128(totalAmount - withdrawAmount);
                remainder.start = userDeposit.start;
                break;
            }
        }

        // If there is a remainder we need to update the index at which
        // we broke out of loop and push the withdrawan amount to user
        // _deposits withdraw 100 ease from [75, 30] EASE balance becomes
        // [5]
        if (remainder.amount != 0) {
            _deposits[user].push(remainder);
        }
    }

    ///@notice Updates total supply on withdraw request
    /// @param gvAmtToWithdraw Amount of gvToken to withdraw of a user
    function _updateTotalSupply(uint256 gvAmtToWithdraw) internal {
        // if _totalSupply is not in Sync with the grown votes of users
        // and if it's the last user wanting to get out of this contract
        // we need to take consideration of underflow and at the same time
        // set total supply to zero
        if (_totalSupply < gvAmtToWithdraw || totalDeposited == 0) {
            _totalSupply = 0;
        } else {
            _totalSupply -= gvAmtToWithdraw;
        }
    }

    function _balanceOf(address user)
        internal
        view
        returns (uint256 depositBalance, uint256 powerEarned)
    {
        uint256 timestamp = block.timestamp;
        depositBalance = _totalDeposit[user];

        uint256 i = _deposits[user].length;
        for (i; i > 0; i--) {
            Deposit memory userDeposit = _deposits[user][i - 1];
            powerEarned += _powerEarned(userDeposit, timestamp);
        }
    }

    function _powerEarned(Deposit memory userDeposit, uint256 timestamp)
        private
        pure
        returns (uint256 powerGrowth)
    {
        uint256 timeSinceDeposit = timestamp - userDeposit.start;

        if (timeSinceDeposit < MAX_GROW) {
            powerGrowth = (userDeposit.amount * timeSinceDeposit) / MAX_GROW;
        } else {
            powerGrowth = userDeposit.amount;
        }
    }

    function _gvTokenValue(
        uint256 easeAmt,
        uint256 depositBalance,
        uint256 earnedPower
    ) internal pure returns (uint256 gvTokenValue) {
        uint256 conversionRate = (((depositBalance + earnedPower) *
            MULTIPLIER) / depositBalance);
        gvTokenValue = (easeAmt * conversionRate) / MULTIPLIER;
    }

}
