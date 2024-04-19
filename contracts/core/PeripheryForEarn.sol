// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import "../libraries/SafeCast.sol";
import "../libraries/SafeMath.sol";
import "../libraries/SignedSafeMath.sol";
import "../libraries/MarketDataStructure.sol";
import "../interfaces/IPool.sol";
import "../interfaces/IMarket.sol";
import "../interfaces/IManager.sol";
import "../interfaces/IERC20.sol";

contract PeripheryForEarn {
    using SignedSafeMath for int256;
    using SignedSafeMath for int8;
    using SafeMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 constant PRICE_PRECISION = 1e10;
    uint256 constant AMOUNT_PRECISION = 1e20;
    int256 constant RATE_PRECISION = 1e6;
    address manager;

    constructor(address _manager){
        require(_manager != address(0), "PC0");
        manager = _manager;
    }

    function getPositionMode(address _market, address _taker) external view returns (MarketDataStructure.PositionMode _mode){
        return IMarket(_market).positionModes(_taker);
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

    struct GetPoolPnlVars {
        address market;
        uint256 longMakerFreeze;
        uint256 shortMakerFreeze;
        int256 makerFundingPayment;
        uint256 interestPayment;
        uint256 longAmount;
        uint256 longOpenTotal;
        uint256 shortAmount;
        uint256 shortOpenTotal;
        uint256 assetDecimals;
        uint8 marketType;
        int256 unPNL;
        uint256 _longInterestPayment;
        uint256 _shortInterestPayment;
        int256 poolTotal;
        uint256 poolTotalTmp;
    }

    function getPoolPnl(address[] memory pools, int256[] memory indexPrices) public view returns (uint256[] memory sharePrices, int256[] memory unPnls){
        sharePrices = new uint256[](pools.length);
        unPnls = new int256[](pools.length);

        for (uint256 i = 0; i < pools.length; i++) {
            address pool = pools[i];
            int256 indexPrice = indexPrices[i];
            GetPoolPnlVars memory vars;
            vars.market = IPool(pool).getMarketList()[0];
            (
            ,,
                vars.longMakerFreeze,
                vars.shortMakerFreeze,,
                vars.makerFundingPayment,
                vars.interestPayment,
                vars.longAmount,
                vars.longOpenTotal,
                vars.shortAmount,
                vars.shortOpenTotal
            ) = IPool(pool).poolDataByMarkets(vars.market);

            vars.assetDecimals = IERC20(IPool(pool).getBaseAsset()).decimals();
            vars.marketType = IMarket(vars.market).marketType();
            if (vars.marketType == 1) {
                vars.unPNL = vars.longAmount.toInt256().sub(vars.shortAmount.toInt256()).mul(PRICE_PRECISION.toInt256()).div(indexPrice);
                vars.unPNL = vars.unPNL.add(vars.shortOpenTotal.toInt256()).sub(vars.longOpenTotal.toInt256());
            } else {
                vars.unPNL = vars.shortAmount.toInt256().sub(vars.longAmount.toInt256()).mul(indexPrice).div(PRICE_PRECISION.toInt256());
                vars.unPNL = vars.unPNL.add(vars.longOpenTotal.toInt256()).sub(vars.shortOpenTotal.toInt256());
                if (vars.marketType == 2) {
                    vars.unPNL = vars.unPNL.mul((IMarket(vars.market).getMarketConfig().multiplier).toInt256()).div(RATE_PRECISION);
                }
            }
            vars.unPNL = vars.unPNL.mul((10 ** vars.assetDecimals).toInt256()).div(AMOUNT_PRECISION.toInt256());
            unPnls[i] = vars.unPNL;

            vars._longInterestPayment = IPool(pool).getCurrentAmount(1, IPool(pool).interestData(1).totalBorrowShare);
            vars._longInterestPayment = vars._longInterestPayment <= vars.longMakerFreeze ? 0 : vars._longInterestPayment.sub(vars.longMakerFreeze);
            vars._shortInterestPayment = IPool(pool).getCurrentAmount(- 1, IPool(pool).interestData(- 1).totalBorrowShare);
            vars._shortInterestPayment = vars._shortInterestPayment <= vars.shortMakerFreeze ? 0 : vars._shortInterestPayment.sub(vars.shortMakerFreeze);

            vars.poolTotal = IPool(pool).balance().add(vars.longMakerFreeze.add(vars.shortMakerFreeze).toInt256()).add(vars.unPNL).add(vars.makerFundingPayment).add(vars.interestPayment.add(vars._longInterestPayment).add(vars._shortInterestPayment).toInt256());
            vars.poolTotalTmp = vars.poolTotal < 0 ? 0 : vars.poolTotal.toUint256();
            uint256 totalSupply = IPool(pool).totalSupply();
            sharePrices[i] = totalSupply == 0 ? PRICE_PRECISION : vars.poolTotalTmp.mul(PRICE_PRECISION).mul(10 ** 18).div(totalSupply).div(10 ** vars.assetDecimals);
        }
    }
}
