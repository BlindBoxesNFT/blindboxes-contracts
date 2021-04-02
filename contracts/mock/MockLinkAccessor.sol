// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "../interfaces/INFTMaster.sol";
import "../interfaces/ILinkAccessor.sol";

contract LinkAccessor is ILinkAccessor {

    INFTMaster public nftMaster;
    uint256 public randomness;

    constructor(
        INFTMaster nftMaster_
    ) public {
        nftMaster = nftMaster_;
    }

    function setRandomness(uint256 randomness_) external {
        randomness = randomness_;
    }

    function requestRandomness(uint256 userProvidedSeed_) public override returns(bytes32) {
        bytes32 requestId = blockhash(block.number);
        nftMaster.fulfillRandomness(requestId, randomness);
        return requestId;
    }
}
