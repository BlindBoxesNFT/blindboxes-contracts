pragma solidity >=0.6.0 <0.7.0;

interface INFTHolder {
    function withdraw(address to_, address tokenAddress_, uint256 tokenId_) external;
}
