// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import "../libraries/SafeMath.sol";
import "../libraries/Tick.sol";
import "../libraries/Constant.sol";
import "../libraries/SwapMath.sol";
import "../interfaces/IPriceHelper.sol";
import "../interfaces/IPool.sol";
import "../interfaces/IManager.sol";

contract PriceHelper is IPriceHelper {
    using SafeMath for uint256;

    uint8 constant TICK_LENGTH = 7;
    uint8 constant MAX_TICK = TICK_LENGTH - 1;
    
    struct MarketSlot0 {
        uint256 netSize;
        uint256 premiumX96;
        uint256 totalBufferSize;
        bool isLong;
        bool initialized;
        uint8 currentTick;
        uint8 pendingTick;
        uint8 liquidationIndex;
        Tick.Info[TICK_LENGTH] ticks;
        uint256[TICK_LENGTH] liquidationBufferSize;
    }

    address public manager;
    mapping(address => MarketSlot0) public marketSlot0;
    mapping(address => MarketTickConfig) public marketConfig;

    constructor(address _manager) {
        manager = _manager;
    }

    modifier onlyMarketPriceFeed() {
        require(IManager(manager).checkMarketPriceFeed(msg.sender), "only manager");
        _;
    }

    function onMarketConfigModified(address market, uint256 liquidity, uint256 indexPrice) internal {
        _modifyHigherTickInfo(market, liquidity, indexPrice);
    }

    function _validateMarketTickConfig(MarketTickConfig memory cfg) internal pure{
        require(cfg.tickConfigs.length == TICK_LENGTH && cfg.liquidationIndex < TICK_LENGTH,"error tick config length");
        require(cfg.tickConfigs[0].sizeRate == 0 && cfg.tickConfigs[0].premium == 0, "error tick config 0");
        require(
            cfg.tickConfigs[MAX_TICK].sizeRate <= Constant.RATE_DIVISOR &&
            cfg.tickConfigs[MAX_TICK].premium <= Constant.RATE_DIVISOR,
            "error tick config max value"
        );

        uint8 i;
        for(i = 1; i < TICK_LENGTH; i ++){
            Tick.Config memory previous = cfg.tickConfigs[i-1];
            Tick.Config memory next = cfg.tickConfigs[i];
            require(previous.sizeRate <= next.sizeRate && previous.premium <= next.premium,"error tick config");
        }
    }

    function modifyMarketTickConfig(address pool, address market, MarketTickConfig memory cfg, uint256 indexPrice) public override onlyMarketPriceFeed {
        _validateMarketTickConfig(cfg);
        uint8 i = 0;

        MarketTickConfig storage _config = marketConfig[market];
        MarketSlot0 storage slot0 = marketSlot0[market];

        if (slot0.initialized) {
            require(_config.baseAssetDivisor == cfg.baseAssetDivisor, "base asset divisor can not be changed");
            require(_config.multiplier == cfg.multiplier, "multiplier can not be changed");
            require(_config.marketType == cfg.marketType, "market type can not be changed");
        } else {
            _config.marketType = cfg.marketType;
            _config.isLinear = _config.marketType == 1 ? false : true;
            _config.baseAssetDivisor = cfg.baseAssetDivisor;
            _config.multiplier = cfg.multiplier;
            slot0.initialized = true;
        }

        for (i = 0; i < TICK_LENGTH; i ++) {
            _config.tickConfigs[i] = cfg.tickConfigs[i];
        }

        _config.liquidationIndex = cfg.liquidationIndex;
        slot0.liquidationIndex = cfg.liquidationIndex;
        
        uint256 liquidity = _getMarketLiquidity(pool, market);

        onMarketConfigModified(market, liquidity, indexPrice);
        emit TickConfigChanged(market, cfg);
    }

    function _modifyTicksRange(address market, uint256 liquidity, uint8 startIndex, uint8 endIndex, uint256 indexPrice) internal {
        if (endIndex < MAX_TICK) {
            Tick.Info memory endTick = marketSlot0[market].ticks[endIndex];
            Tick.Info memory nextTick = marketSlot0[market].ticks[endIndex + 1];
            if (endTick.size >= nextTick.size || endTick.premiumX96 >= nextTick.premiumX96) {
                endIndex = MAX_TICK;
            }
        }
        _modifyTicksInfo(market, liquidity, startIndex, endIndex, indexPrice);
    }

    function _modifyHigherTickInfo(address market, uint256 liquidity, uint256 indexPrice) internal {
        uint8 start = marketSlot0[market].currentTick;
        marketSlot0[market].pendingTick = start;
        _modifyTicksInfo(market, liquidity, start, MAX_TICK, indexPrice);
    }

    function _modifyTicksInfo(address market, uint256 liquidity, uint8 startIndex, uint8 endIndex, uint256 indexPrice) internal {
        bool isLiner = marketConfig[market].isLinear;
        for (uint8 i = startIndex + 1; i <= endIndex; i++) {
            uint32 sizeRate = marketConfig[market].tickConfigs[i].sizeRate;
            uint32 premium = marketConfig[market].tickConfigs[i].premium;
            (uint256 sizeAfter, uint256 premiumX96After) = Tick.calcTickInfo(sizeRate, premium, isLiner, liquidity, indexPrice);

            if (i > 1) {
                Tick.Info memory previous = marketSlot0[market].ticks[i - 1];
                if (previous.size >= sizeAfter || previous.premiumX96 >= premiumX96After) {
                    (sizeAfter, premiumX96After) = (previous.size, previous.premiumX96);
                }
            }

            marketSlot0[market].ticks[i].size = sizeAfter;
            marketSlot0[market].ticks[i].premiumX96 = premiumX96After;
            emit TickInfoChanged(market, i, sizeAfter, premiumX96After);

            if (i == endIndex && endIndex < MAX_TICK) {
                Tick.Info memory next = marketSlot0[market].ticks[i + 1];
                if (sizeAfter >= next.size || premiumX96After >= next.premiumX96) {
                    endIndex = MAX_TICK;
                }
            }
        }
    }

    /// @notice trade related functions
    struct TradeVars {
        bool isTakerLong;
        bool premiumIncrease;
        bool slippageAdd;
        bool liquidation;
        bool isLinear;
        bool exactSize;
    }

    function _validateTradeParas(CalcTradeInfoParams memory params) internal view{
        require(params.deltaSize > 0 || params.deltaValue > 0, "invalid size and value");
        require(params.indexPrice > 0, "invalid index price");
        require(marketSlot0[params.market].initialized, "market price helper not initialized");
    }

    /// @notice calculate trade info
    /// @param params trade parameters
    /// @return tradeSize trade size
    /// @return tradeVol trade volume
    /// @return tradePrice trade price
    function calcTradeInfo(CalcTradeInfoParams memory params) public override onlyMarketPriceFeed returns (uint256 tradeSize, uint256 tradeVol, uint256 tradePrice) {
        MarketSlot0 storage slot0 = marketSlot0[params.market];
        TradeVars memory vars;
        uint256 amountSpecified;

        vars.isTakerLong = params.isTakerLong;
        if (params.deltaSize > 0) {
            amountSpecified = params.deltaSize;
            vars.exactSize = true;
        } else {
            amountSpecified = params.deltaValue;
            vars.exactSize = false;
        }

        if (params.liquidation) {
            require(vars.exactSize, "liquidation trade should be exact size");
        }

        if (slot0.netSize == 0) {
            vars.premiumIncrease = true;
            slot0.isLong = !params.isTakerLong;
        } else {
            vars.premiumIncrease = (params.isTakerLong != slot0.isLong);
        }

        vars.slippageAdd = !slot0.isLong;
        vars.isLinear = marketConfig[params.market].isLinear;
        vars.liquidation = params.liquidation;
        

        (tradeSize, tradeVol) = _calcTradeInfoOneSide(
            params.market,
            slot0,
            params.indexPrice,
            amountSpecified,
            vars
        );
        
        if (vars.exactSize) {
            amountSpecified = amountSpecified.sub(tradeSize);
        } else {
            amountSpecified = amountSpecified.sub(tradeVol);
        }

        if (vars.premiumIncrease) {
            slot0.isLong = !params.isTakerLong;
            if (vars.exactSize) {
                require(amountSpecified == 0, "out of liquidity");
            }
        } else {
            if (slot0.pendingTick > slot0.currentTick) {
                uint256 liquidity = _getMarketLiquidity(params.pool, params.market);
                _modifyTicksRange(params.market, liquidity, slot0.currentTick, slot0.pendingTick, params.indexPrice);
                slot0.pendingTick = slot0.currentTick;
            }

            if (slot0.netSize > 0) {
                // should finish the trade
                if (vars.exactSize) {
                    require(amountSpecified == 0, "exact size decrease premium error");
                }
            } else {
                if (amountSpecified > 0) {
                    slot0.isLong = !slot0.isLong;
                    vars.premiumIncrease = true;
                    vars.slippageAdd = !vars.slippageAdd;
                    (uint256 tradeSizePart2, uint256 tradeVolPart2) = _calcTradeInfoOneSide(
                        params.market,
                        slot0,
                        params.indexPrice,
                        amountSpecified,
                        vars
                    );
                    tradeSize = tradeSize.add(tradeSizePart2);
                    tradeVol = tradeVol.add(tradeVolPart2);
                }
            }
        }

        if (tradeSize > 0 && tradeVol > 0) {
            tradePrice = SwapMath.avgTradePrice(tradeSize, tradeVol, vars.isLinear);
        } else {
            tradePrice = _calcMarketPrice(params.indexPrice, slot0.premiumX96, vars.slippageAdd);
        }
        
        emit Slot0StateChanged(params.market, slot0.netSize, slot0.premiumX96, slot0.isLong, slot0.currentTick);
    }


    struct CalcTradeInfoOneSideVars {
        uint8 maxTick;
        uint256 sizeUsed;
        uint256 volUsed;
        uint256 tradePrice;
        bool crossTick;
    }

    function _calcTradeInfoOneSide(
        address market,
        MarketSlot0 storage slot0,
        uint256 indexPrice,
        uint256 amountSpecified,
        TradeVars memory vars
    ) internal returns (uint256 tradeSize, uint256 tradeVol) {

        if (slot0.currentTick == 0) {
            slot0.currentTick = 1;
        }

        uint8 index;
        CalcTradeInfoOneSideVars memory tmp;
        SwapMath.SwapStep memory step = SwapMath.SwapStep({
            current: Tick.Info(0, 0),
            lower: Tick.Info(0, 0),
            upper: Tick.Info(0, 0)
        });

        index = slot0.currentTick;
        tmp.maxTick = TICK_LENGTH;

        if (vars.liquidation && vars.premiumIncrease) {
            tmp.maxTick = slot0.liquidationIndex + 1;
        }

        while (amountSpecified > 0 && index > 0 && index < tmp.maxTick) {
            Tick.Info memory endTick;
            step.lower = slot0.ticks[index - 1];
            step.upper = slot0.ticks[index];

            step.current.size = slot0.netSize;
            step.current.premiumX96 = slot0.premiumX96;

            if (!vars.premiumIncrease) {
                // premium goes to lower tick, user liquidation buffer size first
                uint256 bufferedSize = slot0.liquidationBufferSize[index];
                if (bufferedSize > 0) {
                    tmp.tradePrice = _calcMarketPrice(indexPrice, step.current.premiumX96, vars.slippageAdd);

                    if (vars.exactSize) {
                        tmp.sizeUsed = amountSpecified < bufferedSize ? amountSpecified : bufferedSize;
                        tmp.volUsed = SwapMath.sizeToVol(tmp.tradePrice, tmp.sizeUsed, vars.isLinear);
                        amountSpecified = amountSpecified.sub(tmp.sizeUsed);
                    } else {
                        uint256 maxBufferedVol = SwapMath.sizeToVol(tmp.tradePrice, bufferedSize, vars.isLinear);
                        tmp.volUsed = amountSpecified < maxBufferedVol ? amountSpecified : maxBufferedVol;
                        tmp.sizeUsed = SwapMath.volToSize(tmp.tradePrice, tmp.volUsed, vars.isLinear);
                        amountSpecified = amountSpecified.sub(tmp.volUsed);
                    }
                    tradeSize = tradeSize.add(tmp.sizeUsed);
                    tradeVol = tradeVol.add(tmp.volUsed);

                    bufferedSize = bufferedSize.sub(tmp.sizeUsed);
                    slot0.liquidationBufferSize[index] = bufferedSize;
                    slot0.totalBufferSize = slot0.totalBufferSize.sub(tmp.sizeUsed);
                    emit LiquidationBufferSizeChanged(market, index, bufferedSize);
                }
            }

            if (amountSpecified == 0) {
                break;
            }

            (tmp.crossTick, tmp.sizeUsed, tmp.volUsed, endTick) = SwapMath.computeSwapStep(
                amountSpecified,
                indexPrice,
                step,
                vars.slippageAdd,
                vars.premiumIncrease,
                vars.isLinear,
                vars.exactSize
            );

            vars.premiumIncrease ? index ++ : index --;
            tradeSize = tradeSize.add(tmp.sizeUsed);
            tradeVol = tradeVol.add(tmp.volUsed);
            slot0.netSize = endTick.size;
            slot0.premiumX96 = endTick.premiumX96;

            if (vars.exactSize) {
                amountSpecified = amountSpecified.sub(tmp.sizeUsed);
            } else {
                amountSpecified = amountSpecified.sub(tmp.volUsed);
            }

            if (tmp.crossTick && index < TICK_LENGTH) {
                slot0.currentTick = index;
            }

            if (amountSpecified == 0) {
                break;
            }

            // when exactSize == false, the final trade vol is not equal to requested amountSpecified
            // and if !crossTick the trade must be finished.
            if (!tmp.crossTick) {
                require(!vars.exactSize, "trade info calc error");
                break;
            }
        }

        // vars.liquidation = true indicates vars.exactSize = true;
        if (vars.liquidation && vars.premiumIncrease && amountSpecified > 0) {
            require(vars.exactSize, "liquidation should be exact size");
            tmp.tradePrice = _calcMarketPrice(indexPrice, slot0.premiumX96, vars.slippageAdd);
            tmp.volUsed = SwapMath.sizeToVol(tmp.tradePrice, amountSpecified, vars.isLinear);

            slot0.totalBufferSize = slot0.totalBufferSize.add(amountSpecified);
            slot0.liquidationBufferSize[slot0.liquidationIndex] = slot0.liquidationBufferSize[slot0.liquidationIndex].add(amountSpecified);

            tradeSize = tradeSize.add(amountSpecified);
            tradeVol = tradeVol.add(tmp.volUsed);
            amountSpecified = 0;
            emit LiquidationBufferSizeChanged(market, slot0.liquidationIndex, slot0.liquidationBufferSize[slot0.liquidationIndex]);
        }
    }

    /// @notice modify market liquidity
    /// @param pool pool address
    /// @param market market address
    /// @param indexPrice index price
    function onLiquidityChanged(address pool, address market, uint256 indexPrice) external override onlyMarketPriceFeed {
        uint256 liquidity = _getMarketLiquidity(pool, market);
        _modifyHigherTickInfo(market, liquidity, indexPrice);
    }

    function _calcMarketPrice(uint256 indexPrice, uint256 premiumX96, bool slippageAdd) internal pure returns (uint256 marketPrice) {
        if (slippageAdd) {
            marketPrice = indexPrice.mul(Constant.Q96.add(premiumX96)).div(Constant.Q96);
        } else {
            marketPrice = indexPrice.mul(Constant.Q96.sub(premiumX96)).div(Constant.Q96);
        }
        require(marketPrice > 0, "market price 0");
    }

    function _getMarketLiquidity(address pool, address market) internal view returns (uint256 liquidity) {
        (,, liquidity) = IPool(pool).getMarketAmount(market);// baseAssetPrecision ---> AMOUNT_PRECISION
        liquidity = SwapMath.convertPrecision(liquidity, marketConfig[market].baseAssetDivisor, Constant.SIZE_DIVISOR);
        MarketTickConfig memory cfg = marketConfig[market];
        if(cfg.marketType == 2) {
            liquidity = liquidity.mul(Constant.MULTIPLIER_DIVISOR).div(cfg.multiplier);
        }
    }
    
    function getMarketPrice(address market, uint256 indexPrice) external view override returns (uint256 marketPrice) {
        marketPrice = _calcMarketPrice(indexPrice, marketSlot0[market].premiumX96, !marketSlot0[market].isLong);
    }

    function _getMarketConfigByIndex(address market, uint8 index) internal view returns (uint32, uint32){
        Tick.Config memory cfg = marketConfig[market].tickConfigs[index];
        return (cfg.sizeRate, cfg.premium);
    }

    function getPremiumInfoByMarket(address market) external view returns (MarketSlot0 memory slot0, MarketTickConfig memory tickConfig){
        slot0 = marketSlot0[market];
        tickConfig = marketConfig[market];
    }

    function getFundingRateX96PerSecond(address market) external view override returns (int256 fundingRateX96) {
        MarketSlot0 memory slot0 = marketSlot0[market];
        require(slot0.initialized, "market premium is not initialized");

        int256 premiumX96 = int256(slot0.premiumX96);

        if (slot0.isLong) {
            // premium <  0
            if (premiumX96 > Constant.FundingRate4_10000X96) {
                fundingRateX96 = Constant.FundingRate5_10000X96 - premiumX96;
            } else {
                fundingRateX96 = Constant.FundingRate1_10000X96;
            }
        } else {
            if (premiumX96 < Constant.FundingRate6_10000X96) {
                fundingRateX96 = Constant.FundingRate1_10000X96;
            } else {
                fundingRateX96 = premiumX96 - Constant.FundingRate5_10000X96;
            }
        }

        if (fundingRateX96 < (- Constant.FundingRateMaxX96)) {
            fundingRateX96 = - Constant.FundingRateMaxX96;
        }

        if (fundingRateX96 > Constant.FundingRateMaxX96) {
            fundingRateX96 = Constant.FundingRateMaxX96;
        }
        fundingRateX96 = fundingRateX96 / Constant.FundingRate8Hours;
    }

    function getConstantValues() public pure returns (int256, int256, int256, int256, int256, int256, int256){
        return (
            Constant.FundingRate4_10000X96,
            Constant.FundingRate6_10000X96,
            Constant.FundingRate5_10000X96,
            Constant.FundingRate1_10000X96,
            Constant.FundingRateMaxX96,
            Constant.FundingRate8Hours,
            Constant.FundingRate1_10000X96 / Constant.FundingRate8Hours
        );
    }
}
