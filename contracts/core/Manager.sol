// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "../libraries/SafeMath.sol";
import "../interfaces/IMarket.sol";
import "../interfaces/IPool.sol";
import "../interfaces/IMarketLogic.sol";

contract Manager {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 constant RATE_PRECISION = 1e6;          // rate decimal 1e6

    address public controller;      //controller, can change all config params
    address public router;          //router address
    address public executorRouter;  //executor router address
    address public vault;           //vault address
    address public riskFunding;     //riskFunding address
    address public inviteManager;   //inviteManager address
    address public marketPriceFeed; //marketPriceFeed address
    address public marketLogic;     //marketLogic address

    uint256 public executeOrderFee = 0.0001 ether;          // execution fee of one order
    // singer  => type =>isOpen
    mapping(address => mapping(uint8 => bool)) signers;     // signers are qualified addresses to execute orders and update off-chain price {0:backup price;1:pyth price;2:data stream}
    mapping(address => mapping(uint8 => bool)) executors;   // liquidators are qualified addresses to liquidate positions {0:market order executor;1:limit order executor;2:liquidity order executor;3:tp,sl,system tp executor}
    mapping(address => bool) treasurers;                    // vault administrators

    uint256 public communityExecuteOrderDelay;              // time elapse after that every one can execute orders
    uint256 public cancelElapse;                            // time elapse after that user can cancel not executed orders
    uint256 public triggerOrderDuration;                    // validity period of trigger orders

    bool public paused = true;                              // protocol pause flag
    mapping(address => bool) public isFundingPaused;        // funding mechanism pause flag, market => bool
    mapping(address => bool) public isInterestPaused;       // interests mechanism pause flag, pool => bool

    mapping(address => address) public getMakerByMarket;        // mapping of market to pool, market => pool
    mapping(address => address) public getMarketMarginAsset;    // mapping of market to base asset, market => base asset
    mapping(address => address) public getPoolBaseAsset;        // mapping of base asset and pool
    EnumerableSet.AddressSet internal markets;                  // enumerate of all markets
    EnumerableSet.AddressSet internal pools;                    // enumerate of all pools

    uint256 public orderNumLimit;                               //taker open order number limit

    event MarketCreated(address market, address pool, string indexToken, address marginAsset, uint8 marketType);
    event SignerModified(address signer, uint8 sType, bool isOpen);
    event Pause(bool paused);
    event Unpause(bool paused);
    event OrderNumLimitModified(uint256 _limit);
    event RouterModified(address _router);
    event ExecutorRouterModified(address _executorRouter);
    event ControllerModified(address _controller);
    event VaultModified(address _vault);
    event RiskFundingModified(address _riskFunding);
    event ExecuteOrderFeeModified(uint256 _feeToPriceProvider);
    event ExecuteOrderFeeOwnerModified(address _feeOwner);
    event InviteManagerModified(address _referralManager);
    event MarketPriceFeedModified(address _marketPriceFeed);
    event MarketLogicModified(address _marketLogic);
    event CancelElapseModified(uint256 _cancelElapse);
    event CommunityExecuteOrderDelayModified(uint256 _communityExecuteOrderDelay);
    event TriggerOrderDurationModified(uint256 triggerOrderDuration);
    event InterestStatusModified(address pool, bool _interestPaused);
    event FundingStatusModified(address market, bool _fundingPaused);
    event TreasurerModified(address _treasurer, bool _isOpen);
    event ExecutorModified(address _liquidator, uint8 eType, bool _isOpen);
    event ControllerInitialized(address _controller);

    modifier onlyController{
        require(msg.sender == controller, "Manager:only controller");
        _;
    }

    constructor(address _controller) {
        require(_controller != address(0), "Manager:address zero");
        controller = _controller;
        emit ControllerModified(controller);
    }

    /// @notice  pause the protocol
    function pause() external onlyController {
        require(!paused, "Manager:already paused");
        paused = true;
        emit Pause(paused);
    }

    /// @notice unpause the protocol
    function unpause() external onlyController {
        require(paused, "Manager:not paused");
        paused = false;
        emit Unpause(paused);
    }

    /// @notice modify executor
    /// @param _executor liquidator address
    /// @param eType executor type {0:market order executor;1:limit order executor;2:liquidity order executor;3:tp,sl,system tp executor}
    /// @param isOpen true open ;false close
    function modifyExecutor(address _executor, uint8 eType, bool isOpen) external onlyController {
        require(_executor != address(0), "Manager:address error");
        executors[_executor][eType] = isOpen;
        emit ExecutorModified(_executor, eType, isOpen);
    }

    /// @notice modify treasurer address
    /// @param _treasurer treasurer address
    /// @param _isOpen true open ;false close
    function modifyTreasurer(address _treasurer, bool _isOpen) external onlyController {
        require(_treasurer != address(0), "Manager:address error");
        treasurers[_treasurer] = _isOpen;
        emit TreasurerModified(_treasurer, _isOpen);
    }

    /// @notice modify order num limit of market
    /// @param _limit order num limit
    function modifyOrderNumLimit(uint256 _limit) external onlyController {
        require(_limit > 0, "Manager:limit error");
        orderNumLimit = _limit;
        emit OrderNumLimitModified(_limit);
    }

    /// @notice modify router address
    /// @param _router router address
    function modifyRouter(address _router) external onlyController {
        //        require(router == address(0), "router already notify");
        require(_router != address(0), "Manager:address zero");
        router = _router;
        emit RouterModified(_router);
    }

    /// @notice modify executor router address
    /// @param _executorRouter executor router address
    function modifyExecutorRouter(address _executorRouter) external onlyController {
        require(_executorRouter != address(0), "Manager:address zero");
        executorRouter = _executorRouter;
        emit ExecutorRouterModified(_executorRouter);
    }

    /// @notice add a signer address
    /// @param signer signer address
    /// @param sType signer type {0:backup price;1:pyth price;2:data stream price}
    /// @param isOpen true open ;false close
    function modifySigner(address signer, uint8 sType, bool isOpen) external onlyController {
        require(signer != address(0), "Manager:address zero");
        signers[signer][sType] = isOpen;
        emit SignerModified(signer, sType, isOpen);
    }

    /// @notice modify controller address
    /// @param _controller controller address
    function modifyController(address _controller) external onlyController {
        require(_controller != address(0), "Manager:address zero");
        controller = _controller;
        emit ControllerModified(_controller);
    }

    /// @notice modify price provider fee owner address
    /// @param _riskFunding risk funding address
    function modifyRiskFunding(address _riskFunding) external onlyController {
        require(_riskFunding != address(0), "Manager:address zero");
        riskFunding = _riskFunding;
        emit RiskFundingModified(_riskFunding);
    }

    /// @notice activate or deactivate the interests module
    /// @param _interestPaused true:interest paused;false:interest not paused
    function modifySingleInterestStatus(address pool, bool _interestPaused) external {
        require((msg.sender == controller) || (EnumerableSet.contains(pools, msg.sender)), "Manager:only controller or pool");
        //update interest growth global
        IPool(pool).updateBorrowIG();
        isInterestPaused[pool] = _interestPaused;

        emit InterestStatusModified(pool, _interestPaused);
    }

    /// @notice activate or deactivate
    /// @param _fundingPaused true:funding paused;false:funding not paused
    function modifySingleFundingStatus(address market, bool _fundingPaused) external {
        require((msg.sender == controller) || (EnumerableSet.contains(pools, msg.sender)), "Manager:only controller or pool");
        //update funding growth global
        IMarket(market).updateFundingGrowthGlobal();
        isFundingPaused[market] = _fundingPaused;

        emit FundingStatusModified(market, _fundingPaused);
    }

    /// @notice modify vault address
    /// @param _vault vault address
    function modifyVault(address _vault) external onlyController {
        require(_vault != address(0), "Manager:address zero");
        vault = _vault;
        emit VaultModified(_vault);
    }

    /// @notice modify price provider fee
    /// @param _fee price provider fee
    function modifyExecuteOrderFee(uint256 _fee) external onlyController {
        executeOrderFee = _fee;
        emit ExecuteOrderFeeModified(_fee);
    }

    /// @notice modify invite manager address
    /// @param _inviteManager invite manager address
    function modifyInviteManager(address _inviteManager) external onlyController {
        inviteManager = _inviteManager;
        emit InviteManagerModified(_inviteManager);
    }

    /// @notice modify market Price Feed address
    /// @param _marketPriceFeed market Price Feed address
    function modifyMarketPriceFeed(address _marketPriceFeed) external onlyController {
        marketPriceFeed = _marketPriceFeed;
        emit MarketPriceFeedModified(_marketPriceFeed);
    }

    /// @notice modify market logic address
    /// @param _marketLogic market logic address
    function modifyMarketLogic(address _marketLogic) external onlyController {
        marketLogic = _marketLogic;
        emit MarketLogicModified(_marketLogic);
    }

    /// @notice modify cancel time elapse
    /// @param _cancelElapse cancel time elapse
    function modifyCancelElapse(uint256 _cancelElapse) external onlyController {
        require(_cancelElapse > 0, "Manager:_cancelElapse zero");
        cancelElapse = _cancelElapse;
        emit CancelElapseModified(_cancelElapse);
    }

    /// @notice modify community execute order delay time
    /// @param _communityExecuteOrderDelay execute time elapse
    function modifyCommunityExecuteOrderDelay(uint256 _communityExecuteOrderDelay) external onlyController {
        require(_communityExecuteOrderDelay > 0, "Manager:_communityExecuteOrderDelay zero");
        communityExecuteOrderDelay = _communityExecuteOrderDelay;
        emit CommunityExecuteOrderDelayModified(_communityExecuteOrderDelay);
    }

    /// @notice modify the trigger order validity period
    /// @param _triggerOrderDuration trigger order time dead line
    function modifyTriggerOrderDuration(uint256 _triggerOrderDuration) external onlyController {
        require(_triggerOrderDuration > 0, "Manager: time duration should > 0");
        triggerOrderDuration = _triggerOrderDuration;
        emit TriggerOrderDurationModified(_triggerOrderDuration);
    }

    /// @notice validate whether an address is a signer
    /// @param signer signer address
    /// @param sType signer type {0:backup price;1:pyth price;2:data stream price}
    function checkSigner(address signer, uint8 sType) external view returns (bool) {
        return signers[signer][sType];
    }

    /// @notice validate whether an address is a treasurer
    /// @param _treasurer treasurer address
    function checkTreasurer(address _treasurer) external view returns (bool) {
        return treasurers[_treasurer];
    }

    /// @notice validate whether an address is a liquidator
    /// @param _executor executor address
    /// @param _eType executor type {0:market order executor;1:limit order executor;2:liquidity order executor;3:tp,sl,system tp executor}
    function checkExecutor(address _executor, uint8 _eType) external view returns (bool) {
        return executors[_executor][_eType];
    }

    /// @notice validate whether an address is a controller
    function checkController(address _controller) view external returns (bool) {
        return _controller == controller;
    }

    /// @notice validate whether an address is the router
    function checkRouter(address _router) external view returns (bool) {
        return _router == router;
    }

    /// @notice validate whether an address is the executor router
    function checkExecutorRouter(address _executorRouter) external view returns (bool) {
        return executorRouter == _executorRouter;
    }

    /// @notice validate whether an address is a legal market address
    function checkMarket(address _market) external view returns (bool) {
        return getMarketMarginAsset[_market] != address(0);
    }

    /// @notice validate whether an address is a legal pool address
    function checkPool(address _pool) external view returns (bool) {
        return getPoolBaseAsset[_pool] != address(0);
    }

    /// @notice validate whether an address is a legal logic address
    function checkMarketLogic(address _logic) external view returns (bool) {
        return marketLogic == _logic;
    }

    /// @notice validate whether an address is a legal market price feed address
    function checkMarketPriceFeed(address _feed) external view returns (bool) {
        return marketPriceFeed == _feed;
    }

    /// @notice create pair ,only controller can call
    /// @param pool pool address
    /// @param market market address
    /// @param token save price key
    /// @param marketType market type
    function createPair(
        address pool,
        address market,
        string memory token,
        uint8 marketType,
        MarketDataStructure.MarketConfig memory _config
    ) external onlyController {
        require(bytes(token).length != 0, 'Manager:indexToken is address(0)');
        require(marketType == 0 || marketType == 1 || marketType == 2, 'Manager:marketType error');
        require(pool != address(0) && market != address(0), 'Manager:market and maker is not address(0)');
        require(getMakerByMarket[market] == address(0), 'Manager:maker already exist');

        getMakerByMarket[market] = pool;
        address asset = IPool(pool).getBaseAsset();
        if (getPoolBaseAsset[pool] == address(0)) {
            getPoolBaseAsset[pool] = asset;
        }
        require(getPoolBaseAsset[pool] == asset, 'Manager:pool base asset error');
        getMarketMarginAsset[market] = asset;

        isFundingPaused[market] = true;

        EnumerableSet.add(markets, market);
        if (!EnumerableSet.contains(pools, pool)) {
            EnumerableSet.add(pools, pool);
            isInterestPaused[pool] = true;
        }
        IMarket(market).initialize(token, asset, pool, marketType);
        IPool(pool).registerMarket(market);

        setMarketConfig(market, _config);
        //let cfg =[[0,0],[4000000,50000],[8000000,100000],[10000000,150000],[12000000,200000],[20000000,600000],[100000000,10000000]]

        emit MarketCreated(market, pool, token, asset, marketType);
    }

    /// @notice set general market configurations, only controller can call
    /// @param _config configuration parameters
    function setMarketConfig(address market, MarketDataStructure.MarketConfig memory _config) public onlyController {
        uint8 marketType = IMarket(market).marketType();
        require(_config.makerFeeRate < RATE_PRECISION, "MSM0");
        require(_config.tradeFeeRate < RATE_PRECISION, "MSM1");
        require(marketType == 2 ? _config.multiplier > 0 : true, "MSM2");
        require(_config.takerLeverageMin > 0 && _config.takerLeverageMin < _config.takerLeverageMax, "MSM3");
        require(_config.mm > 0 && _config.mm < SafeMath.div(RATE_PRECISION, _config.takerLeverageMax), "MSM4");
        require(_config.takerMarginMin > 0 && _config.takerMarginMin < _config.takerMarginMax, "MSM5");
        require(_config.takerValueMin > 0 && _config.takerValueMin < _config.takerValueMax, "MSM6");

        IMarket(market).setMarketConfig(_config);
    }

    /// @notice modify the pause status for creating an order of a market
    /// @param market market address
    /// @param _paused paused or not
    function modifyMarketCreateOrderPaused(address market, bool _paused) public onlyController {
        MarketDataStructure.MarketConfig memory _config = IMarket(market).getMarketConfig();
        _config.createOrderPaused = _paused;
        setMarketConfig(market, _config);
    }

    /// @notice modify the status for setting tpsl for an position
    /// @param market market address
    /// @param _paused paused or not
    function modifyMarketTPSLPricePaused(address market, bool _paused) public onlyController {
        MarketDataStructure.MarketConfig memory _config = IMarket(market).getMarketConfig();
        _config.setTPSLPricePaused = _paused;
        setMarketConfig(market, _config);
    }

    /// @notice modify the pause status for creating a trigger order
    /// @param market market address
    /// @param _paused paused or not
    function modifyMarketCreateTriggerOrderPaused(address market, bool _paused) public onlyController {
        MarketDataStructure.MarketConfig memory _config = IMarket(market).getMarketConfig();
        _config.createTriggerOrderPaused = _paused;
        setMarketConfig(market, _config);
    }

    /// @notice modify the pause status for updating the position margin
    /// @param market market address
    /// @param _paused paused or not
    function modifyMarketUpdateMarginPaused(address market, bool _paused) public onlyController {
        MarketDataStructure.MarketConfig memory _config = IMarket(market).getMarketConfig();
        _config.updateMarginPaused = _paused;
        setMarketConfig(market, _config);
    }

    /// @notice get all markets
    function getAllMarkets() external view returns (address[] memory) {
        address[] memory _markets = new address[](EnumerableSet.length(markets));
        for (uint256 i = 0; i < EnumerableSet.length(markets); i++) {
            _markets[i] = EnumerableSet.at(markets, i);
        }
        return _markets;
    }

    /// @notice get all poolss
    function getAllPools() external view returns (address[] memory) {
        address[] memory _pools = new address[](EnumerableSet.length(pools));
        for (uint256 i = 0; i < EnumerableSet.length(pools); i++) {
            _pools[i] = EnumerableSet.at(pools, i);
        }
        return _pools;
    }
}
