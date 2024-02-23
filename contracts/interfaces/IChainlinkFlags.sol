// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.8.0;

interface IChainlinkFlags {
  function getFlag(address) external view returns (bool);
}
