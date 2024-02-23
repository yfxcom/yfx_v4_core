// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import "./PoolStorage.sol";

import "../interfaces/IERC20.sol";
import "../interfaces/IPool.sol";
import "../interfaces/IMarket.sol";
import "../interfaces/IInterestLogic.sol";
import "../interfaces/IMarketPriceFeed.sol";

import "../token/ERC20.sol";
import "../libraries/SafeMath.sol";
import "../libraries/SignedSafeMath.sol";
import "../libraries/SafeCast.sol";
import "../libraries/ReentrancyGuard.sol";
import "../libraries/TransferHelper.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IInviteManager.sol";

contract Pool is ERC20, PoolStorage, ReentrancyGuard {
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;

    constructor(
        address _manager,
        address _baseAsset,
        address _WETH,
        string memory _lpTokenName,
        string memory _lpTokenSymbol
    )ERC20(_manager){
        vault = IManager(_manager).vault();
        require(
            _baseAsset != address(0)
            && bytes(_lpTokenName).length != 0
            && _WETH != address(0)
            && _manager != address(0)
            && vault != address(0),
            "PC0"
        );

        baseAsset = _baseAsset;
        baseAssetDecimals = IERC20(_baseAsset).decimals();
        name = _lpTokenName;
        symbol = _lpTokenSymbol;
        WETH = _WETH;
    }
    modifier _onlyMarket(){
        require(isMarket[msg.sender], 'PMM');
        _;
    }

    modifier _onlyRouter(){
        require(IManager(manager).checkRouter(msg.sender), 'PMR');
        _;
    }

    modifier whenNotAddPaused() {
        require(!IManager(manager).paused() && !addPaused, "PMW");
        _;
    }

    modifier whenNotRemovePaused() {
        require(!IManager(manager).paused() && !removePaused, "PMWR");
        _;
    }

    function registerMarket(
        address _market
    ) external returns (bool){
        require(msg.sender == manager && !isMarket[_market], "PR0");
        isMarket[_market] = true;
        marketList.push(_market);
        MarketConfig storage args = marketConfigs[_market];
        args.marketType = IMarket(_market).marketType();
        emit RegisterMarket(_market);
        return true;
    }

    /// @notice update pool data when an order with types of open or trigger open is executed
    function openUpdate(IPool.UpdateParams memory params) external _onlyMarket {
        address _market = msg.sender;
        require(!clearAll && canOpen(_market, params.makerMargin), "PO0");
        DataByMarket storage marketData = poolDataByMarkets[_market];
        marketData.takerTotalMargin = marketData.takerTotalMargin.add(params.takerMargin);

        balance = balance.add(params.makerFee.toInt256());
        balanceReal = balanceReal.add(params.makerFee.toInt256());
        marketData.cumulativeFee = marketData.cumulativeFee.add(params.makerFee);
        balance = balance.sub(params.makerMargin.toInt256());
        interestData[params.takerDirection].totalBorrowShare = interestData[params.takerDirection].totalBorrowShare.add(params.deltaDebtShare);
        
        if (params.takerDirection == 1) {
            marketData.longMakerFreeze = marketData.longMakerFreeze.add(params.makerMargin);
            marketData.longAmount = marketData.longAmount.add(params.amount);
            marketData.longOpenTotal = marketData.longOpenTotal.add(params.total);
        } else {
            marketData.shortMakerFreeze = marketData.shortMakerFreeze.add(params.makerMargin);
            marketData.shortAmount = marketData.shortAmount.add(params.amount);
            marketData.shortOpenTotal = marketData.shortOpenTotal.add(params.total);
        }
        _marginToVault(params.marginToVault);
        _feeToExchange(params.feeToExchange);
        _vaultTransfer(params.inviter, params.feeToInviter, baseAsset == WETH);

        GlobalHf memory g = _checkPoolStatus(false);

        emit OpenUpdate(
            params.orderId,
            _market,
            params.taker,
            params.inviter,
            params.feeToExchange,
            params.makerFee,
            params.feeToInviter,
            g.sharePrice,
            marketData.shortOpenTotal,
            marketData.longOpenTotal
        );
    }

    /// @notice update pool data when an order with types of close or trigger close is executed
    function closeUpdate(IPool.UpdateParams memory params) external _onlyMarket {
        DataByMarket storage marketData = poolDataByMarkets[msg.sender];
        marketData.cumulativeFee = marketData.cumulativeFee.add(params.makerFee);
        balance = balance.add(params.makerFee.toInt256());
        balanceReal = balanceReal.add(params.makerFee.toInt256());

        marketData.rlzPNL = marketData.rlzPNL.add(params.makerProfit);
        marketData.interestPayment = marketData.interestPayment.add(params.payInterest);
        {
            int256 tempProfit = params.makerProfit.add(params.makerMargin.toInt256()).add(params.fundingPayment);
            require(tempProfit >= 0, 'PCU0');

            balance = tempProfit.add(balance).add(params.payInterest.toInt256());
            balanceReal = params.makerProfit.add(params.fundingPayment).add(params.payInterest.toInt256()).add(balanceReal);
        }

        require(marketData.takerTotalMargin >= params.takerMargin, 'PCU1');
        marketData.takerTotalMargin = marketData.takerTotalMargin.sub(params.takerMargin);
        interestData[params.takerDirection].totalBorrowShare = interestData[params.takerDirection].totalBorrowShare.sub(params.deltaDebtShare);
        if (params.fundingPayment != 0) marketData.makerFundingPayment = marketData.makerFundingPayment.sub(params.fundingPayment);
        if (params.takerDirection == 1) {
            marketData.longAmount = marketData.longAmount.sub(params.amount);
            marketData.longOpenTotal = marketData.longOpenTotal.sub(params.total);
            marketData.longMakerFreeze = marketData.longMakerFreeze.sub(params.makerMargin);
        } else {
            marketData.shortAmount = marketData.shortAmount.sub(params.amount);
            marketData.shortOpenTotal = marketData.shortOpenTotal.sub(params.total);
            marketData.shortMakerFreeze = marketData.shortMakerFreeze.sub(params.makerMargin);
        }

        GlobalHf memory g;
        if (!params.isClearAll) {
            g = _checkPoolStatus(false);
        }

        _marginToVault(params.marginToVault);
        _feeToExchange(params.feeToExchange);
        _vaultTransfer(params.taker, params.toTaker, params.isOutETH);
        _vaultTransfer(params.inviter, params.feeToInviter, baseAsset == WETH);
        _vaultTransfer(IManager(manager).riskFunding(), params.toRiskFund, false);

        emit CloseUpdate(
            params.orderId,
            msg.sender,
            params.taker,
            params.inviter,
            params.feeToExchange,
            params.makerFee,
            params.feeToInviter,
            params.toRiskFund,
            params.makerProfit.neg256(),
            params.fundingPayment,
            params.payInterest,
            g.sharePrice,
            marketData.shortOpenTotal,
            marketData.longOpenTotal
        );
    }

    function _marginToVault(uint256 _margin) internal {
        if (_margin > 0) IVault(vault).addPoolBalance(_margin);
    }

    function _feeToExchange(uint256 _fee) internal {
        if (_fee > 0) IVault(vault).addExchangeFeeBalance(_fee);
    }

    function _vaultTransfer(address _to, uint256 _amount, bool _isOutETH) internal {
        if (_amount > 0) IVault(vault).transfer(_to, _amount, _isOutETH);
    }

    /// @notice pool update when user increasing or decreasing the position margin
    function takerUpdateMargin(address _market, address taker, int256 _margin, bool isOutETH) external _onlyMarket {
        require(_margin != 0, 'PT0');
        DataByMarket storage marketData = poolDataByMarkets[_market];

        if (_margin > 0) {
            marketData.takerTotalMargin = marketData.takerTotalMargin.add(_margin.toUint256());
            _marginToVault(_margin.toUint256());
        } else {
            marketData.takerTotalMargin = marketData.takerTotalMargin.sub(_margin.neg256().toUint256());
            _vaultTransfer(taker, _margin.neg256().toUint256(), isOutETH);
        }
    }

    // update liquidity order when add liquidity
    function addLiquidity(
        uint256 orderId,
        address sender,
        uint256 amount,
        uint256 leverage
    ) external nonReentrant _onlyRouter whenNotAddPaused returns (uint256 liquidity){
        require(
            !clearAll
            && amount >= minAddLiquidityAmount
            && leverage >= minLeverage
            && leverage <= maxLeverage,
            "PA0"
        );
        
        GlobalHf memory g = _globalInfo(true);
        IPool.Position storage position;
        if (makerPositionIds[sender] == 0) {
            autoId ++;
            makerPositionIds[sender] = autoId;
            position = makerPositions[autoId];
            position.maker = sender;
        } else {
            position = makerPositions[makerPositionIds[sender]];
        }

        _updateBorrowIG(g.allMarketPos.longMakerFreeze, g.allMarketPos.shortMakerFreeze);
        _checkPoolPnlStatus(g);
        uint256 vol = amount.mul(leverage);
        liquidity = vol.mul(10 ** decimals).mul(PRICE_PRECISION).div(g.sharePrice).div(10 ** baseAssetDecimals);
        _mint(sender, liquidity);

        position.entryValue = position.entryValue.add(vol);
        position.initMargin = position.initMargin.add(amount);
        position.liquidity = position.liquidity.add(liquidity);
        position.lastAddTime = block.timestamp;
        balance = balance.add(vol.toInt256());
        balanceReal = balanceReal.add(amount.toInt256());
        _marginToVault(amount);

        _onLiquidityChanged(g.indexPrices);

        _checkPoolStatus(true);

        emit AddLiquidity(++eventId, orderId, sender, makerPositionIds[sender], amount, liquidity, vol, g.sharePrice, g.poolTotalTmp);
    }

    struct RemoveLiquidityVars {
        uint256 positionId;
        uint256 currentSharePrice;
        uint256 removeRate;
        uint256 settleEntryValue;
        uint256 settleInitMargin;
        uint256 outVol;
        uint256 feeToPool;
        int256 pnl;
        int256 outAmount;
        bool positionStatus;
        bool isTP;
        uint256 aType;              // 0: maker remove, 1: TP, 2: SL
    }

    /// @notice pool update when user increasing or decreasing the position margin
    function removeLiquidity(
        uint256 orderId,
        address sender,
        uint256 liquidity,
        bool isETH,
        bool isSystem
    ) external nonReentrant _onlyRouter whenNotRemovePaused returns (uint256 settleLiquidity){
        require(!clearAll && liquidity >= minRemoveLiquidityAmount, "PRL0");
        RemoveLiquidityVars memory vars;
        vars.positionId = makerPositionIds[sender];
        GlobalHf memory g = _globalInfo(false);
        IPool.Position storage position = makerPositions[vars.positionId];
        require(position.liquidity > 0, "PRL2");
        _updateBorrowIG(g.allMarketPos.longMakerFreeze, g.allMarketPos.shortMakerFreeze);
        _checkPoolPnlStatus(g);
        settleLiquidity = position.liquidity >= liquidity ? liquidity : position.liquidity;
        vars.removeRate = settleLiquidity.mul(1e18).div(position.liquidity);
        require(balanceOf[sender] >= settleLiquidity, "PRL3");
        vars.settleEntryValue = position.entryValue.mul(vars.removeRate).div(1e18);
        vars.settleInitMargin = position.initMargin.mul(vars.removeRate).div(1e18);

        if (isSystem) {
            vars.isTP = position.makerProfitPrice > 0 ? g.sharePrice >= position.makerProfitPrice : false;
            vars.aType = vars.isTP ? 1 : 2;
            require((g.sharePrice <= position.makerStopLossPrice) || vars.isTP, "PRL4");
        } 
        
        vars.outVol = settleLiquidity.mul(g.poolTotalTmp).div(totalSupply);
        require(balance >= vars.outVol.toInt256(), 'PRL6');
        vars.pnl = vars.outVol.toInt256().sub(vars.settleEntryValue.toInt256());
        vars.outAmount = vars.settleInitMargin.toInt256().add(vars.pnl);
        require(vars.outAmount > 0, "PRL7");

        _burn(sender, settleLiquidity);
        balanceReal = balanceReal.sub(vars.outAmount);
        vars.feeToPool = vars.outAmount.toUint256().mul(removeLiquidityFeeRate).div(RATE_PRECISION);
        vars.outAmount = vars.outAmount.sub(vars.feeToPool.toInt256());
        _vaultTransfer(sender, vars.outAmount.toUint256(), isETH);
        if (vars.feeToPool > 0) {
            IVault(vault).addPoolRmLpFeeBalance(vars.feeToPool);
            cumulateRmLiqFee = cumulateRmLiqFee.add(vars.feeToPool);
        }
        balance = balance.sub(vars.outVol.toInt256());
        position.initMargin = position.initMargin.sub(vars.settleInitMargin);
        position.liquidity = position.liquidity.sub(settleLiquidity);
        position.entryValue = position.entryValue.sub(vars.settleEntryValue);
        
        g = _checkPoolStatus(false);
        // check position status
        (vars.positionStatus, , ) = _hf(position, g.poolTotalTmp);
        require(!vars.positionStatus, "PRL8");

        _onLiquidityChanged(g.indexPrices);
        emit RemoveLiquidity(++eventId, orderId, position.maker, vars.positionId, vars.settleInitMargin, settleLiquidity, vars.settleEntryValue, vars.pnl, vars.outAmount, g.sharePrice, vars.feeToPool, g.poolTotalTmp, vars.aType);
    }

    struct LiquidateVars {
        int256 pnl;
        uint256 outValue;
        uint256 penalty;
        bool positionStatus;
    }

    /// @notice if position state is liquidation, the position will be liquidated
    /// @param positionId liquidity position id
    function liquidate(uint256 positionId) external nonReentrant _onlyRouter whenNotRemovePaused {
        LiquidateVars memory vars;
        IPool.Position storage position = makerPositions[positionId];
        require(position.liquidity > 0, "PL0");
        GlobalHf memory g = _globalInfo(false);
        _updateBorrowIG(g.allMarketPos.longMakerFreeze, g.allMarketPos.shortMakerFreeze);
        
        if (!clearAll) {
            (vars.positionStatus, vars.pnl, vars.outValue) = _hf(position, g.poolTotalTmp);
            require(vars.positionStatus, "PL1");
            vars.penalty = vars.outValue.mul(penaltyRate).div(RATE_PRECISION);
        } else {
            require(g.allMakerFreeze == 0, "PL2");
            vars.outValue = position.liquidity.mul(g.poolTotalTmp).div(totalSupply);
            vars.pnl = vars.outValue.toInt256().sub(position.entryValue.toInt256());
        }
        int256 remainAmount = position.initMargin.toInt256().add(vars.pnl);
        if (remainAmount > 0) {
            balanceReal = balanceReal.sub(remainAmount);
            if (remainAmount > vars.penalty.toInt256()) {
                remainAmount = remainAmount.sub(vars.penalty.toInt256());
            } else {
                vars.penalty = remainAmount.toUint256();
                remainAmount = 0;
            }
            if (vars.penalty > 0) _vaultTransfer(IManager(manager).riskFunding(), vars.penalty, false);
            if (remainAmount > 0) _vaultTransfer(position.maker, remainAmount.toUint256(), baseAsset == WETH);
        } else {
            // remainAmount < 0, if a liquidation shortfall occurs, the deficit needs to be distributed among all liquidity providers (LPs)
            balance = balance.add(remainAmount);
        }
        balance = balance.sub(vars.outValue.toInt256());
        _burn(position.maker, position.liquidity);

        emit Liquidate(++eventId, position.maker, positionId, position.initMargin, position.liquidity, position.entryValue, vars.pnl, remainAmount, vars.penalty, g.sharePrice, g.poolTotalTmp);

        position.liquidity = 0;
        position.initMargin = 0;
        position.entryValue = 0;
        
        if (!clearAll) {
            _checkPoolStatus(false);
        }

        _onLiquidityChanged(g.indexPrices);
    }

    /// @notice update pool data when user increasing or decreasing the position margin
    /// @param positionId liquidity position id
    /// @param addMargin add margin amount
    function addMakerPositionMargin(uint256 positionId, uint256 addMargin) external nonReentrant _onlyRouter whenNotRemovePaused {
        IPool.Position storage position = makerPositions[positionId];
        require(position.liquidity > 0 && addMargin > 0 && !clearAll, "PAM0");
        position.initMargin = position.initMargin.add(addMargin);
        balanceReal = balanceReal.add(addMargin.toInt256());
        _marginToVault(addMargin);
        require(position.entryValue.div(position.initMargin) >= minLeverage, "PAM3");
        emit AddMakerPositionMargin(++eventId, positionId, addMargin);
    }

    /// @notice add liquidity position stop loss and take profit price
    /// @param maker liquidity position maker address
    /// @param positionId liquidity position id
    /// @param tp take profit price
    /// @param sl stop loss price
    function setTPSLPrice(address maker, uint256 positionId, uint256 tp, uint256 sl) external _onlyRouter {
        IPool.Position storage position = makerPositions[positionId];
        require(!clearAll && position.maker == maker && position.liquidity > 0, "PS0");
        position.makerStopLossPrice = sl;
        position.makerProfitPrice = tp;
    }

    /// @notice if the pool is in the state of clear all, the pool will be closed and all positions will be liquidated
    function activateClearAll() external {
        (GlobalHf memory g, bool status) = _globalHf(false);
        require(status, "PAC0");
        IManager(manager).modifySingleInterestStatus(address(this), true);
        for (uint256 i = 0; i < marketList.length; i++) IManager(manager).modifySingleFundingStatus(marketList[i], true);
        clearAll = true;
        emit  ActivatedClearAll(block.timestamp, g.indexPrices);
    }
    
    /// @notice if the pool is in the state of clear all, the position is closed all, can be restarted, 
    /// should be open interest and funding
    function reStart() external _onlyController {
        require((totalSupply == 0) && clearAll, "PSP3");
        clearAll = false;
        emit ReStarted(address(this));
    }
    
    /// @notice update interests global information
    function updateBorrowIG() public {
        (DataByMarket memory allMarketPos,) = _getAllMarketData();
        _updateBorrowIG(allMarketPos.longMakerFreeze, allMarketPos.shortMakerFreeze);
    }

    /// @notice update funding global information
    function updateFundingPayment(address _market, int256 _fundingPayment) external _onlyMarket {
        if (_fundingPayment != 0) {
            DataByMarket storage marketData = poolDataByMarkets[_market];
            marketData.makerFundingPayment = marketData.makerFundingPayment.add(_fundingPayment);
        }
    }

    /// @notice update interests global information
    function setPoolParams(PoolParams memory params) external _onlyController {
        require(
            params._interestLogic != address(0)
            && params._marketPriceFeed != address(0)
            && params._mm <= RATE_PRECISION,
            "PSP0"
        );
        minAddLiquidityAmount = params._minAmount;
        minRemoveLiquidityAmount = params._minLiquidity;
        removeLiquidityFeeRate = params._ratio;
        addPaused = params._add;
        removePaused = params._remove;
        interestLogic = params._interestLogic;
        marketPriceFeed = params._marketPriceFeed;
        mm = params._mm;
        minLeverage = params._minLeverage;
        maxLeverage = params._maxLeverage;
        penaltyRate = params._penaltyRate;
        // modify market premium rate config
        MarketConfig storage args = marketConfigs[params._market];
        if (params._openRate != args.fundUtRateLimit || params._openLimit != args.openLimit || params._reserveRate != reserveRate) {
            uint256[] memory indexPrices = new uint256[](marketList.length);
            for (uint256 i = 0; i < marketList.length; i++) {
                indexPrices[i] = getPriceForPool(marketList[i], false);
            }
            _onLiquidityChanged(indexPrices);
        }
        args.fundUtRateLimit = params._openRate;
        args.openLimit = params._openLimit;
        reserveRate = params._reserveRate;
    }
    
    /// @notice if the pool liquidity is changed, will be update all market premium rate config
    /// @param indexPrices all market index price
    function _onLiquidityChanged(uint256[] memory indexPrices) internal {
        for (uint256 i = 0; i < marketList.length; i++) {
            IMarketPriceFeed(marketPriceFeed).onLiquidityChanged(address(this), marketList[i], indexPrices[i]);
        }
    }
    
    /// @notice get single position health factor 
    /// @param position liquidity position
    /// @param poolTotalTmp pool total value
    /// @return status true: position is unsafe, false: position is safe
    /// @return pnl position unrealized pnl
    /// @return currentValue position current value
    function _hf(IPool.Position memory position, uint256 poolTotalTmp) internal view returns (bool status, int256 pnl, uint256 currentValue){
        if (totalSupply == 0 || position.initMargin == 0) return (false, 0, 0);
        currentValue = position.liquidity.mul(poolTotalTmp).div(totalSupply);
        pnl = currentValue.toInt256().sub(position.entryValue.toInt256());
        status = position.initMargin.toInt256().add(pnl) <= currentValue.toInt256().mul(mm.toInt256()).div(RATE_PRECISION.toInt256());
    }
    
    /// @notice get pool health factor, status true: pool is unsafe, false: pool is safe
    /// @param isAdd true: add liquidity or show tvl, false: rm liquidity
    function _globalHf(bool isAdd) internal view returns (GlobalHf memory g, bool status){
        g = _globalInfo(isAdd);
        int256 tempTotalLockedFund = balanceReal.add(g.allMarketPos.takerTotalMargin.toInt256());
        int256 totalAvailableFund = balanceReal.add(g.poolInterest.toInt256()).add(g.totalUnPNL).add(g.allMarketPos.makerFundingPayment) - g.poolTotalTmp.mul(mm).div(RATE_PRECISION).toInt256();
        totalAvailableFund = totalAvailableFund > tempTotalLockedFund? tempTotalLockedFund : totalAvailableFund;
        status = totalAvailableFund < 0;
    }
    
    function _checkPoolStatus(bool isAdd) internal view returns (GlobalHf memory g){
        bool status;
        (g, status) = _globalHf(isAdd);
        require(!status, "PCP0");
    }
    
    function _checkPoolPnlStatus(GlobalHf memory g) internal view{
        if (totalSupply > 0) require((g.totalUnPNL.add(g.allMarketPos.makerFundingPayment).add(g.poolInterest.toInt256()) <= g.allMarketPos.takerTotalMargin.toInt256()) && (g.totalUnPNL.neg256().sub(g.allMarketPos.makerFundingPayment) <= g.allMakerFreeze.toInt256()), 'PCPP0');
    }

    function _globalInfo(bool isAdd) internal view returns (GlobalHf memory g){
        (g.allMarketPos, g.allMakerFreeze) = _getAllMarketData();
        g.poolInterest = _calcPooInterest(g.allMarketPos.longMakerFreeze, g.allMarketPos.shortMakerFreeze);
        (g.totalUnPNL, g.indexPrices) = _makerProfitForLiquidity(isAdd);
        int256 poolTotal = balance.add(g.allMakerFreeze.toInt256()).add(g.totalUnPNL).add(g.allMarketPos.makerFundingPayment).add(g.poolInterest.toInt256());
        g.poolTotalTmp = poolTotal < 0 ? 0 : poolTotal.toUint256();
        g.sharePrice = totalSupply == 0 ? PRICE_PRECISION : g.poolTotalTmp.mul(PRICE_PRECISION).mul(10 ** decimals).div(totalSupply).div(10 ** baseAssetDecimals);
    }
    
    /// @notice  calculate unrealized pnl of positions in all markets caused by price changes
    /// @param isAdd true: add liquidity or show tvl, false: rm liquidity
    function _makerProfitForLiquidity(bool isAdd) internal view returns (int256 unPNL, uint256[] memory indexPrices){
        indexPrices = new uint256[](marketList.length);
        for (uint256 i = 0; i < marketList.length; i++) {
            (int256 singleMarketPnl, uint256 indexPrice) = _makerProfitByMarket(marketList[i], isAdd);
            unPNL = unPNL.add(singleMarketPnl);
            indexPrices[i] = indexPrice;
        }
    }

    /// @notice calculate unrealized pnl of positions in one single market caused by price changes
    /// @param _market market address
    /// @param _isAdd true: add liquidity or show tvl, false: rm liquidity
    function _makerProfitByMarket(address _market, bool _isAdd) internal view returns (int256 unPNL, uint256 _price){
        DataByMarket storage marketData = poolDataByMarkets[_market];
        MarketConfig memory args = marketConfigs[_market];
        _price = getPriceForPool(_market, _isAdd ? marketData.longAmount < marketData.shortAmount : marketData.longAmount >= marketData.shortAmount);

        if (args.marketType == 1) {
            unPNL = marketData.longAmount.toInt256().sub(marketData.shortAmount.toInt256()).mul(PRICE_PRECISION.toInt256()).div(_price.toInt256());
            unPNL = unPNL.add(marketData.shortOpenTotal.toInt256()).sub(marketData.longOpenTotal.toInt256());
        } else {
            unPNL = marketData.shortAmount.toInt256().sub(marketData.longAmount.toInt256()).mul(_price.toInt256()).div(PRICE_PRECISION.toInt256());
            unPNL = unPNL.add(marketData.longOpenTotal.toInt256()).sub(marketData.shortOpenTotal.toInt256());
            if (args.marketType == 2) {
                unPNL = unPNL.mul((IMarket(_market).getMarketConfig().multiplier).toInt256()).div(RATE_PRECISION.toInt256());
            }
        }
        unPNL = unPNL.mul((10 ** baseAssetDecimals).toInt256()).div(AMOUNT_PRECISION.toInt256());
    }

    /// @notice update interest index global
    /// @param _longMakerFreeze sum of pool assets taken by the long positions
    /// @param _shortMakerFreeze sum of pool assets taken by the short positions
    function _updateBorrowIG(uint256 _longMakerFreeze, uint256 _shortMakerFreeze) internal {
        (, interestData[1].borrowIG) = _getCurrentBorrowIG(1, _longMakerFreeze, _shortMakerFreeze);
        (, interestData[- 1].borrowIG) = _getCurrentBorrowIG(- 1, _longMakerFreeze, _shortMakerFreeze);
        interestData[1].lastInterestUpdateTs = block.timestamp;
        interestData[- 1].lastInterestUpdateTs = block.timestamp;
    }
    
    /// @notice calculate the latest interest index global
    /// @param _direction position direction
    /// @param _longMakerFreeze sum of pool assets taken by the long positions
    /// @param _shortMakerFreeze sum of pool assets taken by the short positions
    function _getCurrentBorrowIG(int8 _direction, uint256 _longMakerFreeze, uint256 _shortMakerFreeze) internal view returns (uint256 _borrowRate, uint256 _borrowIG){
        require(_direction == 1 || _direction == - 1, "PGC0");
        IPool.InterestData memory data = interestData[_direction];

        // calc util need usedBalance,totalBalance,reserveRate
        //(DataByMarket memory allMarketPos, uint256 allMakerFreeze) = _getAllMarketData();
        uint256 usedBalance = _direction == 1 ? _longMakerFreeze : _shortMakerFreeze;
        uint256 totalBalance = balance.add(_longMakerFreeze.toInt256()).add(_shortMakerFreeze.toInt256()).toUint256();

        (_borrowRate, _borrowIG) = IInterestLogic(interestLogic).getMarketBorrowIG(address(this), usedBalance, totalBalance, reserveRate, data.lastInterestUpdateTs, data.borrowIG);
    }

    function _getCurrentAmount(int8 _direction, uint256 share, uint256 _longMakerFreeze, uint256 _shortMakerFreeze) internal view returns (uint256){
        (,uint256 ig) = _getCurrentBorrowIG(_direction, _longMakerFreeze, _shortMakerFreeze);
        return IInterestLogic(interestLogic).getBorrowAmount(share, ig).mul(10 ** baseAssetDecimals).div(AMOUNT_PRECISION);
    }

    /// @notice calculate the sum data of all markets
    function _getAllMarketData() internal view returns (DataByMarket memory allMarketPos, uint256 allMakerFreeze){
        for (uint256 i = 0; i < marketList.length; i++) {
            address market = marketList[i];
            DataByMarket memory marketData = poolDataByMarkets[market];

            allMarketPos.rlzPNL = allMarketPos.rlzPNL.add(marketData.rlzPNL);
            allMarketPos.cumulativeFee = allMarketPos.cumulativeFee.add(marketData.cumulativeFee);
            allMarketPos.longMakerFreeze = allMarketPos.longMakerFreeze.add(marketData.longMakerFreeze);
            allMarketPos.shortMakerFreeze = allMarketPos.shortMakerFreeze.add(marketData.shortMakerFreeze);
            allMarketPos.takerTotalMargin = allMarketPos.takerTotalMargin.add(marketData.takerTotalMargin);
            allMarketPos.makerFundingPayment = allMarketPos.makerFundingPayment.add(marketData.makerFundingPayment);
            allMarketPos.longOpenTotal = allMarketPos.longOpenTotal.add(marketData.longOpenTotal);
            allMarketPos.shortOpenTotal = allMarketPos.shortOpenTotal.add(marketData.shortOpenTotal);
        }

        allMakerFreeze = allMarketPos.longMakerFreeze.add(allMarketPos.shortMakerFreeze);
    }

    /// @notice get interest of this pool
    /// @return result the interest principal not included
    function _calcPooInterest(uint256 _longMakerFreeze, uint256 _shortMakerFreeze) internal view returns (uint256){
        uint256 longShare = interestData[1].totalBorrowShare;
        uint256 shortShare = interestData[- 1].totalBorrowShare;
        uint256 longInterest = _getCurrentAmount(1, longShare, _longMakerFreeze, _shortMakerFreeze);
        uint256 shortInterest = _getCurrentAmount(- 1, shortShare, _longMakerFreeze, _shortMakerFreeze);
        longInterest = longInterest <= _longMakerFreeze ? 0 : longInterest.sub(_longMakerFreeze);
        shortInterest = shortInterest <= _shortMakerFreeze ? 0 : shortInterest.sub(_shortMakerFreeze);
        return longInterest.add(shortInterest);
    }

    /// @notice get market open limit
    /// @param _market market address
    /// @return openLimitFunds the max funds used to open
    function _getMarketLimit(address _market, uint256 _allMakerFreeze) internal view returns (uint256 openLimitFunds){
        MarketConfig memory args = marketConfigs[_market];
        uint256 availableAmount = balance.add(_allMakerFreeze.toInt256()).toUint256().mul(RATE_PRECISION.sub(reserveRate)).div(RATE_PRECISION);
        uint256 openLimitByRatio = availableAmount.mul(args.fundUtRateLimit).div(RATE_PRECISION);
        openLimitFunds = openLimitByRatio > args.openLimit ? args.openLimit : openLimitByRatio;
    }
    
    function getCurrentAmount(int8 _direction, uint256 share) public view returns (uint256){
        (DataByMarket memory allMarketPos,) = _getAllMarketData();
        return _getCurrentAmount(_direction, share, allMarketPos.longMakerFreeze, allMarketPos.shortMakerFreeze);
    }

    function getCurrentShare(int8 _direction, uint256 amount) external view returns (uint256){
        (DataByMarket memory allMarketPos,) = _getAllMarketData();
        (,uint256 ig) = _getCurrentBorrowIG(_direction, allMarketPos.longMakerFreeze, allMarketPos.shortMakerFreeze);
        return IInterestLogic(interestLogic).getBorrowShare(amount.mul(AMOUNT_PRECISION).div(10 ** baseAssetDecimals), ig);
    }

    /// @notice get the fund utilization information of a market
    /// @param _market market address
    function getMarketAmount(address _market) external view returns (uint256, uint256, uint256){
        DataByMarket memory marketData = poolDataByMarkets[_market];
        (,uint256 allMakerFreeze) = _getAllMarketData();
        uint256 openLimitFunds = _getMarketLimit(_market, allMakerFreeze);
        return (marketData.longAmount, marketData.shortAmount, openLimitFunds);
    }

    /// @notice get current borrowIG
    /// @param _direction position direction
    function getCurrentBorrowIG(int8 _direction) public view returns (uint256 _borrowRate, uint256 _borrowIG){
        (DataByMarket memory allMarketPos,) = _getAllMarketData();
        return _getCurrentBorrowIG(_direction, allMarketPos.longMakerFreeze, allMarketPos.shortMakerFreeze);
    }

    /// @notice validate whether this open order can be executed
    ///         every market open interest is limited by two params, the open limit and the funding utilization rate limit
    /// @param _market market address
    /// @param _makerMargin margin taken from the pool of this order
    function canOpen(address _market, uint256 _makerMargin) public view returns (bool _can){
        // balance - margin >= (balance + frozen) * reserveRatio
        // => balance >= margin + (balance + frozen) * reserveRatio >= margin
        // when reserve ratio == 0  => balance >= margin

        (,uint256 allMakerFreeze) = _getAllMarketData();
        uint256 reserveAmount = balance.add(allMakerFreeze.toInt256()).toUint256().mul(reserveRate).div(RATE_PRECISION);
        if (balance < reserveAmount.add(_makerMargin).toInt256()) {
            return false;
        }

        uint256 openLimitFunds = _getMarketLimit(_market, allMakerFreeze);
        DataByMarket memory marketData = poolDataByMarkets[_market];
        uint256 marketUsedFunds = marketData.longMakerFreeze.add(marketData.shortMakerFreeze).add(_makerMargin);
        return marketUsedFunds <= openLimitFunds;
    }

    /// @notice get pool total status
    /// @return status true: pool is unsafe, false: pool is safe
    /// @return poolTotalTmp pool total valuation
    /// @return totalUnPNL total unrealized pnl of all positions
    function globalHf() public view returns (bool status, uint256 poolTotalTmp, int256 totalUnPNL){
        GlobalHf memory g;
        (g, status) = _globalHf(false);
        poolTotalTmp = g.poolTotalTmp;
        totalUnPNL = g.totalUnPNL;
    }

    /// @notice get index price to calculate the pool unrealized pnl
    /// @param _market market address
    /// @param _maximise should maximise the price
    function getPriceForPool(address _market, bool _maximise) internal view returns (uint256){
        return IMarketPriceFeed(marketPriceFeed).priceForPool(IMarket(_market).token(), _maximise);
    }
    
    /// @notice get all markets
    function getMarketList() external view returns (address[] memory){
        return marketList;
    }

    /// @notice get asset of pool
    function getBaseAsset() public view returns (address){
        return baseAsset;
    }
}
