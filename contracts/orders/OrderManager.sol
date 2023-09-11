// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPool, Side } from "../interfaces/IPool.sol";
import { SwapOrder, Order, UpdatePositionRequest, UpdatePositionType, OrderType } from "../interfaces/IOrderManager.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { IPool } from "../interfaces/IPool.sol";
import { IWETH } from "../interfaces/IWETH.sol";
import { IETHUnwrapper } from "../interfaces/IETHUnwrapper.sol";

// since we defined this function via a state variable of PoolStorage, it cannot be re-declared the interface IPool
interface IWhitelistedPool is IPool {
    function isListed(address) external returns (bool);

    function isAsset(address) external returns (bool);
}

contract OrderManager is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;

    uint256 constant MARKET_ORDER_TIMEOUT = 5 minutes;
    uint256 constant MAX_MIN_EXECUTION_FEE = 1e17; // 0.1 ETH
    address private constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    IWETH public weth;

    uint256 public nextOrderId;
    mapping(uint256 => Order) public orders;
    mapping(uint256 => UpdatePositionRequest) public requests;

    uint256 public nextSwapOrderId;
    mapping(uint256 => SwapOrder) public swapOrders;

    IWhitelistedPool public pool;
    IOracle public oracle;
    uint256 public minExecutionFee;

    mapping(address => uint256[]) public userOrders;
    mapping(address => uint256[]) public userSwapOrders;

    IETHUnwrapper public ethUnwrapper;

    mapping(address => bool) public executor;

    // address receive fee
    address public controller;

    modifier onlyExecutor() {
        _validateExecutor(msg.sender);
        _;
    }

    receive() external payable {
        // prevent send ETH directly to contract
        require(msg.sender == address(weth), "OrderManager:rejected");
    }

    function initialize(address _weth, address _oracle, uint256 _minExecutionFee, address _ethUnwrapper) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        require(_oracle != address(0), "OrderManager:invalidOracle");
        require(_weth != address(0), "OrderManager:invalidWeth");
        require(_minExecutionFee <= MAX_MIN_EXECUTION_FEE, "OrderManager:minExecutionFeeTooHigh");
        require(_ethUnwrapper != address(0), "OrderManager:invalidEthUnwrapper");
        minExecutionFee = _minExecutionFee;
        oracle = IOracle(_oracle);
        nextOrderId = 1;
        nextSwapOrderId = 1;
        weth = IWETH(_weth);
        ethUnwrapper = IETHUnwrapper(_ethUnwrapper);
    }

    // ============= VIEW FUNCTIONS ==============
    function getOrders(address user, uint256 skip, uint256 take) external view returns (uint256[] memory orderIds, uint256 total) {
        total = userOrders[user].length;
        uint256 toIdx = skip + take;
        toIdx = toIdx > total ? total : toIdx;
        uint256 nOrders = toIdx > skip ? toIdx - skip : 0;
        orderIds = new uint[](nOrders);
        for (uint256 i = skip; i < skip + nOrders; i++) {
            orderIds[i] = userOrders[user][i];
        }
    }

    function getSwapOrders(address user, uint256 skip, uint256 take) external view returns (uint256[] memory orderIds, uint256 total) {
        total = userSwapOrders[user].length;
        uint256 toIdx = skip + take;
        toIdx = toIdx > total ? total : toIdx;
        uint256 nOrders = toIdx > skip ? toIdx - skip : 0;
        orderIds = new uint[](nOrders);
        for (uint256 i = skip; i < skip + nOrders; i++) {
            orderIds[i] = userSwapOrders[user][i];
        }
    }

    // =========== MUTATIVE FUNCTIONS ==========
    function placeOrder(
        UpdatePositionType _updateType,
        Side _side,
        address _indexToken,
        address _collateralToken,
        OrderType _orderType,
        bytes calldata data
    ) external payable nonReentrant {
        if (_orderType == OrderType.MARKET) {
            _placeOrderMarket(_updateType, _side, _indexToken, _collateralToken, _orderType, data);
            return;
        }
        bool isIncrease = _updateType == UpdatePositionType.INCREASE;
        require(pool.validateToken(_indexToken, _collateralToken, _side, isIncrease), "OrderManager:invalidTokens");
        uint256 orderId;
        if (isIncrease) {
            orderId = _createIncreasePositionOrder(_side, _indexToken, _collateralToken, _orderType, data);
        } else {
            orderId = _createDecreasePositionOrder(_side, _indexToken, _collateralToken, _orderType, data);
        }
        userOrders[msg.sender].push(orderId);
    }

    function _placeOrderMarket(
        UpdatePositionType _updateType,
        Side _side,
        address _indexToken,
        address _collateralToken,
        OrderType _orderType,
        bytes calldata data
    ) internal {
        require(_orderType == OrderType.MARKET, "!MARKET");
        bool isIncrease = _updateType == UpdatePositionType.INCREASE;
        require(pool.validateToken(_indexToken, _collateralToken, _side, isIncrease), "OrderManager:invalidTokens");

        uint256 orderId;
        if (isIncrease) {
            orderId = _createIncreasePositionOrder(_side, _indexToken, _collateralToken, _orderType, data);
        } else {
            orderId = _createDecreasePositionOrder(_side, _indexToken, _collateralToken, _orderType, data);
        }
        userOrders[msg.sender].push(orderId);
        UpdatePositionRequest memory request = requests[orderId];
        Order memory order = orders[orderId];
        uint256 indexPrice = _getMarkPrice(order, request);

        order.price = indexPrice;

        _executeRequest(order, request);
        delete orders[orderId];
        delete requests[orderId];
        _safeTransferETH(controller, order.executionFee);
        emit OrderExecuted(orderId, order, request, indexPrice);
    }

    function placeSwapOrder(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minOut, uint256 _price) external payable nonReentrant {
        address payToken;
        (payToken, _tokenIn) = _tokenIn == ETH ? (ETH, address(weth)) : (_tokenIn, _tokenIn);
        // if token out is ETH, check wether pool support WETH
        require(pool.isListed(_tokenIn) && pool.isAsset(_tokenOut == ETH ? address(weth) : _tokenOut), "OrderManager:invalidTokens");

        uint256 executionFee;
        if (payToken == ETH) {
            executionFee = msg.value - _amountIn;
            weth.deposit{ value: _amountIn }();
        } else {
            executionFee = msg.value;
            IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
        }

        require(executionFee >= minExecutionFee, "OrderManager:executionFeeTooLow");

        SwapOrder memory order = SwapOrder({
            pool: pool,
            owner: msg.sender,
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            amountIn: _amountIn,
            minAmountOut: _minOut,
            price: _price,
            executionFee: executionFee
        });
        swapOrders[nextSwapOrderId] = order;
        userSwapOrders[msg.sender].push(nextSwapOrderId);
        emit SwapOrderPlaced(msg.sender, nextSwapOrderId, _tokenIn, _tokenOut, _amountIn, _minOut, _price);
        nextSwapOrderId += 1;
    }

    function swap(address _fromToken, address _toToken, uint256 _amountIn, uint256 _minAmountOut) external payable {
        _amountIn = _fromToken == ETH ? msg.value : _amountIn;
        (address outToken, address receiver) = _toToken == ETH ? (address(weth), address(this)) : (_toToken, msg.sender);
        uint256 amountOut = _poolSwap(_fromToken, outToken, _amountIn, _minAmountOut, receiver, msg.sender);
        if (outToken == address(weth) && _toToken == ETH) {
            _safeUnwrapETH(amountOut, msg.sender);
        }
        emit Swap(msg.sender, _fromToken, _toToken, address(pool), _amountIn, amountOut);
    }

    function executeOrder(uint256 _orderId, address payable _feeTo) external nonReentrant onlyExecutor {
        Order memory order = orders[_orderId];
        require(order.owner != address(0), "OrderManager:orderNotExists");
        require(order.pool == pool, "OrderManager:invalidOrPausedPool");
        require(block.number > order.submissionBlock, "OrderManager:blockNotPass");

        if (order.expiresAt != 0 && order.expiresAt < block.timestamp) {
            _expiresOrder(_orderId, order);
            return;
        }

        UpdatePositionRequest memory request = requests[_orderId];
        uint256 indexPrice = _getMarkPrice(order, request);
        bool isValid = order.triggerAboveThreshold ? indexPrice >= order.price : indexPrice <= order.price;

        if (!isValid) {
            return;
        }

        _executeRequest(order, request);
        delete orders[_orderId];
        delete requests[_orderId];
        _safeTransferETH(_feeTo, order.executionFee);
        emit OrderExecuted(_orderId, order, request, indexPrice);
    }

    function getMarkPrice(uint256 id) public view returns (uint256) {
        Order memory order = orders[id];
        UpdatePositionRequest memory request = requests[id];
        bool max = (request.updateType == UpdatePositionType.INCREASE) == (request.side == Side.LONG);
        return oracle.getPrice(order.indexToken, max);
    }

    function cancelOrder(uint256 _orderId) external nonReentrant {
        Order memory order = orders[_orderId];
        require(order.owner == msg.sender, "OrderManager:unauthorizedCancellation");
        UpdatePositionRequest memory request = requests[_orderId];

        delete orders[_orderId];
        delete requests[_orderId];

        _safeTransferETH(order.owner, order.executionFee);
        if (request.updateType == UpdatePositionType.INCREASE) {
            _refundCollateral(order.collateralToken, request.collateral, order.owner);
        }

        emit OrderCancelled(_orderId);
    }

    function cancelSwapOrder(uint256 _orderId) external nonReentrant {
        SwapOrder memory order = swapOrders[_orderId];
        require(order.owner == msg.sender, "OrderManager:unauthorizedCancellation");
        delete swapOrders[_orderId];
        _safeTransferETH(order.owner, order.executionFee);
        IERC20(order.tokenIn).safeTransfer(order.owner, order.amountIn);
        emit SwapOrderCancelled(_orderId);
    }

    function executeSwapOrder(uint256 _orderId, address payable _feeTo) external nonReentrant onlyExecutor {
        SwapOrder memory order = swapOrders[_orderId];
        require(order.owner != address(0), "OrderManager:notFound");
        delete swapOrders[_orderId];
        IERC20(order.tokenIn).safeTransfer(address(order.pool), order.amountIn);
        uint256 amountOut;
        if (order.tokenOut != ETH) {
            amountOut = _doSwap(order.tokenIn, order.tokenOut, order.minAmountOut, order.owner, order.owner);
        } else {
            amountOut = _doSwap(order.tokenIn, address(weth), order.minAmountOut, address(this), order.owner);
            _safeUnwrapETH(amountOut, order.owner);
        }
        _safeTransferETH(_feeTo, order.executionFee);
        require(amountOut >= order.minAmountOut, "OrderManager:slippageReached");
        emit SwapOrderExecuted(_orderId, order.amountIn, amountOut);
    }

    function _executeRequest(Order memory _order, UpdatePositionRequest memory _request) internal {
        if (_request.updateType == UpdatePositionType.INCREASE) {
            IERC20(_order.collateralToken).safeTransfer(address(_order.pool), _request.collateral);
            _order.pool.increasePosition(_order.owner, _order.indexToken, _order.collateralToken, _request.sizeChange, _request.side);
        } else {
            IERC20 collateralToken = IERC20(_order.collateralToken);
            uint256 priorBalance = collateralToken.balanceOf(address(this));
            _order.pool.decreasePosition(
                _order.owner,
                _order.indexToken,
                _order.collateralToken,
                _request.collateral,
                _request.sizeChange,
                _request.side,
                address(this)
            );
            uint256 payoutAmount = collateralToken.balanceOf(address(this)) - priorBalance;
            if (_order.collateralToken == address(weth) && _order.payToken == ETH) {
                _safeUnwrapETH(payoutAmount, _order.owner);
            } else if (_order.collateralToken != _order.payToken) {
                IERC20(_order.payToken).safeTransfer(address(_order.pool), payoutAmount);
                _order.pool.swap(_order.collateralToken, _order.payToken, 0, _order.owner, abi.encode(_order.owner));
            } else {
                collateralToken.safeTransfer(_order.owner, payoutAmount);
            }
        }
    }

    // ========= INTERNAL FUCNTIONS ==========

    function _getMarkPrice(Order memory order, UpdatePositionRequest memory request) internal view returns (uint256) {
        bool max = (request.updateType == UpdatePositionType.INCREASE) == (request.side == Side.LONG);
        return oracle.getPrice(order.indexToken, max);
    }

    function _createDecreasePositionOrder(
        Side _side,
        address _indexToken,
        address _collateralToken,
        OrderType _orderType,
        bytes memory _data
    ) internal returns (uint256 orderId) {
        Order memory order;
        UpdatePositionRequest memory request;
        bytes memory extradata;

        if (_orderType == OrderType.MARKET) {
            (order.price, order.payToken, request.sizeChange, request.collateral, extradata) = abi.decode(_data, (uint256, address, uint256, uint256, bytes));
            order.triggerAboveThreshold = _side == Side.LONG;
        } else {
            (order.price, order.triggerAboveThreshold, order.payToken, request.sizeChange, request.collateral, extradata) = abi.decode(
                _data,
                (uint256, bool, address, uint256, uint256, bytes)
            );
        }
        order.pool = pool;
        order.owner = msg.sender;
        order.indexToken = _indexToken;
        order.collateralToken = _collateralToken;
        order.expiresAt = _orderType == OrderType.MARKET ? block.timestamp + MARKET_ORDER_TIMEOUT : 0;
        order.submissionBlock = block.number;
        order.executionFee = msg.value;
        require(order.executionFee >= minExecutionFee, "OrderManager:executionFeeTooLow");

        request.updateType = UpdatePositionType.DECREASE;
        request.side = _side;
        orderId = nextOrderId;
        nextOrderId = orderId + 1;
        orders[orderId] = order;
        requests[orderId] = request;

        emit OrderPlaced(orderId, order, request);
    }

    function _createIncreasePositionOrder(
        Side _side,
        address _indexToken,
        address _collateralToken,
        OrderType _orderType,
        bytes memory _data
    ) internal returns (uint256 orderId) {
        Order memory order;
        UpdatePositionRequest memory request;
        order.triggerAboveThreshold = _side == Side.SHORT;
        address purchaseToken;
        uint256 purchaseAmount;
        bytes memory extradata;
        (order.price, purchaseToken, purchaseAmount, request.sizeChange, request.collateral, extradata) = abi.decode(
            _data,
            (uint256, address, uint256, uint256, uint256, bytes)
        );

        require(purchaseAmount != 0, "OrderManager:invalidPurchaseAmount");
        require(purchaseToken != address(0), "OrderManager:invalidPurchaseToken");

        order.pool = pool;
        order.owner = msg.sender;
        order.indexToken = _indexToken;
        order.collateralToken = _collateralToken;
        order.expiresAt = _orderType == OrderType.MARKET ? block.timestamp + MARKET_ORDER_TIMEOUT : 0;
        order.submissionBlock = block.number;
        order.executionFee = purchaseToken == ETH ? msg.value - purchaseAmount : msg.value;
        require(order.executionFee >= minExecutionFee, "OrderManager:executionFeeTooLow");
        request.updateType = UpdatePositionType.INCREASE;
        request.side = _side;
        orderId = nextOrderId;
        nextOrderId = orderId + 1;
        orders[orderId] = order;
        requests[orderId] = request;

        // swap or wrap if needed
        if (purchaseToken == ETH && _collateralToken == address(weth)) {
            require(purchaseAmount == request.collateral, "OrderManager:invalidPurchaseAmount");
            weth.deposit{ value: purchaseAmount }();
        } else if (purchaseToken != _collateralToken) {
            // update request collateral value to the actual swap output
            requests[orderId].collateral = _poolSwap(purchaseToken, _collateralToken, purchaseAmount, request.collateral, address(this), order.owner);
        } else if (purchaseToken != ETH) {
            IERC20(purchaseToken).safeTransferFrom(msg.sender, address(this), request.collateral);
        }

        emit OrderPlaced(orderId, order, request);
    }

    function _poolSwap(
        address _fromToken,
        address _toToken,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _receiver,
        address _beneficier
    ) internal returns (uint256 amountOut) {
        address payToken;
        (payToken, _fromToken) = _fromToken == ETH ? (ETH, address(weth)) : (_fromToken, _fromToken);
        if (payToken == ETH) {
            weth.deposit{ value: _amountIn }();
            weth.safeTransfer(address(pool), _amountIn);
        } else {
            IERC20(_fromToken).safeTransferFrom(msg.sender, address(pool), _amountIn);
        }
        return _doSwap(_fromToken, _toToken, _minAmountOut, _receiver, _beneficier);
    }

    function _doSwap(address _fromToken, address _toToken, uint256 _minAmountOut, address _receiver, address _beneficier) internal returns (uint256 amountOut) {
        IERC20 tokenOut = IERC20(_toToken);
        uint256 priorBalance = tokenOut.balanceOf(_receiver);
        pool.swap(_fromToken, _toToken, _minAmountOut, _receiver, abi.encode(_beneficier));
        amountOut = tokenOut.balanceOf(_receiver) - priorBalance;
    }

    function _expiresOrder(uint256 _orderId, Order memory _order) internal {
        UpdatePositionRequest memory request = requests[_orderId];
        delete orders[_orderId];
        delete requests[_orderId];
        emit OrderExpired(_orderId);

        _safeTransferETH(_order.owner, _order.executionFee);
        if (request.updateType == UpdatePositionType.INCREASE) {
            _refundCollateral(_order.collateralToken, request.collateral, _order.owner);
        }
    }

    function _refundCollateral(address _collateralToken, uint256 _amount, address _orderOwner) internal {
        if (_collateralToken == address(weth)) {
            _safeUnwrapETH(_amount, _orderOwner);
        } else {
            IERC20(_collateralToken).safeTransfer(_orderOwner, _amount);
        }
    }

    function _safeTransferETH(address _to, uint256 _amount) internal {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = _to.call{ value: _amount }(new bytes(0));
        require(success, "TransferHelper: ETH_TRANSFER_FAILED");
    }

    function _safeUnwrapETH(uint256 _amount, address _to) internal {
        weth.safeIncreaseAllowance(address(ethUnwrapper), _amount);
        ethUnwrapper.unwrap(_amount, _to);
    }

    function _validateExecutor(address _sender) internal view {
        require(executor[_sender], "OrderManager:onlyExecutor");
    }

    // ============ Administrative =============

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "OrderManager:invalidOracleAddress");
        oracle = IOracle(_oracle);
        emit OracleChanged(_oracle);
    }

    function setWeth(address _weth) external onlyOwner {
        weth = IWETH(_weth);
    }

    function setPool(address _pool) external onlyOwner {
        require(_pool != address(0), "OrderManager:invalidPoolAddress");
        require(address(pool) != _pool, "OrderManager:poolAlreadyAdded");
        pool = IWhitelistedPool(_pool);
        emit PoolSet(_pool);
    }

    function setMinExecutionFee(uint256 _fee) external onlyOwner {
        require(_fee != 0, "OrderManager:invalidFeeValue");
        require(_fee <= MAX_MIN_EXECUTION_FEE, "OrderManager:minExecutionFeeTooHigh");
        minExecutionFee = _fee;
        emit MinExecutionFeeSet(_fee);
    }

    function setExecutor(address _executor, bool _status) external onlyOwner {
        require(_executor != address(0), "OrderManager:invalidAddress");
        executor[_executor] = _status;
        emit ExecutorSet(_executor);
    }

    function setController(address _controller) external onlyOwner {
        require(_controller != address(0), "OrderManager:invalidAddress");
        controller = _controller;
        emit ControllerSet(_controller);
    }

    // ========== EVENTS =========

    event OrderPlaced(uint256 indexed key, Order order, UpdatePositionRequest request);
    event OrderCancelled(uint256 indexed key);
    event OrderExecuted(uint256 indexed key, Order order, UpdatePositionRequest request, uint256 fillPrice);
    event OrderExpired(uint256 indexed key);
    event OracleChanged(address);
    event SwapOrderPlaced(address owner, uint256 key, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 price);
    event SwapOrderCancelled(uint256 indexed key);
    event SwapOrderExecuted(uint256 indexed key, uint256 amountIn, uint256 amountOut);
    event Swap(address indexed account, address indexed tokenIn, address indexed tokenOut, address pool, uint256 amountIn, uint256 amountOut);
    event PoolSet(address indexed pool);
    event MinExecutionFeeSet(uint256 fee);
    event OrderHookSet(address indexed hook);
    event ExecutorSet(address indexed executor);
    event ControllerSet(address);
}
