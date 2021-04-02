// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@chainlink/contracts/src/v0.6/VRFConsumerBase.sol";

import "./interfaces/INFTMaster.sol";
import "./interfaces/ILinkAccessor.sol";

contract LinkAccessor is Context, VRFConsumerBase, ILinkAccessor {

    uint256 constant FEE = 10 ** 17;  // 0.1 LINK

    bytes32 public linkKeyHash;

    address public link;
    INFTMaster public nftMaster;

    constructor(
        address vrfCoordinator_,
        address link_,
        bytes32 linkKeyHash_,
        INFTMaster nftMaster_
    ) VRFConsumerBase(vrfCoordinator_, link_) public {
        link = link_;
        linkKeyHash = linkKeyHash_;
        nftMaster = nftMaster_;
    }

    function requestRandomness(uint256 userProvidedSeed_) public override returns(bytes32) {
        require(_msgSender() == address(nftMaster), "Not the right caller");
        require(IERC20(link).balanceOf(address(this)) >= FEE, "Not enough LINK");

        bytes32 requestId = requestRandomness(linkKeyHash, FEE, userProvidedSeed_);
        return requestId;
    }

    /**
     * Callback function used by VRF Coordinator
     */
    function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override {
        nftMaster.fulfillRandomness(requestId, randomness);
    }
}
