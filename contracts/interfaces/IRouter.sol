// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.0 <0.8.0;

interface IRouter {
    function executorTransfer(address to, uint256 amount) external;

    function removeNotExecuteOrderId(address taker, address market, uint256 orderId) external;
}
