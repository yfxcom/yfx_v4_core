// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.8.0;

interface IWrappedCoin {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
    function withdraw(uint256) external;
}
