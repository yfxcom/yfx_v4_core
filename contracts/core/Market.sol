// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import "../libraries/SafeMath.sol";
import "../libraries/ReentrancyGuard.sol";
import "../libraries/SafeCast.sol";
import "../libraries/SignedSafeMath.sol";
import "../libraries/TransferHelper.sol";
import "./MarketStorage.sol";
import "../interfaces/IMarketLogic.sol";
import "../interfaces/IManager.sol";
import "../interfaces/IPool.sol";
import "../interfaces/IFundingLogic.sol";
import "../interfaces/IInviteManager.sol";

/// @notice A market represents a perpetual trading market, eg. BTC_USDT (USDT settled).
/// YFX.com provides a diverse perpetual contracts including two kinds of position model, which are one-way position and
/// the hedging positiion mode, as well as three kinds of perpetual contracts, which are the linear contracts, the inverse contracts and the quanto contracts.

contract Market is MarketStorage, ReentrancyGuard {
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using SignedSafeMath for int8;
    using SafeCast for int256;
    using SafeCast for uint256;

    constructor(address _manager, address _marketLogic, address _fundingLogic){
        //require(_manager != address(0) && _marketLogic != address(0) && _fundingLogic != address(0), "Market: address is zero address");
        require(_manager != address(0) && _marketLogic != address(0), "MC0");
        manager = _manager;
        marketLogic = _marketLogic;
        fundingLogic = _fundingLogic;
    }

    modifier onlyManager() {
        require(msg.sender == manager, "O0");
        _;
    }

    modifier onlyController() {
        require(IManager(manager).checkController(msg.sender), "MO1");
        _;
    }

    modifier onlyRouter() {
        require(IManager(manager).checkRouter(msg.sender), "MO2");
        _;
    }

    modifier onlyExecutor() {
        require(IManager(manager).checkExecutorRouter(msg.sender), "MOE1");
        _;
    }

    modifier whenNotCreateOrderPaused() {
        require(!marketConfig.createOrderPaused, "MW0");
        _;
    }

    modifier whenNotSetTPSLPricePaused() {
        require(!marketConfig.setTPSLPricePaused, "MW1");
        _;
    }

    modifier whenUpdateMarginPaused() {
        require(!marketConfig.updateMarginPaused, "MW2");
        _;
    }

    /// @notice initialize market, only manager can call
    /// @param _token actually the price key, eg. "BTC_USDT"
    /// @param _marginAsset  margin asset address
    /// @param _pool pool address
    /// @param _marketType market type: {0: linear, 1: inverse, 2: quanto}
    function initialize(string memory _token, address _marginAsset, address _pool, uint8 _marketType) external {
        require(msg.sender == manager && _marginAsset != address(0) && _pool != address(0), "MIO");
        token = _token;
        marginAsset = _marginAsset;
        pool = _pool;
        marketType = _marketType;
        emit Initialize(_token, _marginAsset, _pool, _marketType);
    }

    /// @notice set market params, only controller can call
    /// @param _marketLogic market logic address
    /// @param _fundingLogic funding logic address
    function modifyLogicAddresses(
        address _marketLogic,
        address _fundingLogic
    ) external onlyController {
        require(_marketLogic != address(0), "MM0");
        if (fundingLogic != address(0)) {
            require(_fundingLogic != address(0), "MM1");
        }
        marketLogic = _marketLogic;
        fundingLogic = _fundingLogic;
        emit LogicAddressesModified(marketLogic, fundingLogic);
    }

    /// @notice set general market configurations, only controller can call
    /// @param _config configuration parameters
    function setMarketConfig(MarketDataStructure.MarketConfig memory _config) external onlyManager {
        marketConfig = _config;
        emit SetMarketConfig(marketConfig);
    }

    /// @notice switch position mode, users can choose the one-way or hedging positon mode for a specific market
    /// @param _taker taker address
    /// @param _mode mode {0: one-way, 1: hedging}
    function switchPositionMode(address _taker, MarketDataStructure.PositionMode _mode) external onlyRouter {
        positionModes[_taker] = _mode;
        emit SwitchPositionMode(_taker, _mode);
    }

    function createOrder(MarketDataStructure.CreateInternalParams memory params) public whenNotCreateOrderPaused returns (uint256) {
        require(IManager(manager).checkRouter(msg.sender) || (msg.sender == address(this)) || IManager(manager).checkExecutorRouter(msg.sender), "MO2");
        
        MarketDataStructure.Order memory order = IMarketLogic(marketLogic).createOrderInternal(params);
        order.id = ++orderID;

        orders[order.id] = order;
        takerOrderList[params._taker].push(order.id);

        if (!params.isLiquidate) takerOrderNum[params._taker][order.orderType] ++;
        _setTakerOrderTotalValue(order.taker, order.orderType, order.direction, order.freezeMargin.mul(order.takerLeverage).toInt256());


        if (!params.isLiquidate) IMarketLogic(marketLogic).checkOrder(order.id);
        return order.id;
    }

    struct ExecuteOrderInternalParams {
        bytes32 code;
        address inviter;
        uint256 discountRate;
        uint256 inviteRate;
        MarketDataStructure.Order order;
        MarketDataStructure.Position position;
        MarketDataStructure.Position oldPosition;
        MarketDataStructure.TradeResponse response;
        address inviteManager;
        int256 settleDustMargin;            // dust margin part to be settled
    }

    /// @notice execute an order
    /// @param _id order id
    /// @return resultCode execute result 0：open success；1:order open fail；2:trigger order open fail; 3:low-level call failed
    /// @return _positionId position id
    function executeOrder(uint256 _id) external nonReentrant onlyExecutor returns (uint256 resultCode, uint256 _positionId, bool isAllClosed) {
        ExecuteOrderInternalParams memory params;
        params.order = orders[_id];
        //freezeMargin > 0 ,order type is open and position direction is same as order direction;freezeMargin = 0,order type is close and position direction is neg of order direction

        int8 positionDirection;
        if (isOpenOrder(params.order.orderType)) {
            positionDirection = params.order.direction;
        } else {
            positionDirection = params.order.direction.neg256().toInt8();
        }
        MarketDataStructure.PositionKey key = getPositionKey(params.order.taker, positionDirection);
        _positionId = takerPositionList[params.order.taker][key];
        if (_positionId == 0) {
            _positionId = ++positionID;
            takerPositionList[params.order.taker][key] = _positionId;
        }

        //store position last funding rate
        orders[_id].frLastX96 = takerPositions[_positionId].frLastX96;
        //store position last funding amount
        orders[_id].fundingAmount = takerPositions[_positionId].amount.toInt256().mul(takerPositions[_positionId].direction);

        IPool(pool).updateBorrowIG();
        _settleFunding(takerPositions[_positionId]);

        params.oldPosition = takerPositions[_positionId];

        params.inviteManager = _inviteManager();
        (params.code, params.inviter, params.discountRate, params.inviteRate) = _getReferrerCodeByTaker(params.inviteManager, params.order.taker);

        uint256 indexPrice = IMarketLogic(marketLogic).getIndexOrMarketPrice(address(this), params.order.direction == 1, params.order.useIP);
        // trigger condition validation
        if (params.order.triggerPrice > 0) {
            if ((block.timestamp >= params.order.createTs.add(IManager(manager).triggerOrderDuration())) ||
                (params.order.triggerDirection == 1 ? indexPrice <= params.order.triggerPrice : indexPrice >= params.order.triggerPrice)) {
                // 2 is the error code for "trigger order open fail"
                return (2, _positionId, false);
            }
        }

        try IMarketLogic(marketLogic).trade(_id, _positionId, params.discountRate, params.inviteRate)
        returns (
            MarketDataStructure.Order memory _order,
            MarketDataStructure.Position memory _position,
            MarketDataStructure.TradeResponse memory _response
        ){
            params.order = _order;
            params.position = _position;
            params.response = _response;
        } catch Error(string memory reason) {
            emit ExecuteOrderError(_id, reason);
            orders[_id].status = MarketDataStructure.OrderStatus.OpenFail;
            // 1 is the error code for "order open fail"
            return (1, _positionId, false);
        } catch (bytes memory lowLevelData) {
            emit ExecuteOrderLowLeveError(_id, lowLevelData);
            // 3 is the error code for "low-level call failed"
            return (3, _positionId, false);
        }

        if (params.order.freezeMargin > 0) _transfer(IManager(manager).vault(), params.order.freezeMargin);
        takerOrderNum[params.order.taker][params.order.orderType]--;
        _setTakerOrderTotalValue(params.order.taker, params.order.orderType, params.order.direction, params.order.freezeMargin.mul(params.order.takerLeverage).toInt256().neg256());

        if (params.response.isIncreasePosition) {
            IPool.UpdateParams memory u;
            u.orderId = params.order.id;
            u.makerMargin = params.response.isDecreasePosition ? params.position.makerMargin : params.position.makerMargin.sub(params.oldPosition.makerMargin);
            u.takerMargin = params.response.isDecreasePosition ? params.position.takerMargin : params.position.takerMargin.sub(params.oldPosition.takerMargin);
            u.amount = params.response.isDecreasePosition ? params.position.amount : params.position.amount.sub(params.oldPosition.amount);
            u.total = params.response.isDecreasePosition ? params.position.value : params.position.value.sub(params.oldPosition.value);
            u.makerFee = params.response.isDecreasePosition ? 0 : params.order.feeToMaker;
            u.takerDirection = params.order.direction;
            u.marginToVault = params.order.freezeMargin;
            u.taker = params.order.taker;
            u.feeToInviter = params.response.isDecreasePosition ? 0 : params.order.feeToInviter;
            u.inviter = params.inviter;
            u.deltaDebtShare = params.response.isDecreasePosition ? params.position.debtShare : params.position.debtShare.sub(params.oldPosition.debtShare);
            u.feeToExchange = params.response.isDecreasePosition ? 0 : params.order.feeToExchange;
            IPool(pool).openUpdate(u);
        }
        
        if (params.response.isDecreasePosition) {
            IPool(pool).closeUpdate(
                IPool.UpdateParams(
                    params.order.id,
                    params.response.isIncreasePosition ? params.oldPosition.makerMargin : params.oldPosition.makerMargin.sub(params.position.makerMargin),
                    params.response.isIncreasePosition ? params.oldPosition.takerMargin : params.oldPosition.takerMargin.sub(params.position.takerMargin),
                    params.response.isIncreasePosition ? params.oldPosition.amount : params.oldPosition.amount.sub(params.position.amount),
                    params.response.isIncreasePosition ? params.oldPosition.value : params.oldPosition.value.sub(params.position.value),
                    params.order.rlzPnl.neg256(),
                    params.order.feeToMaker,
                    params.response.isIncreasePosition ? params.oldPosition.fundingPayment : params.oldPosition.fundingPayment.sub(params.position.fundingPayment),
                    params.oldPosition.direction,
                    params.response.isIncreasePosition ? 0 : params.order.freezeMargin,
                    params.response.isIncreasePosition ? params.oldPosition.debtShare : params.oldPosition.debtShare.sub(params.position.debtShare),
                    params.order.interestPayment,
                    params.oldPosition.isETH,
                    0,
                    params.response.toTaker,
                    params.order.taker,
                    params.order.feeToInviter,
                    params.inviter,
                    params.order.feeToExchange,
                    false
                )
            );
        }

        _updateUTP(params.inviteManager, params.order.taker, params.inviter, params.response.tradeValue);

        emit ExecuteInfo(params.order.id, params.order.orderType, params.order.direction, params.order.taker, params.response.tradeValue, params.order.feeToDiscount, params.order.tradePrice);

        if (params.response.isIncreasePosition && !params.response.isDecreasePosition) {
            require(params.position.amount > params.oldPosition.amount, "EO0");
        } else if (!params.response.isIncreasePosition && params.response.isDecreasePosition) {
            require(params.position.amount < params.oldPosition.amount, "EO1");
        } else {
            require(params.position.direction != params.oldPosition.direction, "EO2");
        }

        if (params.order.freezeMargin == 0) params.order.freezeMargin = params.oldPosition.takerMargin.sub(params.position.takerMargin);
        params.order.code = params.code;
        params.order.tradeIndexPrice = indexPrice;
        orders[_id] = params.order;
        takerPositions[_positionId] = params.position;

        // position mint
        isAllClosed = params.response.isDecreasePosition == params.response.isIncreasePosition;

        return (0, _positionId, isAllClosed);
    }

    struct LiquidateInternalParams {
        IMarketLogic.LiquidateInfoResponse response;
        uint256 toTaker;
        bytes32 code;
        address inviter;
        uint256 discountRate;
        uint256 inviteRate;
        address inviteManager;
    }

    ///@notice liquidate position
    ///@param _id position id
    ///@param action liquidate type
    ///@return liquidate order id
    function liquidate(uint256 _id, MarketDataStructure.OrderType action, uint256 clearPrice) public onlyExecutor returns (uint256) {
        LiquidateInternalParams memory params;
        MarketDataStructure.Position storage position = takerPositions[_id];
        require(position.amount > 0, "L0");

        //create liquidate order
        MarketDataStructure.Order storage order = orders[createOrder(MarketDataStructure.CreateInternalParams(position.taker, position.id, 0, 0, 0, position.amount, position.takerLeverage, position.direction.neg256().toInt8(), 0, 0, position.useIP, 1, true, position.isETH))];
        order.frLastX96 = position.frLastX96;
        order.fundingAmount = position.amount.toInt256().mul(position.direction);
        //update interest rate
        IPool(pool).updateBorrowIG();
        //settle funding rate
        _settleFunding(position);
        order.frX96 = fundingGrowthGlobalX96;
        order.fundingPayment = position.fundingPayment;

        params.inviteManager = _inviteManager();
        (params.code, params.inviter, params.discountRate, params.inviteRate) = _getReferrerCodeByTaker(params.inviteManager, order.taker);
        //get liquidate info by marketLogic
        params.response = IMarketLogic(marketLogic).getLiquidateInfo(IMarketLogic.LiquidityInfoParams(position, action, params.discountRate, params.inviteRate, clearPrice));

        //update order info
        order.code = params.code;
        order.takerFee = params.response.takerFee;
        order.feeToMaker = params.response.feeToMaker;
        order.feeToExchange = params.response.feeToExchange;
        order.feeToInviter = params.response.feeToInviter;
        order.feeToDiscount = params.response.feeToDiscount;
        order.orderType = action;
        order.interestPayment = params.response.payInterest;
        order.riskFunding = params.response.riskFunding;
        order.rlzPnl = params.response.pnl;
        order.status = MarketDataStructure.OrderStatus.Opened;
        order.tradeTs = block.timestamp;
        order.tradePrice = params.response.price;
        order.tradeIndexPrice = params.response.indexPrice;
        order.freezeMargin = position.takerMargin;

        //liquidate position，update close position info in pool
        IPool(pool).closeUpdate(
            IPool.UpdateParams(
                order.id,
                position.makerMargin,
                position.takerMargin,
                position.amount,
                position.value,
                params.response.pnl.neg256(),
                params.response.feeToMaker,
                position.fundingPayment,
                position.direction,
                0,
                position.debtShare,
                params.response.payInterest,
                position.isETH,
                order.riskFunding,
                params.response.toTaker,
                position.taker,
                order.feeToInviter,
                params.inviter,
                order.feeToExchange,
                action == MarketDataStructure.OrderType.ClearAll
            )
        );

        //emit invite info
        if (order.orderType != MarketDataStructure.OrderType.Liquidate) {
            _updateUTP(params.inviteManager, order.taker, params.inviter, params.response.tradeValue);
        }

        emit ExecuteInfo(order.id, order.orderType, order.direction, order.taker, params.response.tradeValue, order.feeToDiscount, order.tradePrice);

        //update position info
        position.amount = 0;
        position.makerMargin = 0;
        position.takerMargin = 0;
        position.value = 0;
        //position cumulative rlz pnl
        position.pnl = position.pnl.add(order.rlzPnl);
        position.fundingPayment = 0;
        position.lastUpdateTs = 0;
        //clear position debt share
        position.debtShare = 0;

        return order.id;
    }
    
    function _getReferrerCodeByTaker(address inviteManager, address taker)internal view returns(bytes32, address, uint256, uint256){
        return IInviteManager(inviteManager).getReferrerCodeByTaker(taker);
    }

    function _updateUTP(address inviteManager, address taker, address inviter, uint256 tradeValue) internal {
        IInviteManager(inviteManager).updateTradeValue(marketType, taker, inviter, tradeValue);
    }
    
    function _inviteManager() internal view returns(address){
        return IManager(manager).inviteManager();
    }

    ///@notice update market funding rate
    function updateFundingGrowthGlobal() external {
        _updateFundingGrowthGlobal();
    }

    ///@notice update market funding rate
    ///@param position taker position
    ///@return _fundingPayment
    function _settleFunding(MarketDataStructure.Position storage position) internal returns (int256 _fundingPayment){
        /// @notice once funding logic address set, address(0) is not allowed to use
        if (fundingLogic == address(0)) {
            return 0;
        }
        _updateFundingGrowthGlobal();
        _fundingPayment = IFundingLogic(fundingLogic).getFundingPayment(address(this), position.id, fundingGrowthGlobalX96);
        position.frLastX96 = fundingGrowthGlobalX96;
        if (_fundingPayment != 0) {
            position.fundingPayment = position.fundingPayment.add(_fundingPayment);
            IPool(pool).updateFundingPayment(address(this), _fundingPayment);
        }
    }

    ///@notice update market funding rate
    function _updateFundingGrowthGlobal() internal {
        //calc current funding rate by fundingLogic
        if (fundingLogic != address(0)) {
            int256 deltaFundingRate;
            (fundingGrowthGlobalX96, deltaFundingRate) = IFundingLogic(fundingLogic).getFunding(address(this));
            if (block.timestamp != lastFrX96Ts) {
                lastFrX96Ts = block.timestamp;
            }
            emit UpdateFundingRate(deltaFundingRate);
        }
    }

    ///@notice cancel order, only router can call
    ///@param _id order id
    function cancel(uint256 _id) external nonReentrant onlyRouter {
        MarketDataStructure. Order storage order = orders[_id];
        require(order.status == MarketDataStructure.OrderStatus.Open || order.status == MarketDataStructure.OrderStatus.OpenFail, "MC0");
        order.status = MarketDataStructure.OrderStatus.Canceled;
        //reduce taker order count
        takerOrderNum[order.taker][order.orderType]--;
        _setTakerOrderTotalValue(order.taker, order.orderType, order.direction, order.freezeMargin.mul(order.takerLeverage).toInt256().neg256());
        if (order.freezeMargin > 0) _transfer(msg.sender, order.freezeMargin);
    }

    function _setTakerOrderTotalValue(address _taker, MarketDataStructure.OrderType orderType, int8 _direction, int256 _value) internal {
        if (isOpenOrder(orderType)) {
            _value = _value.mul(AMOUNT_PRECISION).div(marketConfig.marketAssetPrecision.toInt256());
            //reduce taker order total value
            takerOrderTotalValues[_taker][_direction] = takerOrderTotalValues[_taker][_direction].add(_value);
        }
    }

    ///@notice set order stop profit and loss price, only router can call
    ///@param _id position id
    ///@param _profitPrice take profit price
    ///@param _stopLossPrice stop loss price
    function setTPSLPrice(uint256 _id, uint256 _profitPrice, uint256 _stopLossPrice, bool isExecutedByIndexPrice) external onlyRouter whenNotSetTPSLPricePaused {
        MarketDataStructure.Position storage position = takerPositions[_id];
        position.takeProfitPrice = _profitPrice;
        position.stopLossPrice = _stopLossPrice;
        position.useIP = isExecutedByIndexPrice;
        position.lastTPSLTs = block.timestamp;
    }

    ///@notice increase or decrease taker margin, only router can call
    ///@param _id position id
    ///@param _updateMargin increase or decrease margin
    function updateMargin(uint256 _id, uint256 _updateMargin, bool isIncrease) external nonReentrant onlyRouter whenUpdateMarginPaused {
        MarketDataStructure.Position storage position = takerPositions[_id];
        int256 _deltaMargin = _updateMargin.toInt256();
        if (isIncrease) {
            position.takerMargin = position.takerMargin.add(_updateMargin);
        } else {
            position.takerMargin = position.takerMargin.sub(_updateMargin);
            _deltaMargin = _deltaMargin.neg256();
        }

        //update taker margin in pool
        IPool(pool).takerUpdateMargin(address(this), position.taker, _deltaMargin, position.isETH);
        emit UpdateMargin(_id, _deltaMargin);
    }

    function _transfer(address to, uint256 amount) internal {
        TransferHelper.safeTransfer(marginAsset, to, amount);
    }

    function isOpenOrder(MarketDataStructure.OrderType orderType) internal pure returns (bool) {
        return orderType == MarketDataStructure.OrderType.Open || orderType == MarketDataStructure.OrderType.TriggerOpen;
    }

    ///@notice get taker position id
    ///@param _taker taker address
    ///@param _direction position direction
    ///@return position id
    function getPositionId(address _taker, int8 _direction) public view returns (uint256) {
        return takerPositionList[_taker][getPositionKey(_taker, _direction)];
    }

    function getPositionKey(address _taker, int8 _direction) internal view returns (MarketDataStructure.PositionKey key) {
        //if position mode is oneway,position key is 2,else if direction is 1,position key is 1,else position key is 0
        key = positionModes[_taker] == MarketDataStructure.PositionMode.OneWay ? MarketDataStructure.PositionKey.OneWay :
            _direction == - 1 ? MarketDataStructure.PositionKey.Short : MarketDataStructure.PositionKey.Long;
    }

    function getPosition(uint256 _id) external view returns (MarketDataStructure.Position memory) {
        return takerPositions[_id];
    }

    function getOrderIds(address _taker) external view returns (uint256[] memory) {
        return takerOrderList[_taker];
    }

    function getOrder(uint256 _id) external view returns (MarketDataStructure.Order memory) {
        return orders[_id];
    }

    function getLogicAddress() external view returns (address){
        return fundingLogic;
    }

    function getMarketConfig() external view returns (MarketDataStructure.MarketConfig memory){
        return marketConfig;
    }
}
