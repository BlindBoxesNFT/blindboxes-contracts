// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IVoteStaking {
    function set(
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _endBlock,
        bool _withUpdate
    ) external;

    function pendingReward(address _user) external view returns (uint256);

    function updatePool() external;

    function deposit(address _who, uint256 _amount) external;

    function withdraw(address _who) external returns(uint256);

    function claim(address _who) external returns(uint256);

    function getUserStakedAmount(address _who) external view returns(uint256);
}
