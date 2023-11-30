// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "./IOrderManager.sol";

import { IOracle } from "./IOracle.sol";

interface IOrderManagerWithStorage is IOrderManager {
    function oracle() external view returns (IOracle);

    function minExecutionFee() external view returns (uint256);

    function placeOrder(
        UpdatePositionType _updateType,
        Side _side,
        address _indexToken,
        address _collateralToken,
        OrderType _orderType,
        bytes calldata data
    ) external payable;
}
