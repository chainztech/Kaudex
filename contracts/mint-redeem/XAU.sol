// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.17;

import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract XAU is ERC20Burnable {
    address public immutable minter;

    constructor(address _minter) ERC20("XAU", "XAU") {
        minter = _minter;
    }

    function mint(address _to, uint256 _amount) external {
        require(msg.sender == minter, "XAU: !minter");
        _mint(_to, _amount);
    }
}
