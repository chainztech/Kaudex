// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Faucet is Ownable {
    using SafeERC20 for IERC20;
    uint256 public exTime;
    mapping(address => uint256) public amount;
    mapping(address => mapping(address => uint256)) public lastFaucet;

    constructor() {
        exTime = 1 hours;
    }

    function setExTime(uint256 _time) public onlyOwner {
        exTime = _time;
    }

    function setToken(address[] memory _tokens, uint256[] memory _amount) public onlyOwner {
        require(_tokens.length == _amount.length, "length!");
        for (uint256 i = 0; i < _tokens.length; i++) {
            amount[_tokens[i]] = _amount[i];
        }
    }

    function claim(address _token) external {
        require(lastFaucet[msg.sender][_token] + exTime < block.timestamp, "wait");

        IERC20(_token).transfer(msg.sender, amount[_token]);

        lastFaucet[msg.sender][_token] = block.timestamp;
    }

    function withdraw(address _token) public onlyOwner {
        IERC20(_token).transfer(msg.sender, amount[_token]);
    }
}
