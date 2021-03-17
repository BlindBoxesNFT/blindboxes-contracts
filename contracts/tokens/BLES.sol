// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// This token is owned by Timelock.
contract BLES is ERC20("Blind Boxes Token", "BLES") {

    constructor() public {
        _mint(_msgSender(), 1e26);  // 100 million, 18 decimals
    }

    function burn(uint256 _amount) external {
        _burn(_msgSender(), _amount);
    }

    function burnFrom(address account, uint256 amount) external {
        uint256 currentAllowance = allowance(account, _msgSender());
        require(currentAllowance >= amount, "ERC20: burn amount exceeds allowance");
        _approve(account, _msgSender(), currentAllowance - amount);
        _burn(account, amount);
    }
}
