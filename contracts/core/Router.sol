// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "../libraries/SafeMath.sol";
import "../libraries/MarketDataStructure.sol";
import "../libraries/TransferHelper.sol";
import "../libraries/SafeCast.sol";
import "../libraries/SignedSafeMath.sol";
import "../libraries/ReentrancyGuard.sol";
import "../interfaces/IManager.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IWrappedCoin.sol";
import "../interfaces/IMarket.sol";
import "../interfaces/IPool.sol";
import "../interfaces/IFundingLogic.sol";
import "../interfaces/IInviteManager.sol";
import "../interfaces/IMarketLogic.sol";
import "../interfaces/IRewardRouter.sol";
import "../interfaces/IOrder.sol";

contract Router is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeMath for uint32;
    using SignedSafeMath for int256;
    using SafeCast for int256;
    using SafeCast for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    address public manager;
    address inviteManager;
    address marketLogic;
    address poolOrder;

    //taker => market => orderId[]
    mapping(address => mapping(address => EnumerableSet.UintSet)) internal notExecuteOrderIds; // not executed order ids
    address public WETH;


    event OrderCreated(address market, uint256 id);
    event Cancel(address market, uint256 id);
    event SetStopProfitAndLossPrice(uint256 id, address market, uint256 _profitPrice, uint256 _stopLossPrice, bool _isExecutedByIndexPrice);
    event SetParams(address _inviteManager, address _marketLogic, address _order);
    event SetMakerTPSLPrice(address pool, uint256 positionId, uint256 profitPrice, uint256 stopLossPrice);

    constructor(address _manager, address _WETH) {
        manager = _manager;
        WETH = _WETH;
    }

    modifier whenNotPaused() {
        require(!IManager(manager).paused(), "RWN0");
        _;
    }

    modifier onlyController() {
        require(IManager(manager).checkController(msg.sender), "ROC0");
        _;
    }

    modifier onlyTreasurer() {
        require(IManager(manager).checkTreasurer(msg.sender), "ROT0");
        _;
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, 'RE0');
        _;
    }

    modifier validateMarket(address _market){
        require(IManager(manager).checkMarket(_market), "RVM0");
        _;
    }

    modifier validatePool(address _pool){
        require(IManager(manager).checkPool(_pool), "RVP0");
        _;
    }

    /// @notice set params, only controller can call
    /// @param _inviteManager invite manager contract address
    /// @param _marketLogic market logic contract address
    /// @param _order order address
    function setConfigParams(address _inviteManager, address _marketLogic, address _order) external onlyController {
        require(_inviteManager != address(0) && _marketLogic != address(0) && _order != address(0), "RSC0");
        inviteManager = _inviteManager;
        marketLogic = _marketLogic;
        poolOrder = _order;
        emit SetParams(_inviteManager, _marketLogic, _order);
    }

    /// @notice user open position parameters
    struct TakerOpenParams {
        address _market;            // market contract address
        bytes32 inviterCode;        // inviter code
        uint128 minPrice;           // min price for the slippage
        uint128 maxPrice;           // max price for the slippage
        uint256 margin;             // margin of this order
        uint16 leverage;
        int8 direction;             // order direction, 1: long, -1: short
        int8 triggerDirection;      // trigger flag {1: index price >= trigger price, -1: index price <= trigger price}
        uint256 triggerPrice;
        bool isExecutedByIndexPrice;
        uint256 deadline;
    }

    /// @notice user close position parameters
    struct TakerCloseParams {
        address _market;            // market contract address
        uint256 id;                 // position id
        bytes32 inviterCode;        // inviter code
        uint128 minPrice;           // min price for the slippage
        uint128 maxPrice;           // max price for the slippage
        uint256 amount;             // position amount to close
        int8 triggerDirection;      // trigger flag {1: index price >= trigger price, -1: index price <= trigger price}
        uint256 triggerPrice;
        bool isExecutedByIndexPrice;
        uint256 deadline;
    }

    /// @notice place an open-position order, margined by both erc20 and eth
    /// @param params order params, detailed in the data structure declaration
    /// @return id order id
    function takerOpen(TakerOpenParams memory params) external payable ensure(params.deadline) validateMarket(params._market) whenNotPaused nonReentrant returns (uint256 id) {
        require(params.minPrice <= params.maxPrice, "RTOP0");

        setReferralCode(params.inviterCode);

        address marginAsset = getMarketMarginAsset(params._market);
        uint256 fee = getExecuteOrderFee();
        bool isETH = marginAsset == WETH && msg.value > fee;
        if (isETH) {
            params.margin = msg.value.sub(fee);
        } else {
            require(msg.value == fee, "RTOE2");
        }
        require(params.margin > 0, "RTOE1");

        _transfer(marginAsset, params._market, params.margin, isETH);

        id = IMarket(params._market).createOrder(MarketDataStructure.CreateInternalParams({
            _taker: msg.sender,
            id: 0,
            minPrice: params.minPrice,
            maxPrice: params.maxPrice,
            margin: params.margin,
            amount: 0,
            leverage: params.leverage,
            direction: params.direction,
            triggerDirection: params.triggerDirection,
            triggerPrice: params.triggerPrice,
            useIP: params.isExecutedByIndexPrice,
            reduceOnly: 0,
            isLiquidate: false,
            isETH: isETH
        }));

        EnumerableSet.add(notExecuteOrderIds[msg.sender][params._market], id);
        emit OrderCreated(params._market, id);
    }

    /// @notice place a close-position order
    /// @param params order parameters, detailed in the data structure declaration
    /// @return id order id
    function takerClose(TakerCloseParams memory params) external payable ensure(params.deadline) validateMarket(params._market) whenNotPaused nonReentrant returns (uint256 id){
        require(params.minPrice <= params.maxPrice, "RTCL0");
        uint256 executeOrderFee = getExecuteOrderFee();
        require(msg.value == executeOrderFee, "RTCL1");

        setReferralCode(params.inviterCode);

        id = IMarket(params._market).createOrder(MarketDataStructure.CreateInternalParams({
            _taker: msg.sender,
            id: params.id,
            minPrice: params.minPrice,
            maxPrice: params.maxPrice,
            margin: 0,
            amount: params.amount,
            leverage: 0,
            direction: 0,
            triggerDirection: params.triggerDirection,
            triggerPrice: params.triggerPrice,
            useIP: params.isExecutedByIndexPrice,
            reduceOnly: 1,
            isLiquidate: false,
            isETH: false
        }));

        EnumerableSet.add(notExecuteOrderIds[msg.sender][params._market], id);
        emit OrderCreated(params._market, id);
    }

    /// @notice  add margin to a position, margined by ERC20 tokens
    /// @param _market  market contract address
    /// @param _id  position id
    /// @param _value  add margin value 
    function increaseMargin(address _market, uint256 _id, uint256 _value) external payable nonReentrant {
        address marginAsset = getMarketMarginAsset(_market);
        bool isETH = marginAsset == WETH && msg.value > 0;
        _value = isETH ? msg.value : _value;
        _transfer(marginAsset, IManager(manager).vault(), _value, isETH);
        _updateMargin(_market, _id, _value, true);
    }

    /// @notice  remove margin from a position
    /// @param _market  market contract address
    /// @param _id  position id
    /// @param _value  remove margin value
    function decreaseMargin(address _market, uint256 _id, uint256 _value) external nonReentrant {
        _updateMargin(_market, _id, _value, false);
    }

    function _updateMargin(address _market, uint256 _id, uint256 _deltaMargin, bool isIncrease) internal whenNotPaused {
        require(_deltaMargin != 0, "MUM0");
        MarketDataStructure.Position memory position = IMarket(_market).getPosition(_id);
        MarketDataStructure.MarketConfig memory marketConfig = IMarket(_market).getMarketConfig();
        require(position.taker == msg.sender && position.amount > 0, "MUM1");

        if (isIncrease) {
            position.takerMargin = position.takerMargin.add(_deltaMargin);
            require(position.takerMargin <= marketConfig.takerMarginMax && position.makerMargin >= position.takerMargin, 'MUM2');
        } else {
            //get max decrease margin amount
            (uint256 maxDecreaseMargin) = IMarketLogic(marketLogic).getMaxTakerDecreaseMargin(position);
            if (maxDecreaseMargin < _deltaMargin) _deltaMargin = maxDecreaseMargin;
        }

        IMarket(_market).updateMargin(_id, _deltaMargin, isIncrease);
    }

    /// @notice user or system cancel an order that open or failed
    /// @param _market market address
    /// @param id order id
    function orderCancel(address _market, uint256 id) external validateMarket(_market) nonReentrant {
        address marginAsset = getMarketMarginAsset(_market);
        MarketDataStructure.Order memory order = IMarket(_market).getOrder(id);
        require(order.taker == msg.sender && order.createTs.add(IManager(manager).cancelElapse()) <= block.timestamp, "MORC0");

        IMarket(_market).cancel(id);
        if (order.freezeMargin > 0) {
            if (!order.isETH) {
                TransferHelper.safeTransfer(marginAsset, order.taker, order.freezeMargin);
            } else {
                IWrappedCoin(marginAsset).withdraw(order.freezeMargin);
                TransferHelper.safeTransferETH(order.taker, order.freezeMargin);
            }
        }

        if (order.status == MarketDataStructure.OrderStatus.Open) TransferHelper.safeTransferETH(order.taker, order.executeFee);

        EnumerableSet.remove(notExecuteOrderIds[order.taker][_market], id);
        emit Cancel(_market, id);
    }

    /// @notice user set prices for take-profit and stop-loss
    /// @param _market  market contract address
    /// @param _id  position id
    /// @param _profitPrice take-profit price
    /// @param _stopLossPrice stop-loss price
    function setTPSLPrice(address _market, uint256 _id, uint256 _profitPrice, uint256 _stopLossPrice, bool _isExecutedByIndexPrice) external whenNotPaused {
        MarketDataStructure.Position memory position = IMarket(_market).getPosition(_id);
        require(position.taker == msg.sender && position.amount > 0, "MSTP0");
        IMarket(_market).setTPSLPrice(_id, _profitPrice, _stopLossPrice, _isExecutedByIndexPrice);
        emit SetStopProfitAndLossPrice(_id, _market, _profitPrice, _stopLossPrice, _isExecutedByIndexPrice);
    }

    /// @notice user modify position mode
    /// @param _market  market contract address
    /// @param _mode  position mode
    function switchPositionMode(address _market, MarketDataStructure.PositionMode _mode) external {
        IMarketLogic(IMarket(_market).marketLogic()).checkSwitchMode(_market, msg.sender, _mode);
        IMarket(_market).switchPositionMode(msg.sender, _mode);
    }

    /// @notice create pool order
    /// @param _params order params
    /// @param _deadline deadline
    function createPoolOrder(IOrder.CreateOrderParams memory _params, uint256 _deadline) external payable nonReentrant ensure(_deadline) validatePool(_params.pool) {
        uint256 fee = getExecuteOrderFee();
        _params.executeFee = fee;
        _params.maker = msg.sender;
        if (_params.orderType == IOrder.PoolOrderType.Increase) {
            address baseAsset = IPool(_params.pool).getBaseAsset();
            bool isETH = baseAsset == WETH && msg.value > fee;
            if (isETH) {
                _params.margin = msg.value.sub(fee);
            } else {
                require(msg.value == fee, "MCRP1");
            }
            _transfer(baseAsset, poolOrder, _params.margin, isETH);
        } else {
            require(msg.value == fee, "MCRP2");
        }

        IOrder(poolOrder).createOrder(_params);
    }

    /// @notice cancel pool order
    //// @param _orderId order id
    function cancelPoolOrder(uint256 _orderId) external nonReentrant {
        IOrder.PoolOrder memory order = IOrder(poolOrder).getPoolOrder(_orderId);
        require(
            order.maker == msg.sender
            && order.status == IOrder.PoolOrderStatus.Submit
            && order.createTs.add(uint32(IManager(manager).cancelElapse())) <= block.timestamp,
            "MCPO0"
        );
        TransferHelper.safeTransferETH(order.maker, order.executeFee);
        IOrder(poolOrder).updatePoolOrder(order.id, IOrder.PoolOrderStatus.Cancel);
    }

    /// @notice set the take-profit and stop-loss price for a maker position
    /// @param _pool pool address
    /// @param _positionId position id
    /// @param _profitPrice take-profit price
    /// @param _stopLossPrice stop-loss price
    function setMakerTPSLPrice(address _pool, uint256 _positionId, uint256 _profitPrice, uint256 _stopLossPrice) external {
        IPool(_pool).setTPSLPrice(msg.sender, _positionId, _profitPrice, _stopLossPrice);
        emit SetMakerTPSLPrice(_pool, _positionId, _profitPrice, _stopLossPrice);
    }

    /// @notice add margin to a maker position
    /// @param pool pool address
    /// @param positionId position id
    /// @param addMargin add margin value
    function addMakerPositionMargin(address pool, uint256 positionId, uint256 addMargin) external payable validatePool(pool) nonReentrant {
        address baseAsset = IPool(pool).getBaseAsset();
        bool isETH = baseAsset == WETH && msg.value > 0;
        addMargin = isETH ? msg.value : addMargin;
        _transfer(baseAsset, IManager(manager).vault(), addMargin, isETH);
        IPool(pool).addMakerPositionMargin(positionId, addMargin);
    }

    function _transfer(address asset, address to, uint256 amount, bool isETH) internal {
        if (isETH) {
            IWrappedCoin(WETH).deposit{value: amount}();
            TransferHelper.safeTransfer(WETH, to, amount);
        } else {
            TransferHelper.safeTransferFrom(asset, msg.sender, to, amount);
        }
    }

    /// @notice set the referral code for the trader
    /// @param inviterCode the inviter code
    function setReferralCode(bytes32 inviterCode) internal {
        IInviteManager(inviteManager).setTraderReferralCode(msg.sender, inviterCode);
    }

    /// @notice get the not execute order ids
    /// @param _market market address
    /// @param _taker taker address
    /// @return ids order ids
    function getNotExecuteOrderIds(address _market, address _taker) external view returns (uint256[] memory){
        uint256[] memory ids = new uint256[](EnumerableSet.length(notExecuteOrderIds[_taker][_market]));
        for (uint256 i = 0; i < EnumerableSet.length(notExecuteOrderIds[_taker][_market]); i++) {
            ids[i] = EnumerableSet.at(notExecuteOrderIds[_taker][_market], i);
        }
        return ids;
    }

    /// @notice get the margin asset of an market
    function getMarketMarginAsset(address _market) internal view returns (address){
        return IManager(manager).getMarketMarginAsset(_market);
    }

    /// @notice get the configured execution fee of an order
    function getExecuteOrderFee() internal view returns (uint256){
        return IManager(manager).executeOrderFee();
    }

    /// @notice transfer the execution fee to the update router by the treasurer
    function withdrawExecuteFee() external onlyTreasurer {
        TransferHelper.safeTransferETH(IManager(manager).router(), address(this).balance);
    }

    function executorTransfer(address to, uint256 amount) external {
        IManager(manager).checkExecutorRouter(msg.sender);

        TransferHelper.safeTransferETH(to, amount);
    }

    function removeNotExecuteOrderId(address taker, address market, uint256 orderId) external {
        IManager(manager).checkExecutorRouter(msg.sender);
        
        EnumerableSet.remove(notExecuteOrderIds[taker][market], orderId);
    }

    receive() external payable {
    }
}
