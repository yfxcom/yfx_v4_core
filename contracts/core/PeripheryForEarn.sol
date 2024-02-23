// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import "../libraries/SafeMath.sol";
import "../libraries/MarketDataStructure.sol";
import "../interfaces/IPool.sol";
import "../interfaces/IMarket.sol";
import "../interfaces/IManager.sol";
import "../interfaces/IERC20.sol";

contract PeripheryForEarn {
    using SafeMath for uint256;

    uint256 constant PRICE_PRECISION = 1e10;
    address manager;

    constructor(address _manager){
        require(_manager != address(0), "PC0");
        manager = _manager;
    }

    function getPositionId(address _market, address _taker, int8 _direction) public view returns (uint256) {
        uint256 id = IMarket(_market).getPositionId(_taker, _direction);
        return id;
    }

    /// @notice calculate and return the share price of a pool
    function getSharePrice(address _pool) public view returns (uint256 price){
        uint256 totalSupply = IPool(_pool).totalSupply();
        if (totalSupply == 0) {
            price = PRICE_PRECISION;
        } else {
            uint256 baseAssetDecimals = IERC20(IPool(_pool).getBaseAsset()).decimals();
            uint256 decimals = IERC20(_pool).decimals();
            (,uint256 poolTotalTmp,) = IPool(_pool).globalHf();
            price = poolTotalTmp
                .mul(10 ** decimals)
                .div(totalSupply)
                .mul(PRICE_PRECISION)
                .div(10 ** baseAssetDecimals);
        }
    }
    
    ///@notice get all positions of a taker, if _market is 0, get all positions of the taker
    ///@param _market the market address
    ///@param _taker the taker address
    ///@return positions the positions of the taker
    function getAllPosition(address _market, address _taker) external view returns (MarketDataStructure.Position[] memory) {
        address[] memory markets;
        
        if (_market != address(0)) {
            markets = new address[](1);
            markets[0] = _market;
        } else {
            markets = IManager(manager).getAllMarkets();
        }

        MarketDataStructure.Position[] memory positions = new MarketDataStructure.Position[](markets.length * 2);
        uint256 index;
        for (uint256 i = 0; i < markets.length; i++) {
            uint256 longPositionId = getPositionId(markets[i], _taker, 1);
            MarketDataStructure.Position memory longPosition = IMarket(_market).getPosition(longPositionId);
            if (longPosition.amount > 0) {
                positions[index] = longPosition;
                index++;
            }

            uint256 shortPositionId = getPositionId(markets[i], _taker, - 1);
            if (longPositionId == shortPositionId) continue;
            MarketDataStructure.Position memory shortPosition = IMarket(_market).getPosition(shortPositionId);
            if (shortPosition.amount > 0) {
                positions[index] = shortPosition;
                index++;
            }
        }
        return positions;
    }
}
