
// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IVoteStaking.sol";
import "./tokens/BLES.sol";

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
    mapping(address => UserInfo) public userInfo;

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
    PoolInfo public poolInfo;

    // The bles token
    BLES public blesToken;

    address public stakingAddress;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 amount);

    constructor(
        BLES _bles,
        address _stakingAddress
    ) public {
        blesToken = _bles;
        stakingAddress = _stakingAddress;
    }

    function changeStakingAddress(address _stakingAddress) external onlyOwner {
        stakingAddress = _stakingAddress;
    }

    // Update the given pool's SUSHI allocation point. Can only be called by the owner.
    function set(
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _endBlock,
        bool _withUpdate
    ) external override {
        require(msg.sender == stakingAddress, "Only staking address can call");

        if (_withUpdate) {
            updatePool();
        }

        poolInfo.rewardPerBlock = _rewardPerBlock;
        poolInfo.startBlock = _startBlock;
        poolInfo.endBlock = _endBlock;
    }

    // Return reward multiplier over the given _from to _to block.
    function getReward(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        if (_to <= _from || _from > poolInfo.endBlock || _to < poolInfo.startBlock) {
            return 0;
        }

        uint256 startBlock = _from < poolInfo.startBlock ? poolInfo.startBlock : _from;
        uint256 endBlock = _to < poolInfo.endBlock ? _to : poolInfo.endBlock;
        return endBlock.sub(startBlock).mul(poolInfo.rewardPerBlock);
    }

    // View function to see pending BLES on frontend.
    function pendingReward(address _user)
        external
        view
        override
        returns (uint256)
    {
        UserInfo storage user = userInfo[_user];

        uint256 accRewardPerShare = poolInfo.accRewardPerShare;

        if (block.number > poolInfo.lastRewardBlock && poolInfo.totalBalance > 0) {
            uint256 reward = getReward(poolInfo.lastRewardBlock, block.number);
            accRewardPerShare = accRewardPerShare.add(
                reward.mul(PER_SHARE_SIZE).div(poolInfo.totalBalance)
            );
        }

        return user.amount.mul(accRewardPerShare).div(
            PER_SHARE_SIZE).sub(user.rewardDebt).add(user.rewardAmount);
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool() public override {
        if (block.number <= poolInfo.lastRewardBlock) {
            return;
        }

        if (poolInfo.totalBalance == 0) {
            poolInfo.lastRewardBlock = block.number;
            return;
        }

        uint256 reward = getReward(poolInfo.lastRewardBlock, block.number);

        poolInfo.accRewardPerShare = poolInfo.accRewardPerShare.add(
            reward.mul(PER_SHARE_SIZE).div(poolInfo.totalBalance)
        );

        poolInfo.lastRewardBlock = block.number;
    }

    // Deposit tokens for BLES allocation.
    function deposit(address _who, uint256 _amount) external override {
        require(msg.sender == stakingAddress, "Only staking address can call");

        UserInfo storage user = userInfo[_who];
        updatePool();

        if (user.amount > 0) {
            uint256 pending =
                user.amount.mul(poolInfo.accRewardPerShare).div(PER_SHARE_SIZE).sub(
                    user.rewardDebt
                );

            user.rewardAmount = user.rewardAmount.add(pending);
        }

        blesToken.transferFrom(
            _who,
            address(this),
            _amount
        );
        poolInfo.totalBalance = poolInfo.totalBalance.add(_amount);

        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(poolInfo.accRewardPerShare).div(PER_SHARE_SIZE);
        emit Deposit(_who, _amount);
    }

    // Withdraw all tokens.
    function withdraw(address _who) external override returns(uint256) {
        require(msg.sender == stakingAddress, "Only staking address can call");

        UserInfo storage user = userInfo[_who];

        uint256 userAmount = user.amount;

        if (userAmount == 0) {
            return 0;
        }

        updatePool();

        uint256 pending = userAmount.mul(poolInfo.accRewardPerShare).div(
            PER_SHARE_SIZE).sub(user.rewardDebt);
        user.rewardAmount = user.rewardAmount.add(pending);

        user.amount = 0;
        user.rewardDebt = 0;

        blesToken.transfer(_who, userAmount);
        poolInfo.totalBalance = poolInfo.totalBalance.sub(userAmount);

        emit Withdraw(_who, userAmount);

        return userAmount;
    }

    // claim all reward.
    function claim(address _who) external override returns(uint256) {
        require(msg.sender == stakingAddress, "Only staking address can call");

        UserInfo storage user = userInfo[_who];

        updatePool();

        uint256 pending = user.amount.mul(poolInfo.accRewardPerShare).div(
            PER_SHARE_SIZE).sub(user.rewardDebt);
        uint256 rewardTotal = user.rewardAmount.add(pending);

        uint256 balance = blesToken.balanceOf(address(this));
        require(balance.sub(rewardTotal) >= poolInfo.totalBalance, "Only claim rewards");
        blesToken.transfer(_who, rewardTotal);

        user.rewardAmount = 0;
        user.rewardDebt = user.amount.mul(poolInfo.accRewardPerShare).div(PER_SHARE_SIZE);

        emit Claim(_who, rewardTotal);

        return rewardTotal;
    }

    function getUserStakedAmount(address _who) external override view returns(uint256) {
        UserInfo storage user = userInfo[_who];
        return user.amount;
    }
}
