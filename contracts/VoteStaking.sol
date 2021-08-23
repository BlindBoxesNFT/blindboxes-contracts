
// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IVoteStaking.sol";

interface IStaking {
  function userInfo(uint256 pid,  address who) external view returns(uint256, uint256, uint256);
}

// VoteStaking is a small pool that provides extra staking reward, and should be called by Staking.
contract VoteStaking is Ownable, IVoteStaking {

    using SafeMath for uint256;

    uint256 constant PER_SHARE_SIZE = 1e12;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many tokens the user has provided.
        uint256 rewardAmount;
        uint256 rewardDebt; // Reward debt.
    }

    // Info of each user that stakes tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Info of the pool.
    struct PoolInfo {
        uint256 totalBalance;
        uint256 rewardPerBlock;
        uint256 startBlock;
        uint256 endBlock;
        uint256 lastRewardBlock;
        uint256 accRewardPerShare; // Accumulated BLES per share, times PER_SHARE_SIZE.
    }

    // Info of the pool.
    mapping(uint256 => PoolInfo) public poolInfo;

    address public stakingAddress;

    event Deposit(uint256 indexed pid, address indexed user, uint256 amount);
    event Withdraw(uint256 indexed pid, address indexed user, uint256 amount);
    event Claim(uint256 indexed pid, address indexed user, uint256 amount);

    constructor(
        address _stakingAddress
    ) public {
        stakingAddress = _stakingAddress;
    }

    function changeStakingAddress(address _stakingAddress) external onlyOwner {
        stakingAddress = _stakingAddress;
    }

    // Update the given pool's SUSHI allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _endBlock,
        bool _withUpdate
    ) external override {
        require(msg.sender == stakingAddress, "Only staking address can call");

        if (_withUpdate) {
            updatePool(_pid);
        }

        poolInfo[_pid].rewardPerBlock = _rewardPerBlock;
        poolInfo[_pid].startBlock = _startBlock;
        poolInfo[_pid].endBlock = _endBlock;
    }

    // Return reward multiplier over the given _from to _to block.
    function getReward(uint256 _pid, uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        if (_to <= _from || _from > poolInfo[_pid].endBlock || _to < poolInfo[_pid].startBlock) {
            return 0;
        }

        uint256 startBlock = _from < poolInfo[_pid].startBlock ? poolInfo[_pid].startBlock : _from;
        uint256 endBlock = _to < poolInfo[_pid].endBlock ? _to : poolInfo[_pid].endBlock;
        return endBlock.sub(startBlock).mul(poolInfo[_pid].rewardPerBlock);
    }

    // View function to see pending BLES on frontend.
    function pendingReward(uint256 _pid, address _user)
        external
        view
        override
        returns (uint256)
    {
        UserInfo storage user = userInfo[_pid][_user];

        uint256 accRewardPerShare = poolInfo[_pid].accRewardPerShare;

        if (block.number > poolInfo[_pid].lastRewardBlock && poolInfo[_pid].totalBalance > 0) {
            uint256 reward = getReward(_pid, poolInfo[_pid].lastRewardBlock, block.number);
            accRewardPerShare = accRewardPerShare.add(
                reward.mul(PER_SHARE_SIZE).div(poolInfo[_pid].totalBalance)
            );
        }

        return user.amount.mul(accRewardPerShare).div(
            PER_SHARE_SIZE).sub(user.rewardDebt).add(user.rewardAmount);
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public override {
        if (block.number <= poolInfo[_pid].lastRewardBlock) {
            return;
        }

        if (poolInfo[_pid].totalBalance == 0) {
            poolInfo[_pid].lastRewardBlock = block.number;
            return;
        }

        uint256 reward = getReward(_pid, poolInfo[_pid].lastRewardBlock, block.number);

        poolInfo[_pid].accRewardPerShare = poolInfo[_pid].accRewardPerShare.add(
            reward.mul(PER_SHARE_SIZE).div(poolInfo[_pid].totalBalance)
        );

        poolInfo[_pid].lastRewardBlock = block.number;
    }

    // Deposit tokens for BLES allocation.
    function deposit(uint256 _pid, address _who, uint256 _amount) external override {
        require(msg.sender == stakingAddress, "Only staking address can call");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_who];

        (uint256 stakingAmount,,) = IStaking(stakingAddress).userInfo(_pid, _who);
        require(stakingAmount >= user.amount.add(_amount), "Not enough staking amount");

        updatePool(_pid);

        if (user.amount > 0) {
            uint256 pending =
                user.amount.mul(pool.accRewardPerShare).div(PER_SHARE_SIZE).sub(
                    user.rewardDebt
                );

            user.rewardAmount = user.rewardAmount.add(pending);
        }

        pool.totalBalance = pool.totalBalance.add(_amount);

        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(PER_SHARE_SIZE);
        emit Deposit(_pid, _who, _amount);
    }

    // Withdraw all tokens.
    function withdraw(uint256 _pid, address _who) external override returns(uint256) {
        require(msg.sender == stakingAddress, "Only staking address can call");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_who];

        uint256 userAmount = user.amount;

        if (userAmount == 0) {
            return 0;
        }

        updatePool(_pid);

        uint256 pending = userAmount.mul(pool.accRewardPerShare).div(
            PER_SHARE_SIZE).sub(user.rewardDebt);
        user.rewardAmount = user.rewardAmount.add(pending);

        user.amount = 0;
        user.rewardDebt = 0;

        pool.totalBalance = pool.totalBalance.sub(userAmount);

        emit Withdraw(_pid, _who, userAmount);

        return userAmount;
    }

    // claim all reward.
    function claim(uint256 _pid, address _who) external override returns(uint256) {
        require(msg.sender == stakingAddress, "Only staking address can call");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_who];

        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accRewardPerShare).div(
            PER_SHARE_SIZE).sub(user.rewardDebt);
        uint256 rewardTotal = user.rewardAmount.add(pending);

        user.rewardAmount = 0;
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(PER_SHARE_SIZE);

        emit Claim(_pid, _who, rewardTotal);

        return rewardTotal;
    }

    function getUserStakedAmount(uint256 _pid, address _who) external override view returns(uint256) {
        UserInfo storage user = userInfo[_pid][_who];
        return user.amount;
    }
}
