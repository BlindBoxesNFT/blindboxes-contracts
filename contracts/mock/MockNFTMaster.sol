// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "../NFTMaster.sol";

contract MockNFTMaster is NFTMaster {

    constructor() public {
    }

    function buyLink(uint256 times_, address[] calldata path, uint256 amountInMax_, uint256 deadline_) internal override {
    }
}
