// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.17;

import { IPool } from "./IPool.sol";
import { IOracle } from "./IOracle.sol";
import { AssetInfo, Position, PoolTokenInfo } from "../pool/PoolStorage.sol";

interface IPoolWithStorage is IPool {
    function oracle() external view returns (IOracle);

    function trancheAssets(address tranche, address token) external view returns (AssetInfo memory);

    function allTranches(uint256 index) external view returns (address);

    function calcSwapOutput(address _tokenIn, address _tokenOut, uint256 _amountIn) external view returns (uint256 amountOut, uint256 feeAmount);

    function positions(bytes32 positionKey) external view returns (Position memory);

    function isStableCoin(address token) external view returns (bool);

    function poolBalances(address token) external view returns (uint256);

    function feeReserves(address token) external view returns (uint256);

    function borrowIndices(address token) external view returns (uint256);

    function lastAccrualTimestamps(address token) external view returns (uint256);

    function daoFee() external view returns (uint256);

    function riskFactor(address token, address tranche) external view returns (uint256);

    function targetWeights(address token) external view returns (uint256);

    function totalWeight() external view returns (uint256);

    function virtualPoolValue() external view returns (uint256);

    function isTranche(address tranche) external view returns (bool);

    function positionRevisions(bytes32 key) external view returns (uint256 rev);

    function maintenanceMargin() external view returns (uint256);

    function maxLeverage() external view returns (uint256);

    function getPoolAsset(address _token) external view returns (AssetInfo memory);

    function poolTokens(address _token) external view returns (PoolTokenInfo memory);

    function getAllTranchesLength() external view returns (uint256);

    function averageShortPrices(address _tranche, address _token) external view returns (uint256);

    function fee()
        external
        view
        returns (
            uint256 positionFee,
            uint256 liquidationFee,
            uint256 baseSwapFee,
            uint256 taxBasisPoint,
            uint256 stableCoinBaseSwapFee,
            uint256 stableCoinTaxBasisPoint,
            uint256 daoFee
        );
}
