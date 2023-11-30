// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IPriceFeed {
    function postPrices(
        address[] calldata tokens,
        uint256[] calldata prices
    ) external;
}
