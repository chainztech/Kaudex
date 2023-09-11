// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.17;

import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LPToken is ERC20Burnable {
    address public immutable minter;

    constructor(
        string memory _name,
        string memory _symbol,
        address _minter
    ) ERC20(_name, _symbol) {
        require(_minter != address(0), "LPToken: address 0");
        minter = _minter;
    }

    function mint(address _to, uint256 _amount) external {
        require(msg.sender == minter, "LPToken: !minter");
        _mint(_to, _amount);
    }
}
