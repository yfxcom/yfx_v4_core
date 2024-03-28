// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "../libraries/TransferHelper.sol";
import "../interfaces/IOrder.sol";
import "../interfaces/IManager.sol";
import "../interfaces/IPool.sol";
import "../interfaces/IWrappedCoin.sol";

contract Order is IOrder {
    using EnumerableSet for EnumerableSet.UintSet;

    address WETH;
    address public manager;
    uint256 public orderId;
    mapping(address => uint256[]) public makerIds;                                              // maker => orderIds
    mapping(uint256 => PoolOrder) poolOrders;                                                   // orderId => order
    mapping(address => mapping(address => EnumerableSet.UintSet)) internal notExecuteOrderIds;  // not executed order ids, maker => pool => orderIds

    modifier onlyController() {
        require(IManager(manager).checkController(msg.sender), "OOC0");
        _;
    }

    modifier onlyRouter() {
        require(IManager(manager).checkRouter(msg.sender), "OOR0");
        _;
    }

    constructor(address _manager, address _WETH){
        require(_manager != address(0), "OC0");
        manager = _manager;
        WETH = _WETH;
        emit ModifyManager(_manager);
    }

    function setManager(address _manager) external onlyController {
        require(_manager != address(0), "OS0");
        manager = _manager;
        emit ModifyManager(_manager);
    }

    /// @notice Create a new order to increase or decrease liquidity of a pool
    /// @param params The parameters of the order
    function createOrder(CreateOrderParams memory params) external override onlyRouter {
        orderId++;
        uint32 createTs = uint32(block.timestamp);
        PoolOrder memory order;
        order.id = orderId;
        order.maker = params.maker;
        order.pool = params.pool;
        order.executeFee = params.executeFee;
        order.isETH = params.isETH;
        order.status = PoolOrderStatus.Submit;
        order.orderType = params.orderType;
        order.createTs = createTs;
        if (params.orderType == PoolOrderType.Increase) {
            uint256 minAddLiquidityAmount = IPool(params.pool).minAddLiquidityAmount();
            require(params.margin >= minAddLiquidityAmount && params.margin > 0, "OCI0");
            order.margin = params.margin;
            order.leverage = params.leverage;
            order.isStakeLp = params.isStakeLp;
        } else {
            // check the liquidity of the pool
            IPool.Position memory position = IPool(params.pool).makerPositions(IPool(params.pool).makerPositionIds(params.maker));
            require(position.liquidity > 0 && params.liquidity > 0, "OCI2");
            order.liquidity = params.liquidity;
            order.isUnStakeLp = params.isUnStakeLp;
        }

        poolOrders[orderId] = order;
        makerIds[params.maker].push(orderId);
        EnumerableSet.add(notExecuteOrderIds[params.maker][params.pool], orderId);
        emit CreatePoolOrder(params.maker, params.pool, orderId, order.liquidity, order.margin, order.leverage, params.executeFee, params.isStakeLp, params.isUnStakeLp, params.orderType, createTs);
    }

    /// @notice Update the status of the order
    /// @param _orderId The id of the order
    /// @param status The address of the pool
    function updatePoolOrder(uint256 _orderId, PoolOrderStatus status) external override {
        require(IManager(manager).checkExecutorRouter(msg.sender) || IManager(manager).checkRouter(msg.sender), "OUP");
        require(status != PoolOrderStatus.Submit, "OUP0");
        PoolOrder storage order = poolOrders[_orderId];
        if (status == PoolOrderStatus.Cancel) require(order.status == PoolOrderStatus.Submit, "OUP1");
        order.status = status;
        address baseAsset = IPool(order.pool).getBaseAsset();
        if (order.orderType == PoolOrderType.Increase) {
            if (status == PoolOrderStatus.Success) {
                // transfer margin to the vault
                TransferHelper.safeTransfer(baseAsset, IManager(manager).vault(), order.margin);
            } else {
                // refund margin
                if (order.isETH) {
                    IWrappedCoin(WETH).withdraw(order.margin);
                    TransferHelper.safeTransferETH(order.maker, order.margin);
                } else {
                    TransferHelper.safeTransfer(baseAsset, order.maker, order.margin);
                }
            }
        }
        EnumerableSet.remove(notExecuteOrderIds[order.maker][order.pool], order.id);
        emit UpdatePoolOrder(order.maker, order.pool, order.id, status);
    }

    function getPoolOrder(uint256 _orderId) external view override returns (PoolOrder memory) {
        return poolOrders[_orderId];
    }

    /// @notice get the not execute order ids
    /// @param _pool pool address
    /// @param _maker maker address
    /// @return ids order ids
    function getUnExecuteOrderIds(address _pool, address _maker) external view returns (uint256[] memory){
        uint256[] memory ids = new uint256[](EnumerableSet.length(notExecuteOrderIds[_maker][_pool]));
        for (uint256 i = 0; i < EnumerableSet.length(notExecuteOrderIds[_maker][_pool]); i++) {
            ids[i] = EnumerableSet.at(notExecuteOrderIds[_maker][_pool], i);
        }
        return ids;
    }
}
