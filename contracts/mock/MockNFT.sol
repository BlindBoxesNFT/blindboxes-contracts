// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockNFT is ERC721 {

    constructor (string memory name_, string memory symbol_) ERC721(name_, symbol_) public {}

    function mint(address to, uint256 tokenId) public {
        _mint(to, tokenId);
    }
}
