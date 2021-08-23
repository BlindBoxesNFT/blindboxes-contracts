
// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IVoteStaking.sol";
import "./tokens/BLES.sol";

contract Staking is Ownable {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 constant PER_SHARE_SIZE = 1e12;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many tokens the user has provided.
        uint256 rewardAmount;
        uint256 rewardDebt; // Reward debt.
    }

    // Info of each user that stakes tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of token contract.
        uint256 totalBalance;
        uint256 rewardPerBlock;
        uint256 startBlock;
        uint256 endBlock;
        uint256 lastRewardBlock;
        uint256 accRewardPerShare; // Accumulated BLES per share, times PER_SHARE_SIZE.
        uint256 lockForDays;
    }

    // Info of each pool.
    PoolInfo[] public poolInfo;

    struct LockInfo {
        uint256 pointer;
        uint256 amount;
    }

    // who => poolId => LockInfo
    mapping(address => mapping(uint256 => LockInfo)) public userLockInfo;

    // who => poolId => pointer => amount
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public lockedAmountMap;


    // Claim request.
    struct ClaimRequest {
        uint256 time;
        uint256 amount;
        bool executed;
    }

    // who => ClaimRequest[]
    mapping(address => ClaimRequest[]) public claimRequestMap;

    uint256 public claimWaitTime = 7 days;

    // The bles token
    BLES public blesToken;
    uint256 public blesPrincipal;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event ClaimNow(address indexed user, uint256 indexed pid, uint256 amount);
    event ClaimLater(address indexed user, uint256 indexed pid, uint256 amount, uint256 requestIndex);
    event ClaimLaterExecution(address indexed user, uint256 amount, uint256 requestIndex);

    // VoteStaking for extra mining rewards.
    IVoteStaking public voteStaking;

    uint256 public maximumVotingBlocks = 86400;  // Approximately 3 days in BSC.

    struct Proposal {

        string description;
        uint256 startBlock;
        uint256 endBlock;
        uint256 optionCount;

        // optionIndex => count
        mapping (uint256 => uint256) optionVotes;

        // who => optionIndex => count
        mapping (address => mapping (uint256 => uint256)) userOptionVotes;
    }

    Proposal[] public proposals;

    event Vote(address indexed user, uint256 indexed _pid, uint256 indexed proposalIndex, uint256 optionIndex, uint256 votes);

    // who => block number
    mapping(address => uint256) public userVoteEndBlock;

    constructor(
        BLES _bles
    ) public {
        blesToken = _bles;
    }

    function setClaimWaitTime(uint256 _time) external onlyOwner {
        claimWaitTime = _time;
    }

    function setVoteStaking(IVoteStaking _voteStaking) external onlyOwner {
        voteStaking = _voteStaking;
    }

    function setMaximumVotingBlocks(uint256 _maximumVotingBlocks) external onlyOwner {
        maximumVotingBlocks = _maximumVotingBlocks;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function isBles(IERC20 _token) public view returns(bool) {
        return address(_token) == address(blesToken);
    }

    function hasVoteStaking() public view returns(bool) {
        return address(voteStaking) != address(0);
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Reward will be messed up if you do.
    function add(
        IERC20 _token,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _lockForDays,
        bool _withUpdate
    ) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }

        poolInfo.push(
            PoolInfo({
                token: _token,
                totalBalance: 0,
                rewardPerBlock: _rewardPerBlock,
                startBlock: _startBlock,
                endBlock: _endBlock,
                lastRewardBlock: 0,
                accRewardPerShare: 0,
                lockForDays: _lockForDays
            })
        );
    }

    // Update the given pool's SUSHI allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _lockForDays,
        bool _withUpdate
    ) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }

        poolInfo[_pid].rewardPerBlock = _rewardPerBlock;
        poolInfo[_pid].startBlock = _startBlock;
        poolInfo[_pid].endBlock = _endBlock;
        poolInfo[_pid].lockForDays = _lockForDays;
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
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 accRewardPerShare = pool.accRewardPerShare;

        if (block.number > pool.lastRewardBlock && pool.totalBalance > 0) {
            uint256 reward = getReward(_pid, pool.lastRewardBlock, block.number);
            accRewardPerShare = accRewardPerShare.add(
                reward.mul(PER_SHARE_SIZE).div(pool.totalBalance)
            );
        }

        uint256 extra = 0;
        if (isBles(pool.token) && hasVoteStaking()) {
            extra = voteStaking.pendingReward(_pid, _user);
        }

        return user.amount.mul(accRewardPerShare).div(
            PER_SHARE_SIZE).sub(user.rewardDebt).add(user.rewardAmount).add(extra);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        if (pool.totalBalance == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 reward = getReward(_pid, pool.lastRewardBlock, block.number);

        pool.accRewardPerShare = pool.accRewardPerShare.add(
            reward.mul(PER_SHARE_SIZE).div(pool.totalBalance)
        );

        pool.lastRewardBlock = block.number;

        if (isBles(pool.token) && hasVoteStaking()) {
            voteStaking.updatePool(_pid);
        }
    }

    function unlock(address _who, uint256 _pid) public {
        uint256 lockForDays = poolInfo[_pid].lockForDays;
        uint256 stopAtPointer = (now / 86400).sub(lockForDays);
        LockInfo storage lockInfo = userLockInfo[_who][_pid];

        if (lockForDays == 0 || lockInfo.pointer == 0) {
            return;
        }

        uint256 pointer;
        for (pointer = lockInfo.pointer; pointer <= stopAtPointer; ++pointer) {
            if (lockedAmountMap[_who][_pid][pointer] > 0) {
                lockInfo.amount = lockInfo.amount.add(lockedAmountMap[_who][_pid][pointer]);
                delete lockedAmountMap[_who][_pid][pointer];
            }
        }

        lockInfo.pointer = pointer;
    }

    function getUnlockAmount(address _who, uint256 _pid) external view returns(uint256) {
        uint256 lockForDays = poolInfo[_pid].lockForDays;
        uint256 stopAtPointer = (now / 86400).sub(lockForDays);
        LockInfo storage lockInfo = userLockInfo[_who][_pid];

        if (lockForDays == 0 || lockInfo.pointer == 0) {
            return 0;
        }

        uint256 result = lockInfo.amount;
        for (uint256 pointer = lockInfo.pointer; pointer <= stopAtPointer; ++pointer) {
            if (lockedAmountMap[_who][_pid][pointer] > 0) {
                result = result.add(lockedAmountMap[_who][_pid][pointer]);
            }
        }

        return result;
    }

    function getUnlockArray(address _who, uint256 _pid, uint256 _offset, uint256 _limit) external view returns(LockInfo[] memory) {
        uint256 lockForDays = poolInfo[_pid].lockForDays;
        LockInfo storage lockInfo = userLockInfo[_who][_pid];
        uint256 today = (now / 86400);

        if (lockForDays == 0 || lockInfo.pointer == 0) {
            return new LockInfo[](0);
        }

        uint256 count = 0;
        uint256 pointer;
        for (pointer = lockInfo.pointer + _offset;
                pointer <= today && pointer < lockInfo.pointer + _offset + _limit;
                ++pointer) {
            if (lockedAmountMap[_who][_pid][pointer] > 0) {
                ++count;
            }
        }

        LockInfo[] memory results = new LockInfo[](count);

        count = 0;
        for (pointer = lockInfo.pointer + _offset;
                pointer <= today && pointer < lockInfo.pointer + _offset + _limit;
                ++pointer) {
            if (lockedAmountMap[_who][_pid][pointer] > 0) {
                results[count].pointer = pointer;
                results[count].amount = lockedAmountMap[_who][_pid][pointer];
                ++count;
            }
        }

        return results;
    }

    // Deposit tokens for BLES allocation.
    function deposit(uint256 _pid, uint256 _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);

        if (user.amount > 0) {
            uint256 pending =
                user.amount.mul(pool.accRewardPerShare).div(PER_SHARE_SIZE).sub(
                    user.rewardDebt
                );

            user.rewardAmount = user.rewardAmount.add(pending);
        }

        pool.token.safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );

        pool.totalBalance = pool.totalBalance.add(_amount);

        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(PER_SHARE_SIZE);

        emit Deposit(msg.sender, _pid, _amount);

        if (isBles(pool.token)) {
            blesPrincipal = blesPrincipal.add(_amount);
        }

        if (pool.lockForDays > 0) {
            LockInfo storage lockInfo = userLockInfo[msg.sender][_pid];

            uint256 currentPointer = now / 86400;
            lockedAmountMap[msg.sender][_pid][currentPointer] = _amount;
            if (lockInfo.pointer == 0) {
                lockInfo.pointer = currentPointer;
            }

            unlock(msg.sender, _pid);
        }
    }

    // Withdraw tokens.
    function withdraw(uint256 _pid, uint256 _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (isBles(pool.token) && hasVoteStaking()) {
            require(block.number >= userVoteEndBlock[msg.sender] ||
                    user.amount.sub(voteStaking.getUserStakedAmount(_pid, msg.sender)) >= _amount,
                    "Withdraw more than staked - locked");

            if (block.number >= userVoteEndBlock[msg.sender]) {
                voteStaking.withdraw(_pid, msg.sender);
            }
        } else {
            require(user.amount >= _amount, "Withdraw more than staked");
        }

        if (pool.lockForDays > 0) {
            unlock(msg.sender, _pid);

            LockInfo storage lockInfo = userLockInfo[msg.sender][_pid];
            require(lockInfo.amount >= _amount, "Please wait for unlock");
            lockInfo.amount = lockInfo.amount.sub(_amount);
        }

        updatePool(_pid);

        if (user.amount > 0) {
            uint256 pending =
                user.amount.mul(pool.accRewardPerShare).div(PER_SHARE_SIZE).sub(
                    user.rewardDebt
                );
            user.rewardAmount = user.rewardAmount.add(pending);
        }

        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(PER_SHARE_SIZE);

        pool.token.safeTransfer(address(msg.sender), _amount);
        pool.totalBalance = pool.totalBalance.sub(_amount);

        emit Withdraw(msg.sender, _pid, _amount);

        if (isBles(pool.token)) {
            blesPrincipal = blesPrincipal.sub(_amount);
        }
    }

    // Withdraw tokens.
    function withdrawEarly(uint256 _pid, uint256 _pointer, uint256 _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 currentPointer = now / 86400;

        require(isBles(pool.token), "Must be BLES");
        require(pool.lockForDays > 0, "Must have lockForDays");
        require(currentPointer >= _pointer, "Point must be old");
        require(_pointer + pool.lockForDays >= currentPointer, "Not unlocked yet");

        if (hasVoteStaking()) {
            require(block.number >= userVoteEndBlock[msg.sender] ||
                    user.amount.sub(voteStaking.getUserStakedAmount(_pid, msg.sender)) >= _amount,
                    "Withdraw more than staked - locked");

            if (block.number >= userVoteEndBlock[msg.sender]) {
                voteStaking.withdraw(_pid, msg.sender);
            }
        }

        unlock(msg.sender, _pid);
        require(lockedAmountMap[msg.sender][_pid][_pointer] >= _amount, "_amount too large");
        lockedAmountMap[msg.sender][_pid][_pointer] = lockedAmountMap[msg.sender][_pid][_pointer].sub(_amount);

        updatePool(_pid);

        if (user.amount > 0) {
            uint256 pending =
                user.amount.mul(pool.accRewardPerShare).div(PER_SHARE_SIZE).sub(
                    user.rewardDebt
                );
            user.rewardAmount = user.rewardAmount.add(pending);
        }

        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(PER_SHARE_SIZE);

        uint256 realAmount = _amount.mul(currentPointer.sub(_pointer)).div(pool.lockForDays);

        // Transfer.
        pool.token.safeTransfer(address(msg.sender), realAmount);

        // Burn.
        blesToken.burn(_amount.sub(realAmount));

        pool.totalBalance = pool.totalBalance.sub(_amount);

        emit Withdraw(msg.sender, _pid, _amount);

        // isBles
        blesPrincipal = blesPrincipal.sub(_amount);
    }

    // claim reward immediately
    function claimNow(uint256 _pid, uint256 _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        // Make sure we don't claim user's principal.
        uint256 balance = blesToken.balanceOf(address(this));
        require(balance.sub(_amount) >= blesPrincipal, "Only claim rewards");

        uint256 extra = 0;
        if (isBles(pool.token) && hasVoteStaking()) {
            extra = voteStaking.claim(_pid, msg.sender);
        }

        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accRewardPerShare).div(
            PER_SHARE_SIZE).sub(user.rewardDebt);
        uint256 rewardTotal = user.rewardAmount.add(pending).add(extra);
        require(rewardTotal >= _amount, "Not enough reward");

        // Burn 50%.
        uint256 rewardBurn = _amount.div(2);
        blesToken.burn(rewardBurn);
        blesToken.transfer(address(msg.sender), _amount.sub(rewardBurn));

        user.rewardAmount = rewardTotal.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(PER_SHARE_SIZE);

        emit ClaimNow(msg.sender, _pid, _amount);
    }

    // Request to claim reward later.
    function claimLater(uint256 _pid, uint256 _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        // Make sure we don't claim user's principal.
        uint256 balance = blesToken.balanceOf(address(this));
        require(balance.sub(_amount) >= blesPrincipal, "Only claim rewards");

        uint256 extra = 0;
        if (isBles(pool.token) && hasVoteStaking()) {
            extra = voteStaking.claim(_pid, msg.sender);
        }

        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accRewardPerShare).div(
            PER_SHARE_SIZE).sub(user.rewardDebt);
        uint256 rewardTotal = user.rewardAmount.add(pending).add(extra);
        require(rewardTotal >= _amount, "Not enough reward");

        claimRequestMap[msg.sender].push(ClaimRequest({
            time: now,
            amount: _amount,
            executed: false
        }));

        user.rewardAmount = rewardTotal.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(PER_SHARE_SIZE);

        emit ClaimLater(msg.sender, _pid, _amount, claimRequestMap[msg.sender].length.sub(1));
    }

    function claimLaterReady(uint256 _index) external {
        ClaimRequest storage request = claimRequestMap[msg.sender][_index];

        require(request.amount > 0, "Not request found");
        require(now >= request.time.add(claimWaitTime), "Not ready yet");
        require(!request.executed, "Already executed");

        blesToken.transfer(address(msg.sender), request.amount);
        request.executed = true;

        emit ClaimLaterExecution(msg.sender, request.amount, _index);
    }

    // Voting should have no overlaps.
    function addProposal(
        string memory _description,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _optionCount,
        uint256[] memory _pidArray,
        uint256[] memory _rewardPerBlockArray
    ) external onlyOwner {
        require(hasVoteStaking(), "voteStaking not null");
        require(_pidArray.length == _rewardPerBlockArray.length, "length");

        if (proposals.length > 0) {
            require(block.number >= proposals[proposals.length - 1].endBlock,
                    "Last vote unfinished");
        }

        require(_startBlock > block.number, "requires valid start block");
        require(_endBlock > _startBlock &&
            _endBlock <= _startBlock + maximumVotingBlocks, "requires valid end block");

        Proposal memory proposal;
        proposal.description = _description;
        proposal.startBlock = _startBlock;
        proposal.endBlock = _endBlock;
        proposal.optionCount = _optionCount;

        proposals.push(proposal);

        // set pool in VoteStaking
        for (uint256 i = 0; i < _pidArray.length; ++i) {
            voteStaking.set(_pidArray[i], _rewardPerBlockArray[i], _startBlock, _endBlock, true);
        }
    }

    function voteProposal(uint256 _pid, uint256 _index, uint256 _optionIndex, uint256 _votes) external {
        require(hasVoteStaking(), "voteStaking not null");
        require(_votes > 0, "No votes");

        Proposal storage proposal = proposals[_index];
        require(block.number >= proposal.startBlock, "Not started");
        require(block.number < proposal.endBlock, "Already ended");
        require(_optionIndex < proposal.optionCount, "Invalid option index");

        // If user didn't withdraw from an earlier vote yet, do it now so that he don't have any locked in voteStaking.
        if (userVoteEndBlock[msg.sender] < proposal.startBlock && voteStaking.getUserStakedAmount(_pid, msg.sender) > 0) {
            voteStaking.withdraw(_pid, msg.sender);
        }

        // NOTE: We allow user to vote for more than one options, and vote for multiple times.

        proposal.optionVotes[_optionIndex] = proposal.optionVotes[_optionIndex].add(_votes);
        proposal.userOptionVotes[msg.sender][_optionIndex] = proposal.userOptionVotes[msg.sender][_optionIndex].add(_votes);

        // User will get extra rewards before end block, however won't be able to withdraw
        if (proposal.endBlock > userVoteEndBlock[msg.sender]) {
            userVoteEndBlock[msg.sender] = proposal.endBlock;
        }

        // Stake to voteStake for extra reward.
        voteStaking.deposit(_pid, msg.sender, _votes);

        emit Vote(msg.sender, _pid, _index, _optionIndex, _votes);
    }

    function getProposalOptionVotes(uint256 _proposalIndex, uint256 _optionIndex) external view returns(uint256) {
        return proposals[_proposalIndex].optionVotes[_optionIndex];
    }

    function getProposalUserOptionVotes(uint256 _proposalIndex, address _who, uint256 _optionIndex) external view returns(uint256) {
        return proposals[_proposalIndex].userOptionVotes[_who][_optionIndex];
    }
}
