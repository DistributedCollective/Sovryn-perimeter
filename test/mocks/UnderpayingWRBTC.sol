// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract UnderpayingWRBTC is ERC20 {
    bool public underpay;

    constructor() ERC20("Wrapped native", "WRBTC") {}

    function setUnderpay(bool enabled) external {
        underpay = enabled;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(underpay ? amount - 1 : amount);
    }
}
