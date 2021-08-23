// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IVoteStaking {
    function set(
        uint256 _pid,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _endBlock,
        bool _withUpdate
    ) external;

    function pendingReward(uint256 _pid, address _user) external view returns (uint256);

    function updatePool(uint256 _pid) external;

    function deposit(uint256 _pid, address _who, uint256 _amount) external;

    function withdraw(uint256 _pid, address _who) external returns(uint256);

    function claim(uint256 _pid, address _who) external returns(uint256);

    function getUserStakedAmount(uint256 _pid, address _who) external view returns(uint256);
}
