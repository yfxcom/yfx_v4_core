// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import "../libraries/SafeMath.sol";
import "../libraries/SafeCast.sol";
import "../libraries/SignedSafeMath.sol";
import "../interfaces/IFundingLogic.sol";
import "../interfaces/IManager.sol";
import "../interfaces/IMarket.sol";
import "../interfaces/IPool.sol";
import "../interfaces/IMarketPriceFeed.sol";

contract FundingLogic is IFundingLogic {
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using SignedSafeMath for int8;
    using SafeCast for int256;
    using SafeCast for uint256;

    int256 public constant RATE_PRECISION = 1e6;//rate decimal 1e6
    int256 public constant PRICE_PRECISION = 1e10;//price decimal 1e10
    uint256 public constant AMOUNT_PRECISION = 1e20;
    int256 internal constant Q96 = 0x1000000000000000000000000; // 2**96
    address public manager;//manager address
    address public marketPriceFeed;//marketPriceFeed address
    
    event UpdateMarketPriceFeed(address priceFeed);

    constructor(address _manager){
        require(_manager != address(0), "FundingLogic: invalid manager");
        manager = _manager;
    }

    modifier onlyController() {
        require(IManager(manager).checkController(msg.sender), "FundingLogic: Must be controller");
        _;
    }
    
    /// @notice update market price feed, only controller can call
    /// @param _marketPriceFeed market price feed address
    function updateMarketPriceFeed(address _marketPriceFeed) external onlyController {
        marketPriceFeed = _marketPriceFeed;
        emit UpdateMarketPriceFeed(_marketPriceFeed);
    }

    struct FundingInternalParams {
        //address marketPriceFeed;
        string token;
        uint256 price;
        uint256 lastFrX96Ts;//last update timestamp
        uint8 marketType;//market type
        int256 deltaX96;//delta funding rate by deltaTime
        uint256 deltaTs;//delta time
    }

    /// @notice calculation data to update the funding
    /// @param market market address
    /// @return fundingGrowthGlobalX96 current funding rate
    function getFunding(address market) public view override returns (int256 fundingGrowthGlobalX96, int256 deltaFundingRate) {
        FundingInternalParams memory params;
        params.token = IMarket(market).token();
        params.price = IMarketPriceFeed(marketPriceFeed).priceForIndex(params.token, false);

        params.lastFrX96Ts = IMarket(market).lastFrX96Ts();
        params.marketType = IMarket(market).marketType();
        //get last funding rate
        fundingGrowthGlobalX96 = IMarket(market).fundingGrowthGlobalX96();
        
        //if funding paused, return last funding rate
        if (IManager(manager).isFundingPaused(market)) return (fundingGrowthGlobalX96, 0);

        params.deltaTs = block.timestamp - params.lastFrX96Ts;
        if (block.timestamp != params.lastFrX96Ts && params.lastFrX96Ts != 0) {
            deltaFundingRate = IMarketPriceFeed(marketPriceFeed).getFundingRateX96PerSecond(market);
            if (params.marketType == 0 || params.marketType == 2) {
                //precision calc : 24 + 10 + 10 -10 = 34
                params.deltaX96 = deltaFundingRate.mul(params.price.mul(params.deltaTs).toInt256()).div(PRICE_PRECISION);
            } else {
                params.deltaX96 = deltaFundingRate.mul(params.deltaTs.toInt256().mul(PRICE_PRECISION)).div(params.price.toInt256());
            }

            fundingGrowthGlobalX96 = fundingGrowthGlobalX96.add(params.deltaX96);
        }
    }

    /// @notice calculate funding payment
    /// @param market market address
    /// @param positionId position id
    /// @return fundingPayment funding payment
    function getFundingPayment(address market, uint256 positionId, int256 fundingGrowthGlobalX96) external view override returns (int256 fundingPayment){
        MarketDataStructure.Position memory position = IMarket(market).getPosition(positionId);
        MarketDataStructure.MarketConfig memory marketConfig = IMarket(market).getMarketConfig();
        uint8 marketType = IMarket(market).marketType();
        //precision calc : 20 + 34
        fundingPayment = position.amount.toInt256().mul(fundingGrowthGlobalX96.sub(position.frLastX96)).mul(position.direction).div(Q96);

        if (marketType == 2) {
            fundingPayment = fundingPayment.mul(position.multiplier.toInt256()).div(RATE_PRECISION);
        }
        fundingPayment = fundingPayment.mul(marketConfig.marketAssetPrecision.toInt256()).div(AMOUNT_PRECISION.toInt256());
    }
}
