// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.0 <0.8.0;
pragma abicoder v2;

import "./IPriceHelper.sol";

interface IMarketPriceFeed {
    function priceForTrade(address pool, address market, string memory token, int8 takerDirection, uint256 deltaSize, uint256 deltaValue, bool isLiquidation) external returns (uint256 size, uint256 vol, uint256 tradePrice);

    function priceForPool(string memory _token, bool _maximise) external view returns (uint256);

    function priceForLiquidate(string memory _token, bool _maximise) external view returns (uint256);

    function priceForIndex(string memory _token, bool _maximise) external view returns (uint256);

    function getLatestPrimaryPrice(string memory _token) external view returns (uint256);

    function onLiquidityChanged(address pool, address market, uint256 indexPrice) external;

    function getFundingRateX96PerSecond(address market) external view returns(int256 fundingRateX96);

    function modifyMarketTickConfig(address pool, address market, string memory token, IPriceHelper.MarketTickConfig memory cfg) external;

    function getMarketPrice(address market, string memory _token, bool maximise) external view returns (uint256 marketPrice);
}
