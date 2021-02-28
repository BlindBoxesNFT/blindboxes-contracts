pragma solidity >=0.6.0 <0.7.0;

interface INFTMaster {
    function deposit(address from_, address tokenAddress_, uint256 tokenId_) external;
}
