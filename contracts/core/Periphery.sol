// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import "../libraries/SafeCast.sol";
import "../libraries/SafeMath.sol";
import "../libraries/SignedSafeMath.sol";
import "../libraries/MarketDataStructure.sol";
import "../interfaces/IPool.sol";
import "../interfaces/IMarket.sol";
import "../interfaces/IFundingLogic.sol";
import "../interfaces/IManager.sol";
import "../interfaces/IMarketLogic.sol";
import "../interfaces/IMarketPriceFeed.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IPriceHelper.sol";

contract Periphery {
    using SignedSafeMath for int256;
    using SignedSafeMath for int8;
    using SafeMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;

    struct MarketConfig {
        MarketDataStructure.MarketConfig marketConfig;
        address pool;
        address marginAsset;
        uint8 marketType;
    }

    struct PoolConfig {
        uint256 minAddLiquidityAmount;
        uint256 minRemoveLiquidityAmount;
        uint256 reserveRate;
        uint256 removeLiquidityFeeRate;
        bool addPaused;
        bool removePaused;
        address baseAsset;
    }

    struct MarketInfo {
        uint256 longSize;
        uint256 shortSize;
        uint256 availableLiquidity;
        // interest info
        uint256 longBorrowRate;
        uint256 longBorrowIG;
        uint256 shortBorrowRate;
        uint256 shortBorrowIG;
        // funding info
        int256 fundingRate;
        int256 frX96;
        int256 fgX96;
        uint256 lastUpdateTs;
    }

    struct PoolInfo {
        int256 balance;
        uint256 sharePrice;
        int256 assetAmount;
        uint256 allMakerFreeze;
        uint256 totalSupply;
        int256 totalUnrealizedPNL;
        int256 makerFundingPayment;
        uint256 interestPayment;
        int256 rlzPNL;
    }

    // rate decimal 1e6

    int256 constant RATE_PRECISION = 1e6;
    // amount decimal 1e20
    uint256 constant AMOUNT_PRECISION = 1e20;
    uint256 constant PRICE_PRECISION = 1e10;

    address manager;
    address marketPriceFeed;
    address priceHelper;

    event UpdateMarketPriceFeed(address priceFeed);
    event UpdatePriceHelper(address priceHelper);

    constructor(address _manager, address _marketPriceFeed, address _priceHelper){
        require(_manager != address(0) && _marketPriceFeed != address(0) && _priceHelper != address(0), "PC0");
        manager = _manager;
        marketPriceFeed = _marketPriceFeed;
        priceHelper = _priceHelper;
    }

    modifier onlyController() {
        require(IManager(manager).checkController(msg.sender), "PO0");
        _;
    }

    function updateMarketPriceFeed(address _marketPriceFeed) external onlyController {
        require(_marketPriceFeed != address(0), "PU0");
        marketPriceFeed = _marketPriceFeed;
        emit UpdateMarketPriceFeed(_marketPriceFeed);
    }

    function updatePriceHelper(address _priceHelper) external onlyController {
        require(_priceHelper != address(0), "PUP0");
        priceHelper = _priceHelper;
        emit UpdatePriceHelper(_priceHelper);
    }

    function getMarketConfig(address _market) external view returns (MarketConfig memory config){
        config.marketConfig = IMarket(_market).getMarketConfig();
        config.pool = IMarket(_market).pool();
        config.marginAsset = IManager(manager).getMarketMarginAsset(_market);
        config.marketType = IMarket(_market).marketType();
    }

    function getPoolConfig(address _pool) external view returns (PoolConfig memory config){
        config.minAddLiquidityAmount = IPool(_pool).minAddLiquidityAmount();
        config.minRemoveLiquidityAmount = IPool(_pool).minRemoveLiquidityAmount();
        config.reserveRate = IPool(_pool).reserveRate();
        config.removeLiquidityFeeRate = IPool(_pool).removeLiquidityFeeRate();
        config.addPaused = IPool(_pool).addPaused();
        config.removePaused = IPool(_pool).removePaused();
        config.baseAsset = IPool(_pool).getBaseAsset();
    }

    ///below are view functions
    function getMarketInfo(address market) public view returns (MarketInfo memory info)  {
        address pool = IMarket(market).pool();
        (info.longSize, info.shortSize, info.availableLiquidity) = IPool(pool).getMarketAmount(market);
        (,,uint256 longFreeze,uint256 shortFreeze,,,,,,,) = IPool(pool).poolDataByMarkets(market);
        info.availableLiquidity = info.availableLiquidity.sub(longFreeze).sub(shortFreeze);

        (info.shortBorrowRate, info.shortBorrowIG) = IPool(pool).getCurrentBorrowIG(- 1);   // scaled by 1e27
        (info.longBorrowRate, info.longBorrowIG) = IPool(pool).getCurrentBorrowIG(1);     //  scaled by 1e27

        info.lastUpdateTs = IMarket(market).lastFrX96Ts();
        info.fgX96 = IMarket(market).fundingGrowthGlobalX96();
        (info.frX96, info.fundingRate) = IFundingLogic(IMarket(market).getLogicAddress()).getFunding(market);
    }

    function getPoolInfo(address _pool) external view returns (PoolInfo memory info){
        (info.sharePrice) = getSharePrice(_pool);
        info.balance = IPool(_pool).balance();
        (info.rlzPNL,,,, info.makerFundingPayment, info.interestPayment, info.allMakerFreeze) = getAllMarketData(_pool);
        info.assetAmount = IPool(_pool).balanceReal();
        info.totalSupply = IPool(_pool).totalSupply();
        (,, info.totalUnrealizedPNL) = IPool(_pool).globalHf();
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


    function getOrderIds(address _market, address taker) external view returns (uint256[] memory) {
        return IMarket(_market).getOrderIds(taker);
    }

    function getOrder(address _market, uint256 id) public view returns (MarketDataStructure.Order memory) {
        return IMarket(_market).getOrder(id);
    }

    function getPositionId(address _market, address _taker, int8 _direction) public view returns (uint256) {
        uint256 id = IMarket(_market).getPositionId(_taker, _direction);
        return id;
    }

    function getPosition(address _market, uint256 _id) public view returns (MarketDataStructure.Position memory _position, int256 _fundingPayment, uint256 _interestPayment, uint256 _maxDecreaseMargin) {
        (_position) = IMarket(_market).getPosition(_id);
        (, _fundingPayment) = getPositionFundingPayment(_market, _position.id);
        (_interestPayment) = getPositionInterestPayment(_market, _position.id);
        (_maxDecreaseMargin) = getMaxDecreaseMargin(_market, _position.id);
    }

    struct TakerPositionInfo {
        MarketDataStructure.Position position;
        int256 fundingPayment;
        uint256 interestPayment;
        uint256 maxDecreaseMargin;
    }
    ///@notice get all positions of a taker, if _market is 0, get all positions of the taker
    ///@param _market the market address
    ///@param _taker the taker address
    function getAllPosition(address _market, address _taker) external view returns (TakerPositionInfo memory longInfo, TakerPositionInfo memory shortInfo){
        uint256 longPositionId = getPositionId(_market, _taker, 1);
        uint256 shortPositionId = getPositionId(_market, _taker, - 1);
        longInfo.position = IMarket(_market).getPosition(longPositionId);
        if (longInfo.position.amount > 0) {
            (, longInfo.fundingPayment) = getPositionFundingPayment(_market, longPositionId);
            (longInfo.interestPayment) = getPositionInterestPayment(_market, longPositionId);
            (longInfo.maxDecreaseMargin) = getMaxDecreaseMargin(_market, longPositionId);
        }

        if (longPositionId != shortPositionId) {
            shortInfo.position = IMarket(_market).getPosition(shortPositionId);
            if (shortInfo.position.amount > 0) {
                (, shortInfo.fundingPayment) = getPositionFundingPayment(_market, shortPositionId);
                (shortInfo.interestPayment) = getPositionInterestPayment(_market, shortPositionId);
                (shortInfo.maxDecreaseMargin) = getMaxDecreaseMargin(_market, shortPositionId);
            }
        }
    }

    function getPositionStatus(address _market, uint256 _id) external view returns (bool) {
        MarketDataStructure.Position memory position = IMarket(_market).getPosition(_id);
        if (position.amount > 0) {
            (address fundingLogic) = IMarket(_market).getLogicAddress();
            MarketDataStructure.MarketConfig memory marketConfig = IMarket(_market).getMarketConfig();
            uint256 indexPrice = IMarketPriceFeed(marketPriceFeed).priceForIndex(IMarket(_market).token(), position.direction == - 1);
            (int256 frX96,) = IFundingLogic(fundingLogic).getFunding(position.market);
            position.fundingPayment = position.fundingPayment.add(IFundingLogic(fundingLogic).getFundingPayment(_market, _id, frX96));
            return IMarketLogic(IMarket(_market).marketLogic()).isLiquidateOrProfitMaximum(position, marketConfig.mm, indexPrice, marketConfig.marketAssetPrecision);
        }
        return false;
    }

    /// @notice get ids of maker's liquidity position id
    /// @param _pool the pool where the order in
    /// @param _maker the address of taker
    function getMakerPositionId(address _pool, address _maker) external view returns (uint256 positionId){
        positionId = IPool(_pool).makerPositionIds(_maker);
    }

    /// @notice get position by pool and position id
    /// @param _pool the pool where the order in
    /// @param _positionId the id of the position to get
    /// @return order
    function getPoolPosition(address _pool, uint256 _positionId) external view returns (IPool.Position memory){
        return IPool(_pool).makerPositions(_positionId);
    }

    /// @notice check if the position can be liquidated
    /// @param _pool maker address
    /// @param _positionId position id
    /// @return status true if the position can be liquidated
    function makerPositionHf(address _pool, uint256 _positionId) external view returns (bool status){
        (uint256 sharePrice) = getSharePrice(_pool);
        IPool.Position memory position = IPool(_pool).makerPositions(_positionId);
        uint256 currentValue = position.liquidity.mul(sharePrice).mul(10 ** IERC20(IPool(_pool).getBaseAsset()).decimals()).div(PRICE_PRECISION).div(10 ** IERC20(_pool).decimals());
        int256 pnl = currentValue.toInt256().sub(position.entryValue.toInt256());
        status = position.initMargin.toInt256().add(pnl) <= currentValue.toInt256().mul(IPool(_pool).mm().toInt256()).div(RATE_PRECISION);
    }

    /// @notice check if the pool can be clear all
    /// @param _pool maker address
    /// @return status true if the pool can be clear all
    function poolHf(address _pool) external view returns (bool status){
        (status,,) = IPool(_pool).globalHf();
    }

    function getMakerPositionLiqPrice(address _pool, uint256 _positionId) external view returns (uint256 liqSharePrice){
        IPool.Position memory position = IPool(_pool).makerPositions(_positionId);
        if (position.liquidity != 0) {
            // 18 + 10 + 18 + 6 = 52
            liqSharePrice = position.entryValue.sub(position.initMargin)
                .mul(PRICE_PRECISION).mul(10 ** IERC20(_pool).decimals()).mul(RATE_PRECISION.toUint256())
                .div(position.liquidity).div(10 ** IERC20(IPool(_pool).getBaseAsset()).decimals()).div(RATE_PRECISION.toUint256().sub(IPool(_pool).mm()));
        }
    }

    struct ClearAllPriceVar {
        int256 balance;
        int256 assetAmount;
        uint256 totalSupply;
        uint256 mm;
        int256 maxUnrealizedPNL;
        int256 makerFundingPayment;
        uint256 interestPayment;
        uint256 longAmount;
        uint256 longOpenTotal;
        uint256 shortAmount;
        uint256 shortOpenTotal;
        int256 deltaSize;
        int256 poolTotalTmp;
        uint256 lpDecimals;
        uint256 assetDecimals;
        int256 tempPrice;
    }

    function getPoolClearAllPrice(address pool, address market) external view returns (uint256 sharePrice, uint256 indexPrice){
        ClearAllPriceVar memory vars;
        vars.balance = IPool(pool).balance();
        vars.assetAmount = IPool(pool).balanceReal();
        vars.totalSupply = IPool(pool).totalSupply();
        vars.mm = IPool(pool).mm();
        vars.lpDecimals = IERC20(pool).decimals();
        vars.assetDecimals = IERC20(IPool(pool).getBaseAsset()).decimals();
        (,,,,,
            vars.makerFundingPayment,
        ,
            vars.longAmount,
            vars.longOpenTotal,
            vars.shortAmount,
            vars.shortOpenTotal
        ) = IPool(pool).poolDataByMarkets(market);
        (,,,,, vars.interestPayment,) = getAllMarketData(pool);
        uint256 precision = 10 ** (20 - vars.assetDecimals);
        uint8 marketType = IMarket(market).marketType();
        vars.poolTotalTmp = vars.balance.add(vars.longOpenTotal.add(vars.shortOpenTotal).div(precision).toInt256()).add(vars.makerFundingPayment).add(vars.interestPayment.toInt256());
        vars.maxUnrealizedPNL = vars.poolTotalTmp.mul(vars.mm.toInt256()).div(RATE_PRECISION).sub(vars.assetAmount).mul(RATE_PRECISION).div(RATE_PRECISION.sub(vars.mm.toInt256()));
        vars.poolTotalTmp = vars.poolTotalTmp.add(vars.maxUnrealizedPNL);
        sharePrice = vars.poolTotalTmp < 0 ? 0 : vars.poolTotalTmp.toUint256().mul(PRICE_PRECISION).mul(10 ** vars.lpDecimals).div(vars.totalSupply).div(10 ** vars.assetDecimals);
        vars.deltaSize = vars.longAmount.toInt256().sub(vars.shortAmount.toInt256()).div(precision.toInt256());
        if (marketType == 1) {
            vars.tempPrice = vars.deltaSize.mul(PRICE_PRECISION.toInt256()).div(vars.longOpenTotal.toInt256().sub(vars.shortOpenTotal.toInt256()).div(precision.toInt256()).add(vars.maxUnrealizedPNL));
            indexPrice = vars.tempPrice < 0 ? 0 : vars.tempPrice.toUint256();
        } else {
            if (marketType == 2) {
                vars.maxUnrealizedPNL = vars.maxUnrealizedPNL.mul(RATE_PRECISION).div((IMarket(market).getMarketConfig().multiplier).toInt256());
            }
            vars.tempPrice = vars.longOpenTotal.toInt256().sub(vars.shortOpenTotal.toInt256()).div(precision.toInt256()).sub(vars.maxUnrealizedPNL).mul(PRICE_PRECISION.toInt256()).div(vars.deltaSize);
            indexPrice = vars.deltaSize == 0 ? 0 : vars.tempPrice < 0 ? 0 : vars.tempPrice.toUint256();
        }
    }

    struct GetAllMarketDataVars {
        uint256 i;
        address[] markets;
        address market;
        int256 _rlzPNL;
        uint256 _longMakerFreeze;
        uint256 _shortMakerFreeze;
        uint256 _takerTotalMargin;
        int256 _makerFundingPayment;
        uint256 _interestPayment;
        uint256 _longInterestPayment;
        uint256 _shortInterestPayment;
    }

    /// @notice calculate the sum data of all markets
    function getAllMarketData(address pool) public view returns (
        int256 rlzPNL,
        uint256 longMakerFreeze,
        uint256 shortMakerFreeze,
        uint256 takerTotalMargin,
        int256 makerFundingPayment,
        uint256 interestPayment,
        uint256 allMakerFreeze
    ){
        GetAllMarketDataVars memory vars;
        vars.markets = IPool(pool).getMarketList();
        vars.market = vars.markets[0];
        (
            rlzPNL,
        ,
            longMakerFreeze,
            shortMakerFreeze,
            takerTotalMargin,
            makerFundingPayment,
            interestPayment,,,,
        ) = IPool(pool).poolDataByMarkets(vars.market);
        
        vars._longInterestPayment = IPool(pool).getCurrentAmount(1, IPool(pool).interestData(1).totalBorrowShare);
        vars._longInterestPayment = vars._longInterestPayment <= longMakerFreeze ? 0 : vars._longInterestPayment.sub(longMakerFreeze);
        vars._shortInterestPayment = IPool(pool).getCurrentAmount(- 1, IPool(pool).interestData(- 1).totalBorrowShare);
        vars._shortInterestPayment = vars._shortInterestPayment <= shortMakerFreeze ? 0 : vars._shortInterestPayment.sub(shortMakerFreeze);
        interestPayment = interestPayment.add(vars._longInterestPayment).add(vars._shortInterestPayment);

        allMakerFreeze = longMakerFreeze.add(shortMakerFreeze);
    }

    /// @notice check can open or not
    /// @param _pool the pool to open
    /// @param _makerMargin margin amount
    /// @return result
    function canOpen(address _pool, address _market, uint256 _makerMargin) external view returns (bool){
        return IPool(_pool).canOpen(_market, _makerMargin);
    }

    /// @notice can remove liquidity or not
    /// @param _pool the pool to remove liquidity
    /// @param _liquidity the amount to remove liquidity
    function canRemoveLiquidity(address _pool, uint256 _liquidity) external view returns (bool){
        int256 balance = IPool(_pool).balance();
        (uint256 sharePrice) = getSharePrice(_pool);
        uint256 removeValue = _liquidity.mul(sharePrice).mul(10 ** IERC20(IPool(_pool).getBaseAsset()).decimals()).div(PRICE_PRECISION).div(10 ** IERC20(_pool).decimals());
        return removeValue.toInt256() <= balance;
    }

    /// @notice can add liquidity or not
    /// @param _pool the pool to add liquidity or not
    function canAddLiquidity(address _pool) external view returns (bool){
        (,,,uint256 takerTotalMargin,,, uint256 allMakerFreeze) = getAllMarketData(_pool);
        (,,int256 totalUnPNL) = IPool(_pool).globalHf();
        if (totalUnPNL <= int256(takerTotalMargin) && totalUnPNL.neg256() <= int256(allMakerFreeze)) {
            return true;
        }
        return false;
    }

    /// @notice get funding info
    /// @param id position id
    /// @param market the market address
    /// @return frX96 current funding rate
    /// @return fundingPayment funding payment
    function getPositionFundingPayment(address market, uint256 id) public view returns (int256 frX96, int256 fundingPayment){
        MarketDataStructure.Position memory position = IMarket(market).getPosition(id);
        (address calc) = IMarket(market).getLogicAddress();
        (frX96,) = IFundingLogic(calc).getFunding(market);
        fundingPayment = position.fundingPayment.add(IFundingLogic(calc).getFundingPayment(market, position.id, frX96));
    }

    function getPositionInterestPayment(address market, uint256 positionId) public view returns (uint256 positionInterestPayment){
        MarketDataStructure.Position memory position = IMarket(market).getPosition(positionId);
        address pool = IManager(manager).getMakerByMarket(market);
        uint256 amount = IPool(pool).getCurrentAmount(position.direction, position.debtShare);
        positionInterestPayment = amount < position.makerMargin ? 0 : amount - position.makerMargin;
    }

    function getPositionMode(address _market, address _taker) external view returns (MarketDataStructure.PositionMode _mode){
        return IMarket(_market).positionModes(_taker);
    }

    function getMaxDecreaseMargin(address market, uint256 positionId) public view returns (uint256){
        return IMarketLogic(IMarket(market).marketLogic()).getMaxTakerDecreaseMargin(IMarket(market).getPosition(positionId));
    }

    function getOrderNumLimit(address _market, address _taker) external view returns (uint256 _currentOpenNum, uint256 _currentCloseNum, uint256 _currentTriggerOpenNum, uint256 _currentTriggerCloseNum, uint256 _limit){
        _currentOpenNum = IMarket(_market).takerOrderNum(_taker, MarketDataStructure.OrderType.Open);
        _currentCloseNum = IMarket(_market).takerOrderNum(_taker, MarketDataStructure.OrderType.Close);
        _currentTriggerOpenNum = IMarket(_market).takerOrderNum(_taker, MarketDataStructure.OrderType.TriggerOpen);
        _currentTriggerCloseNum = IMarket(_market).takerOrderNum(_taker, MarketDataStructure.OrderType.TriggerClose);
        _limit = IManager(manager).orderNumLimit();
    }

    /// @notice get position's liq price
    /// @param positionId position id
    ///@return liqPrice liquidation price,price is scaled by 1e8
    function getPositionLiqPrice(address market, uint256 positionId) external view returns (uint256 liqPrice){
        MarketDataStructure.MarketConfig memory marketConfig = IMarket(market).getMarketConfig();
        uint8 marketType = IMarket(market).marketType();

        MarketDataStructure.Position memory position = IMarket(market).getPosition(positionId);
        if (position.amount == 0) return 0;
        //calc position current payInterest
        uint256 payInterest = IPool(IMarket(market).pool()).getCurrentAmount(position.direction, position.debtShare);
        payInterest = payInterest < position.makerMargin ? 0 : payInterest.sub(position.makerMargin);
        //calc position current fundingPayment
        (, position.fundingPayment) = getPositionFundingPayment(position.market, positionId);
        int256 numerator;
        int256 denominator;
        int256 value = position.value.mul(marketConfig.marketAssetPrecision).div(AMOUNT_PRECISION).toInt256();
        int256 amount = position.amount.mul(marketConfig.marketAssetPrecision).div(AMOUNT_PRECISION).toInt256();
        if (marketType == 0) {
            numerator = position.fundingPayment.add(payInterest.toInt256()).add(value.mul(position.direction)).sub(position.takerMargin.toInt256()).mul(RATE_PRECISION);
            denominator = RATE_PRECISION.mul(position.direction).sub(marketConfig.mm.toInt256()).mul(amount);
        } else if (marketType == 1) {
            numerator = marketConfig.mm.toInt256().add(position.direction.mul(RATE_PRECISION)).mul(amount);
            denominator = position.takerMargin.toInt256().sub(position.fundingPayment).sub(payInterest.toInt256()).add(value.mul(position.direction)).mul(RATE_PRECISION);
        } else {
            numerator = position.fundingPayment.add(payInterest.toInt256()).sub(position.takerMargin.toInt256()).mul(RATE_PRECISION).add(value.mul(position.multiplier.toInt256()).mul(position.direction)).mul(RATE_PRECISION);
            denominator = RATE_PRECISION.mul(position.direction).sub(marketConfig.mm.toInt256()).mul(amount).mul(position.multiplier.toInt256());
        }

        if (denominator == 0) return 0;

        liqPrice = numerator.mul(1e8).div(denominator).toUint256();
    }
}
