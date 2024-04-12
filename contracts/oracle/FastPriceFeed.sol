// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import "../libraries/PythStructs.sol";
import "../libraries/SafeMath.sol";
import "../libraries/Common.sol";
import "../libraries/TransferHelper.sol";
import "../interfaces/IManager.sol";
import "../interfaces/IMarketPriceFeed.sol";
import "../interfaces/IFeeManager.sol";
import "../interfaces/IVerifierProxy.sol";
import "../interfaces/IFastPriceFeed.sol";
import "../interfaces/IPyth.sol";
import "../interfaces/IWrappedCoin.sol";

contract FastPriceFeed {
    using SafeMath for uint256;
    using SafeMath for uint32;

    uint256 public constant MAX_REF_PRICE = type(uint160).max;//max chainLink price
    uint256 public constant MAX_CUMULATIVE_REF_DELTA = type(uint32).max;//max cumulative chainLink price delta
    uint256 public constant MAX_CUMULATIVE_FAST_DELTA = type(uint32).max;//max cumulative fast price delta
    uint256 public constant CUMULATIVE_DELTA_PRECISION = 10 * 1000 * 1000;//cumulative delta precision
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;//basis points divisor
    uint256 public constant MAX_PRICE_DURATION = 30 minutes;//max price validity period 
    uint256 public constant PRICE_PRECISION = 10 ** 10;//price precision

    // fit data in a uint256 slot to save gas costs
    struct PriceDataItem {
        uint160 refPrice; // ChainLink price
        uint32 refTime; // last ChainLink price updated at time
        uint32 cumulativeRefDelta; // cumulative ChainLink price delta
        uint32 cumulativeFastDelta; // cumulative fast price delta
    }

    mapping(string => PriceDataItem) public priceData;//chainLink price data
    mapping(string => uint256) public prices;//offChain price data
    mapping(string => uint32) lastUpdatedAts;//last offChain price update time
    uint256 public lastUpdatedBlock;//last offChain price update block
    mapping(string => uint256) public maxCumulativeDeltaDiffs;//max cumulative delta diff,delta = (cumulativeFastDelta - cumulativeRefDelta)

    // should be 10 ** 8
    string[] public tokens;//index token
    mapping(bytes32 => string) public feedIds;
    mapping(bytes32 => string) public pythFeedIds;
    mapping(string => uint256) public backUpPricePrecisions;
    mapping(string => uint256) public primaryPricePrecisions;

    bool public isInitialized;//is initialized,only can be initialized once
    address public marketPriceFeed;//marketPriceFeed address

    //max diff between chainLink price and offChain price,if diff > maxDeviationBasisPoints then use chainLink price or offChain price
    uint256 public maxDeviationBasisPoints;
    //max diff between chainLink price and offChain price,if diff > maxDeviationBasisPoints then use chainLink price 
    uint256 public indexMaxDeviationBasisPoints;
    uint256 public priceDuration;//offChain validity period tradePrice,if delay > priceDuration then use chainLink price with 0.2% spreadBasisPoints 
    uint256 public indexPriceDuration;//offChain validity period for indexPrice
    //max offChain price update delay,if delay > maxPriceUpdateDelay then use chainLink price with 5% spreadBasisPoints 
    uint256 public maxPriceUpdateDelay;
    uint256 public spreadBasisPointsIfInactive = 20;
    uint256 public spreadBasisPointsIfChainError = 500;
    uint256 public minBlockInterval; //min block interval between two offChain price update
    uint256 public maxTimeDeviation = 3600;//max time deviation between offChain price update time and block timestamp
    uint256 public priceDataInterval = 60;//cumulative delta interval
    bool public isSpreadEnabled = false;//is spread enabled
    address public manager;

    address public WETH;
    IVerifierProxy public verifier;
    IPyth public pyth;
    uint256 public maxPriceTsDiff;//max price timestamp diff

    struct PremiumReport {
        bytes32 feedId; // The feed ID the report has data for
        uint32 validFromTimestamp; // Earliest timestamp for which price is applicable
        uint32 observationsTimestamp; // Latest timestamp for which price is applicable
        uint192 nativeFee; // Base cost to validate a transaction using the report, denominated in the chain’s native token (WETH/ETH)
        uint192 linkFee; // Base cost to validate a transaction using the report, denominated in LINK
        uint64 expiresAt; // Latest timestamp where the report can be verified on-chain
        int192 price; // DON consensus median price, carried to 8 decimal places
        int192 bid; // Simulated price impact of a buy order up to the X% depth of liquidity utilisation
        int192 ask; // Simulated price impact of a sell order up to the X% depth of liquidity utilisation
    }

    event PriceData(string token, uint256 refPrice, uint256 fastPrice, uint256 cumulativeRefDelta, uint256 cumulativeFastDelta);
    event MaxCumulativeDeltaDiffExceeded(string token, uint256 refPrice, uint256 fastPrice, uint256 cumulativeRefDelta, uint256 cumulativeFastDelta);
    event PriceUpdated(string _token, uint256 _price);
    event SetMarketPriceFeed(address _marketPriceFeed);
    event SetMaxTimeDeviation(uint256 _maxTimeDeviation);
    event SetPriceDuration(uint256 _priceDuration, uint256 _indexPriceDuration);
    event SetMaxPriceUpdateDelay(uint256 _maxPriceUpdateDelay);
    event SetMinBlockInterval(uint256 _minBlockInterval);
    event SetMaxDeviationBasisPoints(uint256 _maxDeviationBasisPoints);
    event SetSpreadBasisPointsIfInactive(uint256 _spreadBasisPointsIfInactive);
    event SetSpreadBasisPointsIfChainError(uint256 _spreadBasisPointsIfChainError);
    event SetPriceDataInterval(uint256 _priceDataInterval);
    event SetVerifier(IVerifierProxy verifier);
    event SetIsSpreadEnabled(bool _isSpreadEnabled);
    event SetTokens(string[] _tokens, bytes32[] _feedIds, bytes32[] _pythFeedIds, uint256[] _backUpPricePrecisions, uint256[] _primaryPricePrecisions);
    event SetLastUpdatedAt(string token, uint256 lastUpdatedAt);
    event SetMaxCumulativeDeltaDiff(string token, uint256 maxCumulativeDeltaDiff);
    event fallbackCalled(address sender, uint256 value, bytes data);
    event SetPyth(IPyth _pyth);
    event SetMaxPriceTsDiff(uint256 _maxPriceTsDiff);

    modifier onlyExecutorRouter() {
        require(IManager(manager).checkExecutorRouter(msg.sender), "FastPriceFeed: forbidden");
        _;
    }

    modifier onlyController() {
        require(IManager(manager).checkController(msg.sender), "FastPriceFeed: Must be controller");
        _;
    }

    modifier onlyTreasurer() {
        require(IManager(manager).checkTreasurer(msg.sender), "FastPriceFeed: Must be treasurer");
        _;
    }

    constructor(
        address _WETH,
        address _manager,
        uint256 _priceDuration,
        uint256 _indexPriceDuration,
        uint256 _maxPriceUpdateDelay,
        uint256 _minBlockInterval,
        uint256 _maxDeviationBasisPoints,
        uint256 _indexMaxDeviationBasisPoints
    ) {
        require(_priceDuration <= MAX_PRICE_DURATION, "FastPriceFeed: invalid _priceDuration");
        require(_indexPriceDuration <= MAX_PRICE_DURATION, "FastPriceFeed: invalid _indexPriceDuration");
        require(_manager != address(0) && _WETH != address(0), "FastPriceFeed: invalid address");
        WETH = _WETH;
        manager = _manager;
        priceDuration = _priceDuration;
        maxPriceUpdateDelay = _maxPriceUpdateDelay;
        minBlockInterval = _minBlockInterval;
        maxDeviationBasisPoints = _maxDeviationBasisPoints;
        indexMaxDeviationBasisPoints = _indexMaxDeviationBasisPoints;
        indexPriceDuration = _indexPriceDuration;
    }

    function setMarketPriceFeed(address _marketPriceFeed) external onlyController {
        require(_marketPriceFeed != address(0), "FastPriceFeed: invalid _marketPriceFeed");
        marketPriceFeed = _marketPriceFeed;
        emit SetMarketPriceFeed(_marketPriceFeed);
    }

    function setMaxTimeDeviation(uint256 _maxTimeDeviation) external onlyController {
        maxTimeDeviation = _maxTimeDeviation;
        emit SetMaxTimeDeviation(_maxTimeDeviation);
    }

    function setPriceDuration(uint256 _priceDuration, uint256 _indexPriceDuration) external onlyController {
        require(_priceDuration <= MAX_PRICE_DURATION, "FastPriceFeed: invalid _priceDuration");
        require(_indexPriceDuration <= MAX_PRICE_DURATION, "FastPriceFeed: invalid _indexPriceDuration");
        priceDuration = _priceDuration;
        indexPriceDuration = _indexPriceDuration;
        emit SetPriceDuration(_priceDuration, _indexPriceDuration);
    }

    function setMaxPriceUpdateDelay(uint256 _maxPriceUpdateDelay) external onlyController {
        maxPriceUpdateDelay = _maxPriceUpdateDelay;
        emit SetMaxPriceUpdateDelay(_maxPriceUpdateDelay);
    }

    function setSpreadBasisPointsIfInactive(uint256 _spreadBasisPointsIfInactive) external onlyController {
        spreadBasisPointsIfInactive = _spreadBasisPointsIfInactive;
        emit SetSpreadBasisPointsIfInactive(_spreadBasisPointsIfInactive);
    }

    function setSpreadBasisPointsIfChainError(uint256 _spreadBasisPointsIfChainError) external onlyController {
        spreadBasisPointsIfChainError = _spreadBasisPointsIfChainError;
        emit SetSpreadBasisPointsIfChainError(_spreadBasisPointsIfChainError);
    }

    function setMinBlockInterval(uint256 _minBlockInterval) external onlyController {
        minBlockInterval = _minBlockInterval;
        emit SetMinBlockInterval(_minBlockInterval);
    }

    function setIsSpreadEnabled(bool _isSpreadEnabled) external onlyController {
        isSpreadEnabled = _isSpreadEnabled;
        emit SetIsSpreadEnabled(_isSpreadEnabled);
    }

    function setLastUpdatedAt(string memory _token, uint32 _lastUpdatedAt) external onlyController {
        lastUpdatedAts[_token] = _lastUpdatedAt;
        emit  SetLastUpdatedAt(_token, _lastUpdatedAt);
    }

    function setMaxDeviationBasisPoints(uint256 _maxDeviationBasisPoints, uint256 _indexMaxDeviationBasisPoints) external onlyController {
        maxDeviationBasisPoints = _maxDeviationBasisPoints;
        indexMaxDeviationBasisPoints = _indexMaxDeviationBasisPoints;
        emit SetMaxDeviationBasisPoints(_maxDeviationBasisPoints);
    }

    function setMaxCumulativeDeltaDiffs(string[] memory _tokens, uint256[] memory _maxCumulativeDeltaDiffs) external onlyController {
        for (uint256 i = 0; i < _tokens.length; i++) {
            string memory token = _tokens[i];
            maxCumulativeDeltaDiffs[token] = _maxCumulativeDeltaDiffs[i];
            emit SetMaxCumulativeDeltaDiff(token, _maxCumulativeDeltaDiffs[i]);
        }
    }

    function setPriceDataInterval(uint256 _priceDataInterval) external onlyController {
        priceDataInterval = _priceDataInterval;
        emit SetPriceDataInterval(_priceDataInterval);
    }

    function setVerifier(IVerifierProxy _verifier) external onlyController {
        verifier = _verifier;
        emit SetVerifier(verifier);
    }

    function setPyth(IPyth _pyth) external onlyController {
        pyth = _pyth;
        emit SetPyth(_pyth);
    }

    function setMaxPriceTsDiff(uint256 _maxPriceTsDiff) external onlyController {
        maxPriceTsDiff = _maxPriceTsDiff;
        emit SetMaxPriceTsDiff(_maxPriceTsDiff);
    }

    function withdrawVerifyingFee(address _to) external onlyTreasurer {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            payable(_to).transfer(balance);
        }
    }

    function setTokens(string[] memory _tokens, bytes32[] memory _feedIds, bytes32[] memory _pythFeedIds, uint256[] memory _backUpPricePrecisions, uint256[] memory _primaryPricePrecisions) external onlyController {
        require(_tokens.length == _pythFeedIds.length, "FastPriceFeed: invalid pyth feed id lengths");
        require(_tokens.length == _feedIds.length, "FastPriceFeed: invalid feed id lengths");
        require(_tokens.length == _backUpPricePrecisions.length, "FastPriceFeed: invalid backUpPricePrecisions lengths");
        require(_tokens.length == _primaryPricePrecisions.length, "FastPriceFeed: invalid primaryPricePrecisions lengths");
        tokens = _tokens;
        for (uint256 i = 0; i < tokens.length; ++i) {
            feedIds[_feedIds[i]] = tokens[i];
            backUpPricePrecisions[tokens[i]] = _backUpPricePrecisions[i];
            primaryPricePrecisions[tokens[i]] = _primaryPricePrecisions[i];
            pythFeedIds[_pythFeedIds[i]] = tokens[i];
        }

        emit SetTokens(_tokens, _feedIds, _pythFeedIds, _backUpPricePrecisions, _primaryPricePrecisions);
    }

    /// @notice off-chain price update
    /// @param sender price data sender
    /// @param priceType price type {0:backup price;1:pyth price;2:data stream price}
    /// @param offChainPrices off-chain price array
    function setPrices(address sender, uint8 priceType, bytes memory offChainPrices) external onlyExecutorRouter {
        uint256 price;
        bool shouldUpdate;
        require(priceType == 0 || priceType == 1 || priceType == 2, "FastPriceFeed: invalid prices type");
        if (priceType == 0) {
            bytes[] memory _backupPrices = abi.decode(offChainPrices, (bytes[]));
            for (uint256 i = 0; i < _backupPrices.length; i++) {
                (string memory token, uint192 backUpPrice, uint32 ts) = abi.decode(_backupPrices[i], (string, uint192, uint32));
                shouldUpdate = _setLastUpdatedValues(token, ts);
                if (shouldUpdate) {
                    price = backUpPrice;
                    if (price > 0) {
                        price = price.mul(PRICE_PRECISION).div(10 ** backUpPricePrecisions[token]);
                        _setPrice(token, price, marketPriceFeed);
                    }
                }
            }
        } else if (priceType == 1) {
            (bytes32[] memory _priceIds, bytes[] memory _priceUpdateData) = abi.decode(offChainPrices, (bytes32[], bytes[]));
            uint256 fee = pyth.getUpdateFee(_priceUpdateData);
            TransferHelper.safeTransferFrom(WETH, sender, address(this), fee);
            IWrappedCoin(WETH).withdraw(fee);
            PythStructs.PriceFeed[] memory _priceFeed = pyth.parsePriceFeedUpdates{value: fee}(_priceUpdateData, _priceIds, uint64(block.timestamp.sub(maxPriceTsDiff)), uint64(block.timestamp));

            for (uint256 i = 0; i < _priceIds.length; i++) {
                string memory token = pythFeedIds[_priceIds[i]];
                require(_priceFeed[i].price.price > 0 && _priceFeed[i].price.expo <= 0, "FastPriceFeed: invalid price");

                shouldUpdate = _setLastUpdatedValues(token, uint32(_priceFeed[i].price.publishTime));
                if (shouldUpdate) {
                    price = uint256(_priceFeed[i].price.price);
                    price = price.mul(PRICE_PRECISION).div(10 ** uint32(- _priceFeed[i].price.expo));
                    _setPrice(token, price, marketPriceFeed);
                }
            }
        } else {
            bytes[] memory _signedReports = abi.decode(offChainPrices, (bytes[]));
            IFeeManager feeManager = IFeeManager(address(verifier.s_feeManager()));
            address feeNativeTokenAddress = feeManager.i_nativeAddress();
            uint256 feeCost;
            for (uint256 i = 0; i < _signedReports.length; i++) {
                (PremiumReport memory basicReport, uint256 fee) = _calcVerifyFee(_signedReports[i], feeManager, feeNativeTokenAddress);
                feeCost = feeCost.add(fee);
                shouldUpdate = _setLastUpdatedValues(feedIds[basicReport.feedId], basicReport.validFromTimestamp);
                if (shouldUpdate) {
                    require(basicReport.price > 0, "FastPriceFeed: invalid price");
                    price = uint256(basicReport.price);
                    price = price.mul(PRICE_PRECISION).div(10 ** primaryPricePrecisions[feedIds[basicReport.feedId]]);
                    _setPrice(feedIds[basicReport.feedId], price, marketPriceFeed);
                }
            }

            // Verify the reports
            TransferHelper.safeTransferFrom(WETH, sender, address(this), feeCost);
            IWrappedCoin(WETH).withdraw(feeCost);
            verifier.verifyBulk{value: feeCost}(_signedReports, abi.encode(feeNativeTokenAddress));
        }
    }

    function _calcVerifyFee(bytes memory unverifiedReport, IFeeManager feeManager, address feeNativeTokenAddress) internal returns (PremiumReport memory basicReport, uint256 feeCost){
        (, /* bytes32[3] reportContextData */ bytes memory reportData) = abi.decode(unverifiedReport, (bytes32[3], bytes));
        basicReport = abi.decode(reportData, (PremiumReport));
        require(block.timestamp <= basicReport.validFromTimestamp.add(maxPriceTsDiff) && basicReport.expiresAt >= block.timestamp, "FastPriceFeed: invalid price ts");

        // Report verification fees
        (Common.Asset memory fee, ,) = feeManager.getFeeAndReward(
            address(this),
            reportData,
            feeNativeTokenAddress
        );

        feeCost = fee.amount;
    }

    // under regular operation, the fastPrice (prices[token]) is returned and there is no spread returned from this function,
    // though VaultPriceFeed might apply its own spread
    //
    // if the fastPrice has not been updated within priceDuration then it is ignored and only _refPrice with a spread is used (spread: spreadBasisPointsIfInactive)
    // in case the fastPrice has not been updated for maxPriceUpdateDelay then the _refPrice with a larger spread is used (spread: spreadBasisPointsIfChainError)
    //
    // there will be a spread from the _refPrice to the fastPrice in the following cases:
    // - in case isSpreadEnabled is set to true
    // - in case the maxDeviationBasisPoints between _refPrice and fastPrice is exceeded
    // - in case watchers flag an issue
    // - in case the cumulativeFastDelta exceeds the cumulativeRefDelta by the maxCumulativeDeltaDiff
    function getPrice(string memory _token, uint256 _refPrice, bool _maximise) external view returns (uint256) {
        if (block.timestamp > uint256(lastUpdatedAts[_token]).add(maxPriceUpdateDelay)) {
            if (_maximise) {
                return _refPrice.mul(BASIS_POINTS_DIVISOR.add(spreadBasisPointsIfChainError)).div(BASIS_POINTS_DIVISOR);
            }
            return _refPrice.mul(BASIS_POINTS_DIVISOR.sub(spreadBasisPointsIfChainError)).div(BASIS_POINTS_DIVISOR);
        }

        if (block.timestamp > uint256(lastUpdatedAts[_token]).add(priceDuration)) {
            if (_maximise) {
                return _refPrice.mul(BASIS_POINTS_DIVISOR.add(spreadBasisPointsIfInactive)).div(BASIS_POINTS_DIVISOR);
            }
            return _refPrice.mul(BASIS_POINTS_DIVISOR.sub(spreadBasisPointsIfInactive)).div(BASIS_POINTS_DIVISOR);
        }

        uint256 fastPrice = prices[_token];

        if (fastPrice == 0) {return _refPrice;}
        uint256 diffBasisPoints = _refPrice > fastPrice ? _refPrice.sub(fastPrice) : fastPrice.sub(_refPrice);
        diffBasisPoints = diffBasisPoints.mul(BASIS_POINTS_DIVISOR).div(_refPrice);

        // create a spread between the _refPrice and the fastPrice if the maxDeviationBasisPoints is exceeded
        // or if watchers have flagged an issue with the fast price
        bool hasSpread = !favorFastPrice(_token) || diffBasisPoints > maxDeviationBasisPoints;

        if (hasSpread) {
            // return the higher of the two prices
            if (_maximise) {
                return _refPrice > fastPrice ? _refPrice : fastPrice;
            }

            // return the lower of the two prices
            //min price
            return _refPrice < fastPrice ? _refPrice : fastPrice;
        }

        return fastPrice;
    }

    function favorFastPrice(string memory _token) public view returns (bool) {
        if (isSpreadEnabled) {
            return false;
        }

        (/* uint256 prevRefPrice */, /* uint256 refTime */, uint256 cumulativeRefDelta, uint256 cumulativeFastDelta) = getPriceData(_token);
        if (cumulativeFastDelta > cumulativeRefDelta && cumulativeFastDelta.sub(cumulativeRefDelta) > maxCumulativeDeltaDiffs[_token]) {
            // force a spread if the cumulative delta for the fast price feed exceeds the cumulative delta
            // for the Chainlink price feed by the maxCumulativeDeltaDiff allowed
            return false;
        }

        return true;
    }

    function getIndexPrice(string memory _token, uint256 _refPrice, bool /* _maximise*/) external view returns (uint256) {
        if (block.timestamp > uint256(lastUpdatedAts[_token]).add(indexPriceDuration)) {
            return _refPrice;
        }

        uint256 fastPrice = prices[_token];
        if (fastPrice == 0) return _refPrice;

        uint256 diffBasisPoints = _refPrice > fastPrice ? _refPrice.sub(fastPrice) : fastPrice.sub(_refPrice);
        diffBasisPoints = diffBasisPoints.mul(BASIS_POINTS_DIVISOR).div(_refPrice);

        // create a spread between the _refPrice and the fastPrice if the maxDeviationBasisPoints is exceeded
        // or if watchers have flagged an issue with the fast price
        if (diffBasisPoints > indexMaxDeviationBasisPoints) {
            return _refPrice;
        }

        return fastPrice;
    }

    function getPriceData(string memory _token) public view returns (uint256, uint256, uint256, uint256) {
        PriceDataItem memory data = priceData[_token];
        return (uint256(data.refPrice), uint256(data.refTime), uint256(data.cumulativeRefDelta), uint256(data.cumulativeFastDelta));
    }

    function _setPrice(string memory _token, uint256 _price, address _marketPriceFeed) internal {
        if (_marketPriceFeed != address(0)) {
            uint256 refPrice = IMarketPriceFeed(_marketPriceFeed).getLatestPrimaryPrice(_token);
            uint256 fastPrice = prices[_token];
            (uint256 prevRefPrice, uint256 refTime, uint256 cumulativeRefDelta, uint256 cumulativeFastDelta) = getPriceData(_token);

            if (prevRefPrice > 0) {
                uint256 refDeltaAmount = refPrice > prevRefPrice ? refPrice.sub(prevRefPrice) : prevRefPrice.sub(refPrice);
                uint256 fastDeltaAmount = fastPrice > _price ? fastPrice.sub(_price) : _price.sub(fastPrice);

                // reset cumulative delta values if it is a new time window
                if (refTime.div(priceDataInterval) != block.timestamp.div(priceDataInterval)) {
                    cumulativeRefDelta = 0;
                    cumulativeFastDelta = 0;
                }

                cumulativeRefDelta = cumulativeRefDelta.add(refDeltaAmount.mul(CUMULATIVE_DELTA_PRECISION).div(prevRefPrice));
                cumulativeFastDelta = cumulativeFastDelta.add(fastDeltaAmount.mul(CUMULATIVE_DELTA_PRECISION).div(fastPrice));
            }

            if (cumulativeFastDelta > cumulativeRefDelta && cumulativeFastDelta.sub(cumulativeRefDelta) > maxCumulativeDeltaDiffs[_token]) {
                emit MaxCumulativeDeltaDiffExceeded(_token, refPrice, fastPrice, cumulativeRefDelta, cumulativeFastDelta);
            }

            _setPriceData(_token, refPrice, cumulativeRefDelta, cumulativeFastDelta);
            emit PriceData(_token, refPrice, fastPrice, cumulativeRefDelta, cumulativeFastDelta);
        }
        prices[_token] = _price;
        emit PriceUpdated(_token, _price);
    }

    function _setPriceData(string memory _token, uint256 _refPrice, uint256 _cumulativeRefDelta, uint256 _cumulativeFastDelta) internal {
        require(_refPrice < MAX_REF_PRICE, "FastPriceFeed: invalid refPrice");
        // skip validation of block.timestamp, it should only be out of range after the year 2100
        require(_cumulativeRefDelta < MAX_CUMULATIVE_REF_DELTA, "FastPriceFeed: invalid cumulativeRefDelta");
        require(_cumulativeFastDelta < MAX_CUMULATIVE_FAST_DELTA, "FastPriceFeed: invalid cumulativeFastDelta");

        priceData[_token] = PriceDataItem(
            uint160(_refPrice),
            uint32(block.timestamp),
            uint32(_cumulativeRefDelta),
            uint32(_cumulativeFastDelta)
        );
    }

    function _setLastUpdatedValues(string memory _token, uint32 _timestamp) internal returns (bool) {
        if (minBlockInterval > 0) {
            require(block.number.sub(lastUpdatedBlock) >= minBlockInterval, "FastPriceFeed: minBlockInterval not yet passed");
        }

        uint256 _maxTimeDeviation = maxTimeDeviation;
        require(_timestamp > block.timestamp.sub(_maxTimeDeviation), "FastPriceFeed: _timestamp below allowed range");
        require(_timestamp < block.timestamp.add(_maxTimeDeviation), "FastPriceFeed: _timestamp exceeds allowed range");

        // do not update prices if _timestamp is before the current lastUpdatedAt value
        if (_timestamp < lastUpdatedAts[_token]) {
            return false;
        }

        lastUpdatedAts[_token] = _timestamp;
        lastUpdatedBlock = block.number;

        return true;
    }

    receive() external payable {
        emit fallbackCalled(msg.sender, msg.value, msg.data);
    }
}
