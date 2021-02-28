// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

// For details, check
// https://www.xdaichain.com/for-developers/on-chain-random-numbers/accessing-a-random-seed-with-a-smart-contract
interface IPOSDAORandom {
    function collectRoundLength() external view returns(uint256);
    function currentSeed() external view returns(uint256);
}
