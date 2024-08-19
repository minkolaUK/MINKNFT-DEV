// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract MinkRewards is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    IERC20 public immutable minkToken;

    // State variables
    uint256 public totalStaked;
    uint256 public totalRewardsDistributed; // Track total rewards distributed

    mapping(address => uint256) private stakes;
    mapping(address => uint256) private rewards;
    mapping(address => uint256) private lastUpdate;
    mapping(address => uint256) private lockEndTimes;
    mapping(address => uint256) private stakingTimestamps;

    

    // Define a struct to hold staking details
    struct StakingDetail {
        uint256 amount;
        uint256 lockPeriod;
        uint256 timestamp;
    }

    // History mappings
    mapping(address => StakingDetail[]) private stakingHistory;
    mapping(address => uint256[]) private rewardHistory;

    // Penalty parameters
    uint256 public penaltyPercentage = 100; // Reward percentage to lose on early unstaking
    uint256 private constant SECONDS_IN_A_YEAR = 31557600; // 365.25 days in seconds

    // Stake limits
    uint256 public immutable minStakeAmount90Days;
    uint256 public immutable minStakeAmount180Days;
    uint256 public immutable minStakeAmount365Days;

    uint256 public immutable lockPeriod90Days = 90 days;
    uint256 public immutable lockPeriod180Days = 180 days;
    uint256 public immutable lockPeriod365Days = 365 days;

    // Reward rate and constants
    uint256 public rewardRate = 1000;
    uint256 private constant REWARD_SCALE = 1e18;

    // Event declarations
    event Staked(address indexed user, uint256 amount, uint256 lockPeriod, uint256 timestamp);
    event Unstaked(address indexed user, uint256 amount, uint256 timestamp);
    event RewardPaid(address indexed user, uint256 reward, uint256 timestamp);
    event RewardRateUpdated(uint256 newRate, uint256 timestamp);
    event MinimumStakeAmountsUpdated(uint256 min90Days, uint256 min180Days, uint256 min365Days, uint256 timestamp);
    event PenaltyPercentageUpdated(uint256 newPenaltyPercentage, uint256 timestamp);

    // Constructor requires initialOwner for Ownable
    constructor(
        address _minkToken,
        uint256 _minStakeAmount90Days,
        uint256 _minStakeAmount180Days,
        uint256 _minStakeAmount365Days
    ) Ownable() ReentrancyGuard() {
        require(_minkToken != address(0), "Token address cannot be zero");
        minkToken = IERC20(_minkToken);
        minStakeAmount90Days = _minStakeAmount90Days;
        minStakeAmount180Days = _minStakeAmount180Days;
        minStakeAmount365Days = _minStakeAmount365Days;
    }

    function batchStake(
        address[] calldata _users,
        uint256[] calldata _amounts,
        uint256[] calldata _lockPeriods
    ) external onlyOwner nonReentrant {
        require(_users.length == _amounts.length && _users.length == _lockPeriods.length, "Mismatched input lengths");
        for (uint256 i = 0; i < _users.length; i++) {
            stakeForUser(_users[i], _amounts[i], _lockPeriods[i]);
        }
    }

    function stake(uint256 _amount, uint256 _lockPeriod) external nonReentrant {
        stakeForUser(msg.sender, _amount, _lockPeriod);
    }

    function stakeForUser(address _user, uint256 _amount, uint256 _lockPeriod) internal {
        require(_amount > 0, "Amount must be greater than zero");

        uint256 minStakeAmount;
        if (_lockPeriod == lockPeriod90Days) {
            minStakeAmount = minStakeAmount90Days;
        } else if (_lockPeriod == lockPeriod180Days) {
            minStakeAmount = minStakeAmount180Days;
        } else if (_lockPeriod == lockPeriod365Days) {
            minStakeAmount = minStakeAmount365Days;
        } else {
            revert("Invalid lock period");
        }

        require(_amount >= minStakeAmount, "Amount is below minimum stake for the selected lock period");

        updateReward(_user);

        bool success = minkToken.transferFrom(_user, address(this), _amount);
        require(success, "Token transfer failed");

        totalStaked = totalStaked.add(_amount);
        stakes[_user] = stakes[_user].add(_amount);
        stakingTimestamps[_user] = block.timestamp;
        lockEndTimes[_user] = block.timestamp.add(_lockPeriod);

        stakingHistory[_user].push(StakingDetail({
            amount: _amount,
            lockPeriod: _lockPeriod,
            timestamp: block.timestamp
        }));

        emit Staked(_user, _amount, _lockPeriod, block.timestamp);
    }


    function unstake(uint256 _index) external nonReentrant {
        require(_index < stakingHistory[msg.sender].length, "Invalid stake index");

        StakingDetail memory stakeDetail = stakingHistory[msg.sender][_index];
        require(stakeDetail.amount > 0, "Stake already withdrawn");

        uint256 lockEndTime = stakeDetail.timestamp.add(stakeDetail.lockPeriod);
        uint256 amountToUnstake = stakeDetail.amount;

        if (block.timestamp >= lockEndTime) {
            // Unstake after lock period: give initial investment plus rewards
            updateReward(msg.sender);
            amountToUnstake = amountToUnstake.add(calculateReward(msg.sender));
        } else {
            // Unstake before lock period: give only the initial investment, no rewards
            // No reward calculation or update here
        }

        totalStaked = totalStaked.sub(stakeDetail.amount);
        stakes[msg.sender] = stakes[msg.sender].sub(stakeDetail.amount);

        stakingHistory[msg.sender][_index].amount = 0;

        bool success = minkToken.transfer(msg.sender, amountToUnstake);
        require(success, "Token transfer failed");

        emit Unstaked(msg.sender, stakeDetail.amount, block.timestamp);
    }



    function claimReward() external nonReentrant {
        updateReward(msg.sender);
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards available");

        rewards[msg.sender] = 0;

        bool success = minkToken.transfer(msg.sender, reward);
        require(success, "Reward transfer failed");

        totalRewardsDistributed = totalRewardsDistributed.add(reward);

        rewardHistory[msg.sender].push(reward);

        emit RewardPaid(msg.sender, reward, block.timestamp);
    }

    function updateReward(address _user) internal {
        uint256 timeElapsed = block.timestamp.sub(lastUpdate[_user]);
        if (stakes[_user] > 0 && timeElapsed > 0) {
            StakingDetail[] memory userStakes = stakingHistory[_user];
            uint256 totalNewReward = 0;

            for (uint256 i = 0; i < userStakes.length; i++) {
                if (userStakes[i].amount > 0) {
                    uint256 apy = getAPY(userStakes[i].lockPeriod);
                    uint256 amount = userStakes[i].amount;
                    uint256 newReward = amount
                    .mul(apy)
                    .mul(timeElapsed)
                    .div(SECONDS_IN_A_YEAR)
                    .div(10000);
                    totalNewReward = totalNewReward.add(newReward);
                }
            }

            rewards[_user] = rewards[_user].add(totalNewReward);
        }
        lastUpdate[_user] = block.timestamp;
    }

    function getStakingDuration(address _user) external view returns (uint256) {
        if (stakes[_user] > 0) {
            return block.timestamp.sub(stakingTimestamps[_user]);
        } else {
            return 0;
        }
    }

    function getLockEndTime(address _user) external view returns (uint256) {
        return lockEndTimes[_user];
    }

    function getStakingHistory(address _user) external view returns (StakingDetail[] memory) {
        return stakingHistory[_user];
    }

    function getRewardHistory(address _user) external view returns (uint256[] memory) {
        return rewardHistory[_user];
    }

    function updateRewardRate(uint256 _newRate) external onlyOwner {
        rewardRate = _newRate;
        emit RewardRateUpdated(_newRate, block.timestamp);
    }

    function updateMinimumStakeAmounts(
        uint256 _min90Days,
        uint256 _min180Days,
        uint256 _min365Days
    ) external onlyOwner {
        emit MinimumStakeAmountsUpdated(_min90Days, _min180Days, _min365Days, block.timestamp);
    }

    function updatePenaltyPercentage(uint256 _newPenaltyPercentage) external onlyOwner {
        penaltyPercentage = _newPenaltyPercentage;
        emit PenaltyPercentageUpdated(_newPenaltyPercentage, block.timestamp);
    }

    function getStakedBalance(address _user) external view returns (uint256) {
        return stakes[_user];
    }

    function getRewardBalance(address _user) external view returns (uint256) {
        return calculateReward(_user);
    }

    function calculateReward(address _user) public view returns (uint256) {
        uint256 timeElapsed = block.timestamp.sub(lastUpdate[_user]);
        if (timeElapsed == 0 || stakes[_user] == 0) {
            return rewards[_user];
        }
        StakingDetail[] memory userStakes = stakingHistory[_user];
        uint256 totalNewReward = 0;

        for (uint256 i = 0; i < userStakes.length; i++) {
            if (userStakes[i].amount > 0) {
                uint256 apy = getAPY(userStakes[i].lockPeriod);
                uint256 amount = userStakes[i].amount;
                // Convert APY to a decimal percentage
                uint256 newReward = amount
                    .mul(apy)
                    .mul(timeElapsed)
                    .div(SECONDS_IN_A_YEAR)
                    .div(10000);
                totalNewReward = totalNewReward.add(newReward);
            }
        }

        return rewards[_user].add(totalNewReward);
    }

    function getAPY(uint256 _lockPeriod) internal pure returns (uint256) {
        if (_lockPeriod == 90 days) {
            return 200; // 2.00% APY as 200 in scaled format
        } else if (_lockPeriod == 180 days) {
            return 250; // 2.50% APY as 250 in scaled format
        } else if (_lockPeriod == 365 days) {
            return 300; // 3.00% APY as 300 in scaled format
        } else {
            revert("Invalid lock period");
        }
    }

    function calculateAPY() public view returns (uint256) {
        // Assuming rewardRate is given per second, calculate APY for 1 year (365 days)
        uint256 secondsPerYear = 365 * 24 * 60 * 60;
        uint256 rewardRatePerYear = rewardRate.mul(secondsPerYear).div(REWARD_SCALE);
        uint256 apy = rewardRatePerYear; // This will need to be scaled or formatted according to your needs
        return apy;
    }

    function getTotalRewardsDistributed() external view returns (uint256) {
        return totalRewardsDistributed;
    }

    function getTotalStaked() external view returns (uint256) {
        return totalStaked;
    }
}