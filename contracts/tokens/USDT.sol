// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.17;

import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract USDT is ERC20Burnable {
    uint256 public constant MAX_SUPPLY = 50_000_000 * 10 ** 6;

    constructor() ERC20("USDT Token", "USDT") {
        _mint(_msgSender(), MAX_SUPPLY);
    }

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}
