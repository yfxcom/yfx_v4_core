// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import "./Tick.sol";
import "./SafeMath.sol";
import "./Constant.sol";

library SwapMath {
    using SafeMath for uint256;

    struct SwapStep {
        Tick.Info lower;
        Tick.Info current;
        Tick.Info upper;
    }

    function convertPrecision(uint256 val, uint256 from, uint256 to) internal pure returns(uint256 res) {
        if(from == to) {
            res = val;
        } else {
            res = val.mul(to).div(from);
        }
    }

    function validateSwapStep(SwapStep memory step) internal pure {
        require(step.lower.size <= step.current.size && step.lower.premiumX96 <= step.current.premiumX96, "tick error 1");
        require(step.current.size <= step.upper.size && step.current.premiumX96 <= step.upper.premiumX96, "tick error 2");
    }

    function calcTradePrice(uint256 indexPrice, uint256 premium1, uint256 premium2, bool slippageAdd) internal pure returns (uint256 tradePrice) {
        if(slippageAdd){
            tradePrice = indexPrice.mul((Constant.Q96 << 1).add(premium1).add(premium2)).div(Constant.Q96 << 1);
        } else {
            tradePrice = indexPrice.mul((Constant.Q96 << 1).sub(premium1).sub(premium2)).div(Constant.Q96 << 1);
        }
    }

    function sizeToVol(uint256 tradePrice, uint256 size, bool isLinear) internal pure returns(uint256 vol){
        if(size == 0) {
            vol = 0;
        } else {
            if(isLinear){
                vol = size.mul(tradePrice).div(Constant.PRICE_DIVISOR);
            } else {
                vol = size.mul(Constant.PRICE_DIVISOR).div(tradePrice);
            }
        }
    }

    function volToSize(uint256 tradePrice, uint256 vol, bool isLinear) internal pure returns(uint256 size) {
        if(vol == 0) {
            size = 0;
        } else {
            if(isLinear) {
                size = vol.mul(Constant.PRICE_DIVISOR).div(tradePrice);
            } else {
                size = vol.mul(tradePrice).div(Constant.PRICE_DIVISOR);
            }
        }
    }

    function avgTradePrice(uint256 size, uint256 vol, bool isLinear) internal pure returns(uint256 _avgTradePrice) {
        if(isLinear) {
            _avgTradePrice = vol.mul(Constant.PRICE_DIVISOR).div(size);
        } else {
            _avgTradePrice = size.mul(Constant.PRICE_DIVISOR).div(vol);
        }
    }

    function stepMaxLiquidity (uint256 indexPrice, SwapStep memory step, bool slippageAdd, bool premiumIncrease, bool isLinear) internal pure returns(uint256 sizeMax, uint256 volMax) {
        validateSwapStep(step);
        uint256 premiumX96End;
        if(premiumIncrease){
            sizeMax = step.upper.size.sub(step.current.size);
            premiumX96End = step.upper.premiumX96;
        } else {
            sizeMax = step.current.size.sub(step.lower.size);
            premiumX96End = step.lower.premiumX96;
        }
        uint256 tradePrice = calcTradePrice(indexPrice, step.current.premiumX96, premiumX96End, slippageAdd);
        volMax = sizeToVol(tradePrice, sizeMax, isLinear);
    }

    function estimateSwapSizeInTick(
        uint256  vol,
        uint256 indexPrice,
        SwapStep memory step,
        bool slippageAdd,
        bool premiumIncrease,
        bool isLinear
    ) internal pure returns(uint256 sizeRecommended)
    {
        validateSwapStep(step);
        uint256 estimateEndPremiumX96;
        uint256 estimatePricePrice;
        if(premiumIncrease){
            if(slippageAdd){
                estimateEndPremiumX96 = isLinear ? step.upper.premiumX96 : step.current.premiumX96;
            } else {
                estimateEndPremiumX96 = isLinear ? step.current.premiumX96 : step.upper.premiumX96;
            }
        } else {
            if(slippageAdd){
                estimateEndPremiumX96 = isLinear ? step.current.premiumX96 : step.lower.premiumX96;
            } else {
                estimateEndPremiumX96 = isLinear ? step.lower.premiumX96 : step.current.premiumX96;
            }
        }

        estimatePricePrice = calcTradePrice(indexPrice, step.current.premiumX96, estimateEndPremiumX96, slippageAdd);
        sizeRecommended = volToSize(estimatePricePrice, vol, isLinear);
        
    }

    function computeSwapStep(
        uint256 amountSpecified,
        uint256 indexPrice,
        SwapStep memory step,
        bool slippageAdd,
        bool premiumIncrease,
        bool isLinear,
        bool exactSize
    ) internal view returns (bool crossTick, uint256 tradeSize, uint256 tradeVol, Tick.Info memory endTick)
    {
        validateSwapStep(step);

        (uint256 sizeMax, uint256 volMax) = stepMaxLiquidity(indexPrice, step, slippageAdd, premiumIncrease, isLinear);
        if(premiumIncrease){
            endTick.size = step.upper.size;
            endTick.premiumX96 = step.upper.premiumX96;
        } else {
            endTick.size = step.lower.size;
            endTick.premiumX96 = step.lower.premiumX96;
        }

        uint256 premiumX96End;

        crossTick = exactSize ? (amountSpecified >= sizeMax) : (amountSpecified >= volMax);

        if(crossTick){
            tradeSize = sizeMax;
            tradeVol = volMax;
        } else {
            if(exactSize) {
                tradeSize = amountSpecified;
                premiumX96End = calcInMiddlePremiumX96(step, tradeSize, premiumIncrease);
                endTick.premiumX96 = premiumX96End;
                endTick.size = premiumIncrease ? step.current.size.add(tradeSize) : step.current.size.sub(tradeSize);
                uint256 tradePrice = calcTradePrice(indexPrice, step.current.premiumX96, premiumX96End, slippageAdd);
                tradeVol = sizeToVol(tradePrice, tradeSize, isLinear);
            } else {
                uint256 sizeRecommended = estimateSwapSizeInTick(amountSpecified, indexPrice, step, slippageAdd, premiumIncrease, isLinear);
                return computeSwapStep(sizeRecommended, indexPrice, step, slippageAdd, premiumIncrease, isLinear, true);
            }
        }
    }

    function calcInMiddlePremiumX96(SwapStep memory step, uint256 size, bool premiumIncrease) internal pure returns(uint256 premiumX96End) {
        uint256 sizeDelta;
        uint256 premiumX96Delta;
        uint256 premiumX96Impact;
        if(step.lower.size == step.upper.size){
            require(step.lower.premiumX96 == step.upper.premiumX96,"tick error =");
            return step.upper.premiumX96;
        }
        premiumX96Delta = step.upper.premiumX96.sub(step.lower.premiumX96);
        sizeDelta = step.upper.size.sub(step.lower.size);

        premiumX96Impact = size.mul(premiumX96Delta); // SafeMath.mul(size, premiumX96Delta);
        premiumX96Impact = premiumX96Impact.div(sizeDelta); // SafeMath.div(premiumX96Impact, sizeDelta);

        if(premiumIncrease){
            return step.current.premiumX96.add(premiumX96Impact);
        } else {
            return step.current.premiumX96.sub(premiumX96Impact);
        }
    }

}