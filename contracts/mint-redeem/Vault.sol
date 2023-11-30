// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.17;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { IOrderManagerWithStorage, UpdatePositionType, OrderType, Side } from "../interfaces/IOrderManagerWithStorage.sol";
import { IPoolWithStorage, Position, AssetInfo, PoolTokenInfo } from "../interfaces/IPoolWithStorage.sol";
import { PositionUtils } from "../lib/PositionUtils.sol";
import { SafeCast } from "../lib/SafeCast.sol";
import { MathUtils } from "../lib/MathUtils.sol";
import { SignedInt, SignedIntOps } from "../lib/SignedInt.sol";

struct PositionView {
    address owner;
    bytes32 key;
    Side side;
    bool hasProfit;
    uint256 size;
    uint256 collateralValue;
    uint256 entryPrice;
    uint256 pnl;
    uint256 reserveAmount;
    uint256 borrowIndex;
    uint256 liquidatePrice;
    uint256 borrowFee;
    uint256 positionFee;
}

struct PoolAsset {
    uint256 poolAmount;
    uint256 reservedAmount;
    uint256 feeReserve;
    uint256 guaranteedValue;
    uint256 totalShortSize;
    uint256 averageShortPrice;
    uint256 poolBalance;
    uint256 lastAccrualTimestamp;
    uint256 borrowIndex;
}

interface IXAU is IERC20 {
    function mint(address _to, uint256 _amount) external;

    function burn(uint256 amount) external;
}

contract Vault is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SignedIntOps for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    uint256 public constant PRECISION = 1e10;
    IXAU public xau;
    ERC20 public usdt;
    IOracle public oracle;
    uint256 public mint_fee;
    uint256 public redeem_fee;
    uint256 public init_usdt_value;

    address public feeCollector;
    uint256 public longPercent;

    uint256 public reserve;
    uint256 public longSize;
    uint256 public leverage;

    IOrderManagerWithStorage public orderManager;
    IPoolWithStorage public pool;

    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        _pause();

        init_usdt_value = 500000 * 10 ** 6;
        longPercent = PRECISION / 10;
        leverage = 10;
        feeCollector = msg.sender;
    }

    function init() external {
        require(xau.totalSupply() == 0, "Supply");
        (uint256 xauAmount, uint256 feeAmount) = calMintAmount(init_usdt_value);
        usdt.transferFrom(_msgSender(), address(this), init_usdt_value);
        xau.mint(_msgSender(), xauAmount);
        usdt.transfer(feeCollector, feeAmount);
    }

    function mint(address _to, uint256 _amount) external payable whenNotPaused nonReentrant {
        require(_to != address(0), "Zero Address");
        require(_amount > 0, "Amount = 0");
        require(msg.value >= orderManager.minExecutionFee(), "minExecutionFee");

        (uint256 xauAmount, uint256 feeAmount) = calMintAmount(_amount);

        if (xauAmount == 0) return;

        usdt.transferFrom(_msgSender(), address(this), _amount);

        uint256 size = ((_amount - feeAmount) * longPercent) / PRECISION;
        reserve += _amount - feeAmount - size;
        increaseLongPosition(size);
        xau.mint(_msgSender(), xauAmount);
        usdt.transfer(feeCollector, feeAmount);
    }

    function redeem(address _to, uint256 _amount) external payable whenNotPaused nonReentrant {
        require(_to != address(0), "Zero Address");
        require(_amount > 0, "Amount = 0");

        (uint256 usdtAmount, uint256 feeAmount) = calRedeemAmount(_amount);

        if (usdtAmount == 0) return;

        xau.transferFrom(_msgSender(), address(this), _amount);

        // closeLongXau
        uint256 size = (usdtAmount * longPercent) / PRECISION;
        reserve -= usdtAmount - size;
        decreaseLongPosition(size);
        xau.burn(_amount - feeAmount);
        xau.transfer(feeCollector, feeAmount);
        usdt.transfer(_to, usdtAmount);
    }

    function increaseLongPosition(uint256 _amount) internal {
        UpdatePositionType updateType = UpdatePositionType.INCREASE;
        Side side = Side.LONG;
        address indexToken = address(xau);
        address collateralToken = address(xau);
        OrderType orderType = OrderType.MARKET;

        uint256 order_price = getXauPrice();
        address order_payToken = address(usdt);
        uint256 purchaseAmount = _amount;

        (uint256 amountOut, ) = pool.calcSwapOutput(order_payToken, collateralToken, purchaseAmount);

        uint256 sizeChange = order_price * amountOut * leverage;

        bytes memory callData = abi.encode(order_price, order_payToken, purchaseAmount, sizeChange, amountOut, "");

        usdt.approve(address(orderManager), purchaseAmount);

        orderManager.placeOrder{ value: orderManager.minExecutionFee() }(updateType, side, indexToken, collateralToken, orderType, callData);
    }

    function decreaseLongPosition(uint256 _amount) internal {
        UpdatePositionType updateType = UpdatePositionType.DECREASE;
        Side side = Side.LONG;
        address indexToken = address(xau);
        address collateralToken = address(xau);
        OrderType orderType = OrderType.MARKET;

        uint256 order_price = getXauPrice();
        address order_payToken = address(usdt);

        (uint256 amountOut, ) = pool.calcSwapOutput(order_payToken, collateralToken, _amount);

        uint256 sizeChange = order_price * amountOut * leverage;
        uint256 collateralChanged = order_price * amountOut;

        PositionView memory result = getCurrentPosition();
        (, uint256 _liquidationFee, , , , , ) = pool.fee();

        if (sizeChange + _liquidationFee > result.size) {
            sizeChange = result.size;
            collateralChanged = result.collateralValue;
        }

        bytes memory callData = abi.encode(order_price, collateralToken, sizeChange, collateralChanged, "");

        orderManager.placeOrder{ value: orderManager.minExecutionFee() }(updateType, side, indexToken, collateralToken, orderType, callData);
    }

    function calRedeemAmount(uint256 _amount) public view returns (uint256 usdtAmount, uint256 feeAmount) {
        uint256 xau_price = getXauPrice();
        uint256 usdt_price = getUsdtPrice();
        uint256 valueChange = xau_price * _amount;
        usdtAmount = (valueChange * (PRECISION - redeem_fee)) / usdt_price / PRECISION;
        feeAmount = (valueChange * redeem_fee) / xau_price / PRECISION;

        if (usdtAmount > usdt.balanceOf(address(this))) {
            usdtAmount = 0;
            feeAmount = 0;
        }
    }

    function calMintAmount(uint256 _amount) public view returns (uint256 xauAmount, uint256 feeAmount) {
        uint256 xau_price = getXauPrice();
        uint256 usdt_price = getUsdtPrice();
        uint256 valueChange = usdt_price * _amount;
        xauAmount = (valueChange * (PRECISION - mint_fee)) / xau_price / PRECISION;
        feeAmount = (valueChange * mint_fee) / usdt_price / PRECISION;

        uint256 available = availableLP(address(xau));

        if (xau.totalSupply() > 0 && (xauAmount * longPercent) / PRECISION > available) {
            xauAmount = 0;
            feeAmount = 0;
        }
    }

    function availableLP(address _token) public view returns (uint256) {
        return
            MathUtils.average(getAssetPoolAum(_token, true) / oracle.getPrice(_token, true), getAssetPoolAum(_token, false) / oracle.getPrice(_token, false));
    }

    function getAssetPoolAum(address _token, bool _max) public view returns (uint256) {
        bool isStable = pool.isStableCoin(_token);
        uint256 price = oracle.getPrice(_token, _max);
        uint256 nTranches = pool.getAllTranchesLength();

        int256 sum = 0;

        for (uint256 i = 0; i < nTranches; ) {
            address tranche = pool.allTranches(i);
            AssetInfo memory asset = pool.trancheAssets(tranche, _token);
            if (isStable) {
                sum = sum + (asset.poolAmount * price).toInt256();
            } else {
                uint256 averageShortPrice = pool.averageShortPrices(tranche, _token);
                int256 shortPnl = PositionUtils.calcPnl(Side.SHORT, asset.totalShortSize, averageShortPrice, price);
                sum = ((asset.poolAmount - asset.reservedAmount) * price + asset.guaranteedValue).toInt256() + sum - shortPnl;
            }
            unchecked {
                ++i;
            }
        }

        return sum.toUint256();
    }

    function getCurrentPosition() public view returns (PositionView memory result) {
        return getPosition(address(this), address(xau), address(xau), Side.LONG);
    }

    function getPosition(address _owner, address _indexToken, address _collateralToken, Side _side) internal view returns (PositionView memory result) {
        bytes32 positionKey = _getPositionKey(_owner, _indexToken, _collateralToken, _side);
        Position memory position = pool.positions(positionKey);

        if (position.size == 0) {
            return result;
        }

        uint256 indexPrice = _side == Side.LONG ? oracle.getPrice(_indexToken, false) : oracle.getPrice(_indexToken, true);
        int256 pnl = PositionUtils.calcPnl(_side, position.size, position.entryPrice, indexPrice);

        (uint256 _positionFee, uint256 _liquidationFee, , , , , ) = pool.fee();
        PoolTokenInfo memory tokenInfo = pool.poolTokens(_indexToken);
        uint256 borrowFee = ((tokenInfo.borrowIndex - position.borrowIndex) * position.size) / PRECISION;
        uint256 fee = borrowFee + _positionFee;
        int256 loseProfit1 = int256(fee) + int256(_liquidationFee) - int256(position.collateralValue);
        int256 loseProfit2 = int256((position.size * pool.maintenanceMargin()) / PRECISION) - int256(position.collateralValue);
        int256 loseProfit = loseProfit1 > loseProfit2 ? loseProfit1 : loseProfit2;
        uint256 liquidatePrice = 0;
        if (_side == Side.LONG) {
            liquidatePrice = uint256((loseProfit * int256(position.entryPrice)) / int256(position.size) + int256(position.entryPrice));
        } else {
            liquidatePrice = uint256(int256(position.entryPrice) - (loseProfit * int256(position.entryPrice)) / int256(position.size));
        }

        uint256 positionFee = (position.size * _positionFee) / PRECISION;
        result.key = positionKey;
        result.side = _side;
        result.size = position.size;
        result.collateralValue = position.collateralValue;
        result.pnl = uint256(pnl);
        result.hasProfit = pnl > 0;
        result.entryPrice = position.entryPrice;
        result.borrowIndex = position.borrowIndex;
        result.reserveAmount = position.reserveAmount;
        result.liquidatePrice = liquidatePrice;
        result.borrowFee = borrowFee;
        result.positionFee = positionFee;
    }

    function _getPositionKey(address _owner, address _indexToken, address _collateralToken, Side _side) internal pure returns (bytes32) {
        return keccak256(abi.encode(_owner, _indexToken, _collateralToken, _side));
    }

    function getXauPrice() public view returns (uint256) {
        return oracle.getPrice(address(xau), false);
    }

    function getUsdtPrice() public view returns (uint256) {
        return oracle.getPrice(address(usdt), false);
    }

    function setXau(address _xau) external onlyOwner {
        require(_xau != address(0), "Zero Address");
        xau = IXAU(_xau);
        emit SetXau(_xau);
    }

    function setUsdt(address _usdt) external onlyOwner {
        require(_usdt != address(0), "Zero Address");
        usdt = ERC20Burnable(_usdt);
        emit SetUsdt(_usdt);
    }

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Zero Address");
        oracle = IOracle(_oracle);
        emit SetOracle(_oracle);
    }

    function setOrderManager(address _orderManager) external onlyOwner {
        require(_orderManager != address(0), "Zero Address");
        orderManager = IOrderManagerWithStorage(_orderManager);
    }

    function setPool(address _pool) external onlyOwner {
        require(_pool != address(0), "Zero Address");
        pool = IPoolWithStorage(_pool);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    event SetXau(address xau);
    event SetUsdt(address usdt);
    event SetOracle(address oracle);
}
