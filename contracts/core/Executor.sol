// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import "../libraries/SafeMath.sol";
import "../libraries/MarketDataStructure.sol";
import "../libraries/TransferHelper.sol";
import "../libraries/SafeCast.sol";
import "../libraries/SignedSafeMath.sol";
import "../libraries/ReentrancyGuard.sol";
import "../libraries/Multicall.sol";
import "../interfaces/IManager.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IWrappedCoin.sol";
import "../interfaces/IMarket.sol";
import "../interfaces/IRiskFunding.sol";
import "../interfaces/IPool.sol";
import "../interfaces/IFastPriceFeed.sol";
import "../interfaces/IRewardRouter.sol";
import "../interfaces/IOrder.sol";
import "../interfaces/IRouter.sol";

contract Executor is ReentrancyGuard, Multicall {
    using SafeMath for uint256;
    using SafeMath for uint32;
    using SignedSafeMath for int256;
    using SafeCast for int256;
    using SafeCast for uint256;

    address internal WETH;
    address public manager;
    address fastPriceFeed;
    address riskFunding;
    address rewardRouter;
    address poolOrder;

    event OrderExecuted(address executer, address market, uint256 id, uint256 orderid);
    event Liquidate(address market, uint256 id, uint256 orderid, address liquidator);
    event AddLiquidity(uint256 id, address pool, uint256 amount);
    event RemoveLiquidity(uint256 id, address pool, uint256 liquidity);
    event ExecuteAddLiquidityOrder(uint256 id, address pool);
    event SetParams(address _fastPriceFeed, address _riskFunding, address _rewardRouter, address _order);
    event CloseTakerPositionWithClearPrice(address market, uint256 id, uint256 cleearPrice);
    event UnstakeLpForAccountError(string error);
    event UnstakeLpForAccountLowLevelError(bytes error);
    event StakeLpForAccountError(string error);
    event StakeLpForAccountLowLevelError(bytes error);
    event ModifyStakeAmountError(string error);
    event ModifyStakeAmountLowLevelError(bytes error);
    event AddLiquidityError(string error);
    event AddLiquidityLowLevelError(bytes error);
    event RemoveLiquidityError(string error);
    event RemoveLiquidityLowLevelError(bytes error);

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
    /// @param _fastPriceFeed fast price feed contract address
    /// @param _riskFunding risk funding contract address
    /// @param _rewardRouter reward router contract address
    /// @param _order pool order contract address
    function setConfigParams(address _fastPriceFeed, address _riskFunding, address _rewardRouter, address _order) external onlyController {
        require(_fastPriceFeed != address(0) && _riskFunding != address(0) && _order != address(0), "ESC0");
        fastPriceFeed = _fastPriceFeed;
        riskFunding = _riskFunding;
        rewardRouter = _rewardRouter;
        poolOrder = _order;

        emit SetParams(_fastPriceFeed, _riskFunding, _rewardRouter, _order);
    }

    /// @notice execute order
    /// @param _market market contract address
    /// @param _orderId order id
    function executeOrder(address _market, uint256 _orderId) external nonReentrant validateMarket(_market) {
        MarketDataStructure.Order memory order = IMarket(_market).getOrder(_orderId);

        if (order.orderType == MarketDataStructure.OrderType.Open || order.orderType == MarketDataStructure.OrderType.Close) {
            require(
                IManager(manager).checkExecutor(msg.sender, 0) ||
                order.createTs.add(IManager(manager).communityExecuteOrderDelay()) < block.timestamp,
                "EE0"
            );
        } else {
            require(IManager(manager).checkExecutor(msg.sender, 1), "EE1");
        }

        if (order.id != 0 && order.status == MarketDataStructure.OrderStatus.Open) {
            (int256 resultCode,uint256 positionId, bool isAllClosed) = IMarket(_market).executeOrder(_orderId);
            address router = IManager(manager).router();
            if (resultCode == 0) {
                IRouter(router).removeNotExecuteOrderId(order.taker, order.market, order.id);
                _modifyStakeAmount(order.market, order.taker, isAllClosed);
            }
            if (resultCode == 0 || resultCode == 1) {
                IRouter(router).executorTransfer(msg.sender, order.executeFee);
            }
            emit OrderExecuted(msg.sender, order.market, positionId, order.id);
        }
    }

    /// @notice execute position liquidation, take profit and tpsl
    function executePositionTrigger(address _market, uint256 id, MarketDataStructure.OrderType action) external {
        require(IManager(manager).checkExecutor(msg.sender, 3), "EP0");

        _liquidate(msg.sender, _market, id, action, 0);
    }

    /// @notice execute position liquidation, take profit and tpsl
    /// @param _market  market contract address
    /// @param id   position id
    function liquidate(address _market, uint256 id) external {
        _liquidate(msg.sender, _market, id, MarketDataStructure.OrderType.Liquidate, 0);
    }

    function closeTakerPositionWithClearPrice(address _pool, address _market, uint256 _positionId, uint256 _clearPrice) external {
        require(IManager(manager).checkSigner(msg.sender, 0), "EC0");
        require(IPool(_pool).clearAll(), "EC1");

        _liquidate(msg.sender, _market, _positionId, MarketDataStructure.OrderType.ClearAll, _clearPrice);

        emit CloseTakerPositionWithClearPrice(_market, _positionId, _clearPrice);
    }

    function _liquidate(address _caller, address _market, uint256 id, MarketDataStructure.OrderType action, uint256 _clearPrice) internal nonReentrant validateMarket(_market) {
        MarketDataStructure.Position memory position = IMarket(_market).getPosition(id);
        uint256 orderId = IMarket(_market).liquidate(id, action, _clearPrice);

        if (MarketDataStructure.OrderType.Liquidate == action) {
            IRiskFunding(riskFunding).updateLiquidatorExecutedFee(_caller);
        }

        _modifyStakeAmount(_market, position.taker, true);

        emit Liquidate(_market, id, orderId, _caller);
    }

    function _modifyStakeAmount(address market, address taker, bool isAllClose) internal {
        if (rewardRouter != address(0)) {
            try IRewardRouter(rewardRouter).modifyStakedPosition(market, taker, isAllClose){}
            catch Error(string memory reason){
                emit ModifyStakeAmountError(reason);
            }
            catch (bytes memory error){
                emit ModifyStakeAmountLowLevelError(error);
            }
        }
    }

    /// @notice execute pool order
    /// @param _orderId order id
    function executePoolOrder(uint256 _orderId) external payable nonReentrant returns (bool isSuccess) {
        require(IManager(manager).checkExecutor(msg.sender, 2), "EPO0");

        IOrder.PoolOrder memory order = IOrder(poolOrder).getPoolOrder(_orderId);
        require(order.status == IOrder.PoolOrderStatus.Submit && order.id > 0, "EPO1");
        isSuccess = order.orderType == IOrder.PoolOrderType.Increase ? _addLiquidity(order) :
            _removeLiquidity(order.id, order.pool, order.maker, order.liquidity, order.isUnStakeLp, order.isETH, false);

        // refund or send execute fee
        IOrder(poolOrder).updatePoolOrder(order.id, isSuccess ? IOrder.PoolOrderStatus.Success : IOrder.PoolOrderStatus.Fail);
        IRouter(IManager(manager).router()).executorTransfer(isSuccess ? msg.sender : order.maker, order.executeFee);
    }

    /// @notice remove liquidity by system ,tp/sl
    /// @param _pool pool address
    /// @param _maker maker address
    /// @param isReceiveETH whether receive ETH
    function removeLiquidityBySystem(address _pool, address _maker, bool isReceiveETH) external nonReentrant {
        require(IManager(manager).checkExecutor(msg.sender, 3), "ER0");
        _removeLiquidity(0, _pool, _maker, type(uint256).max, true, isReceiveETH, true);
    }

    function _addLiquidity(IOrder.PoolOrder memory order) internal returns (bool isAddSuccess){
        try IPool(order.pool).addLiquidity(order.id, order.maker, order.margin, order.leverage) returns (uint256 liquidity){
            isAddSuccess = true;
            if (order.isStakeLp && rewardRouter != address(0)) {
                try IRewardRouter(rewardRouter).stakeLpForAccount(order.maker, order.pool, liquidity){}
                catch Error(string memory reason){
                    emit StakeLpForAccountError(reason);
                }
                catch (bytes memory error){
                    emit StakeLpForAccountLowLevelError(error);
                }
            }
        }
        catch Error(string memory reason){
            isAddSuccess = false;
            emit AddLiquidityError(reason);
        }
        catch (bytes memory error){
            isAddSuccess = false;
            emit AddLiquidityLowLevelError(error);
        }
    }

    function _removeLiquidity(uint256 _orderId, address _pool, address _maker, uint256 _liquidity, bool _isUnStake, bool _isReceiveETH, bool _isSystem) internal returns (bool isRemoveSuccess){
        _preRemoveLiquidity(_maker, _pool, _liquidity, _isUnStake, false);
        try IPool(_pool).removeLiquidity(_orderId, _maker, _liquidity, IPool(_pool).getBaseAsset() == WETH ? _isReceiveETH : false, _isSystem){
            isRemoveSuccess = true;
        }
        catch Error(string memory reason){
            isRemoveSuccess = false;
            emit RemoveLiquidityError(reason);
        }
        catch (bytes memory error){
            isRemoveSuccess = false;
            emit RemoveLiquidityLowLevelError(error);
        }
    }

    /// @notice liquidate the liquidity position
    /// @param _pool pool address
    /// @param _positionId position id
    function liquidateLiquidityPosition(address _pool, uint256 _positionId) external nonReentrant {
        require(IManager(manager).checkExecutor(msg.sender, 3), "EL0");

        _liquidateLiquidityPosition(_pool, _positionId);
        IRiskFunding(riskFunding).updateLiquidatorExecutedFee(msg.sender);
    }

    /// @notice clear the maker position
    /// @param _pool pool address
    /// @param _positionId position id
    function clearMakerPosition(address _pool, uint256 _positionId) external nonReentrant {
        require(IManager(manager).checkSigner(msg.sender, 0), "ECM0");

        _liquidateLiquidityPosition(_pool, _positionId);
    }

    function _liquidateLiquidityPosition(address _pool, uint256 _positionId) internal {
        IPool.Position memory position = IPool(_pool).makerPositions(_positionId);
        _preRemoveLiquidity(position.maker, _pool, position.liquidity, true, true);
        IPool(_pool).liquidate(_positionId);
    }

    function _preRemoveLiquidity(address sender, address _pool, uint256 _liquidity, bool isUnStake, bool isLiquidate) internal {
        if (isUnStake && rewardRouter != address(0)) {
            uint256 lpBalance = IERC20(_pool).balanceOf(sender);
            if (lpBalance < _liquidity) {
                try IRewardRouter(rewardRouter).unstakeLpForAccount(sender, _pool, _liquidity.sub(lpBalance), isLiquidate) {}
                catch Error(string memory reason){
                    emit UnstakeLpForAccountError(reason);
                }
                catch (bytes memory error){
                    emit UnstakeLpForAccountLowLevelError(error);
                }
            }
        }
    }

    /// @notice update offChain price by price provider
    /// @param backupPrices  backup price array
    function setPrices(bytes memory backupPrices) external nonReentrant {
        require(IManager(manager).checkSigner(msg.sender, 0), "ES0");
        IFastPriceFeed(fastPriceFeed).setPrices(msg.sender, 0, backupPrices);
    }

    /// @notice update offChain price by price provider
    /// @param pythPrices price price array
    function setPythPrices(bytes memory pythPrices) external nonReentrant {
        require(IManager(manager).checkSigner(msg.sender, 1), "ESP0");
        IFastPriceFeed(fastPriceFeed).setPrices(msg.sender, 1, pythPrices);
    }

    /// @notice update offChain price by price provider
    /// @param dataStreamPrices  data stream price array
    function setDataStreamPrices(bytes memory dataStreamPrices) external nonReentrant {
        require(IManager(manager).checkSigner(msg.sender, 2), "ESP0");
        IFastPriceFeed(fastPriceFeed).setPrices(msg.sender, 2, dataStreamPrices);
    }
}
