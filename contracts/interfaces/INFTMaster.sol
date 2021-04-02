// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface INFTMaster {
    function fulfillRandomness(bytes32 requestId, uint256 randomness) external;
}
