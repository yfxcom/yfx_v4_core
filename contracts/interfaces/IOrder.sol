// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.0 <0.8.0;
pragma abicoder v2;

interface IOrder {
    enum PoolOrderType {
        Increase,
        Decrease
    }

    enum PoolOrderStatus {
        Submit,
        Success,
        Fail,
        Cancel
    }

    struct PoolOrder {
        uint256 id;                 // the id of the order
        address maker;              // the address of the maker
        address pool;               // the address of the pool
        uint256 liquidity;          // the liquidity to decrease
        uint256 margin;             // the amount of margin to increase
        uint16 leverage;           // the leverage of the margin
        uint256 executeFee;         // the fee of the order
        bool isStakeLp;             // whether the maker wants to stake LP token by increasing liquidity
        bool isUnStakeLp;           // whether the maker wants to unstake LP token by decreasing liquidity
        bool isETH;                 // whether the maker wants to receive or send ETH
        PoolOrderStatus status;     // the status of the order
        PoolOrderType orderType;    // the type of the order
        uint32 createTs;            // the timestamp of the order
    }

    struct CreateOrderParams {
        address pool;               // the address of the pool
        address maker;              // the address of the maker
        uint256 liquidity;          // the liquidity to decrease , only for decrease order
        uint256 margin;             // the amount of margin to increase, only for increase order
        uint16 leverage;           // the leverage of the margin, only for increase order
        uint256 executeFee;         // the fee of the order, not necessary
        bool isStakeLp;             // whether the maker wants to stake LP token by increasing liquidity, only for increase order
        bool isUnStakeLp;           // whether the maker wants to unstake LP token by decreasing liquidity , only for decrease order
        bool isETH;                 // whether the maker wants to receive ETH by decreasing liquidity , only for decrease order
        PoolOrderType orderType;    // the type of the order {Increase:0, Decrease:1}
    }

    event ModifyManager(address indexed newManager);
    event ModifyOrderNumLimit(uint256 newOrderNumLimit);
    event CreatePoolOrder(address indexed maker, address indexed pool, uint256 orderId, uint256 liquidity, uint256 margin, uint16 leverage, uint256 executeFee, bool isStakeLp, bool isUnStakeLp, PoolOrderType orderType, uint32 createTs);
    event UpdatePoolOrder(address indexed maker, address indexed pool, uint256 orderId, PoolOrderStatus status);

    function getPoolOrder(uint256 _orderId) external view returns (PoolOrder memory);

    function createOrder(CreateOrderParams memory params) external;

    function updatePoolOrder(uint256 _orderId, PoolOrderStatus status) external;
}
