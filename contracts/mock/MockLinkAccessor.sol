// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "../interfaces/INFTMaster.sol";
import "../interfaces/ILinkAccessor.sol";

contract MockLinkAccessor is ILinkAccessor {

    INFTMaster public nftMaster;
    uint256 public randomness;
    bytes32 public requestId;

    constructor(
        INFTMaster nftMaster_
    ) public {
        nftMaster = nftMaster_;
    }

    function setRandomness(uint256 randomness_) external {
        randomness = randomness_;
    }

    function triggerRandomness() external {
        nftMaster.fulfillRandomness(requestId, randomness);
    }

    function requestRandomness(uint256 userProvidedSeed_) public override returns(bytes32) {
        requestId = blockhash(block.number);
        return requestId;
    }
}
