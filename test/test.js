const { ethers, upgrades } = require("hardhat");

let contract = {
  utp: new Object(),
  urp: new Object(),
  testToken: new Object(),
  manager: new Object(),
  marketLogic: new Object(),
  fundingLogic: new Object(),
  interestLogic: new Object(),
  validationLogic: new Object(),
  riskFunding: new Object(),
  inviteManager: new Object(),
  vault: new Object(),
  periphery: new Object(),
  router: new Object(),
  fastPriceFeed: new Object(),
  marketPriceFeed: new Object(),
  pool: new Object(),
  market: new Object(),
  oracle: new Object()
};

let fee = { value: ethers.utils.parseEther("0.0001") };
let r;

/*
  init info: userA,userB,userC,userD balance 1w，userE is inviter，balance 0,default positionMode is OneWay
  1.price 1000,userA add 1w liquidity
  2.price 1100,userB open m=100 ,l=10,long position
  3.price 1150,userC add 1w liquidity
  4.price 1200,userD open m=100 ,l=10,short position ,userB open m=200 ,l=10,short position
  5.price 1210,userD open m=100 ,l=10,short position
  6.price 1220,userD open m=100 ,l=10,long position
  7.price 1300,userB,userD close position,userA,userC remove liquidity
 */
async function multipleUserTest(deployer, userA, userB, userC, userD, userE, marketType) {
  showTitle("deploy contract");
  await deploy(deployer, marketType, false);
  showTitle("init");
  await init(deployer, userA, userB, userC, userD, userE, true);


  showTitle("set price 1000");
  await setOraclePrice(deployer, ethers.utils.parseUnits("1000", 8));
  await setPrice(deployer, ethers.utils.parseUnits("1000", 8));
  showTitle("userA price 1000 add liquidity 10000");
  await addLiquidity(userA, ethers.utils.parseUnits("10000", 18));
  let userALp = await contract.pool.getLpBalanceOf(userA.address);
  console.log("userA lp balance:", ethers.utils.formatEther(userALp._balance.toString()));


  showTitle("userB price 1100 open m=100 ,l=10,long position");
  await open(userB, ethers.utils.parseUnits("100", 18), 10, 1, ethers.utils.formatBytes32String("yfx"));
  await sleep(1000);
  await setOraclePrice(deployer, ethers.utils.parseUnits("1100", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1100", 8));
  let orderID = await getOrderID(userB);
  let positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);

  showTitle("set price 1150");
  await setOraclePrice(deployer, ethers.utils.parseUnits("1150", 8));
  await setPrice(deployer, ethers.utils.parseUnits("1150", 8));
  showTitle("userC price 1150 add liquidity 10000");
  await addLiquidity(userC, ethers.utils.parseUnits("10000", 18));
  let userCLp = await contract.pool.getLpBalanceOf(userC.address);
  console.log("userC lp balance:", ethers.utils.formatEther(userCLp._balance.toString()));

  showTitle("userD price 1200 open m=100 ,l=10,short position");
  showTitle("userB price 1200 open m=200 ,l=10,short position");
  await open(userD, ethers.utils.parseUnits("100", 18), 10, -1, ethers.utils.formatBytes32String("yfx"));
  await open(userB, ethers.utils.parseUnits("200", 18), 10, -1, ethers.utils.formatBytes32String("yfx"));
  await setOraclePrice(deployer, ethers.utils.parseUnits("1200", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1200", 8));
  await sleep(1000);
  orderID = await getOrderID(userD);
  positionID = await getPositionID(userD, 1);
  await getPosition("userD position info", positionID, orderID);
  await sleep(1000);
  orderID = await getOrderID(userB);
  positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);

  showTitle("userD price 1210 open m=100 ,l=10,short position");
  await open(userD, ethers.utils.parseUnits("100", 18), 10, -1, ethers.utils.formatBytes32String("yfx"));
  await setOraclePrice(deployer, ethers.utils.parseUnits("1210", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1210", 8));
  await sleep(1000);
  orderID = await getOrderID(userD);
  positionID = await getPositionID(userD, 1);
  await getPosition("userD position info", positionID, orderID);


  showTitle("userD price 1220 open m=100 ,l=10,long position");
  await open(userD, ethers.utils.parseUnits("100", 18), 10, 1, ethers.utils.formatBytes32String("yfx"));
  await setOraclePrice(deployer, ethers.utils.parseUnits("1220", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1220", 8));
  await sleep(1000);
  orderID = await getOrderID(userD);
  positionID = await getPositionID(userD, 1);
  await getPosition("userD position info", positionID, orderID);


  showTitle("userB,userD price 1300 close position");
  let userBPositionId = await getPositionID(userB, 1);
  let userDPositionId = await getPositionID(userD, 1);
  console.log("userB position id:", userBPositionId.toString());
  await close(userB, userBPositionId, ethers.utils.parseUnits("100000000000000000000000", 20), ethers.utils.formatBytes32String("yfx"));
  await close(userD, userDPositionId, ethers.utils.parseUnits("100000000000000000000000", 20), ethers.utils.formatBytes32String("yfx"));
  await setOraclePrice(deployer, ethers.utils.parseUnits("1300", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1300", 8));
  await sleep(1000);
  orderID = await getOrderID(userB);
  positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);
  orderID = await getOrderID(userD);
  positionID = await getPositionID(userD, 1);
  await getPosition("userD position info", positionID, orderID);

  showTitle("userA,userC price 1300 remove liquidity");
  await removeLiquidity(userA, userALp._balance.toString());
  await getRmFee("userA remove liquidity fee:");
  await removeLiquidity(userC, userCLp._balance.toString());
  await getRmFee("userA+userC remove liquidity fee:");


  await getBalanceInfo("user balance info", userA, userB, userC, userD, userE, false);
}


/*
  init info: userA,userB,userC,userD balance 1w，userE is inviter，balance 0,default positionMode is OneWay
  1.price 1000,userA add 1w liquidity
  2.price 1100,userB open m=100 ,l=10,long position
  3.price 1200,userB close position

  switch to heuge mode


  4.price 1210,userB open m=100 ,l=10,long position ,userB open m=200 ,l=10,short position
  5.price 1220,userB open m=100 ,l=10,long position
  6.price 1230,userD open m=100 ,l=10,short position
  7.price 1300,userB close position,userA remove liquidity
 */
async function postionModeTest(deployer, userA, userB, userC, userD, userE, marketType) {
  showTitle("deploy contract");
  await deploy(deployer, marketType, false);
  // showTitle("init");
  await init(deployer, userA, userB, userC, userD, userE, true);


  showTitle("set price 1000");
  await setOraclePrice(deployer, ethers.utils.parseUnits("1700", 8));
  await setPrice(deployer, ethers.utils.parseUnits("1700", 8));
  showTitle("userA price 1000 add liquidity 10000");
  await addLiquidity(userA, ethers.utils.parseUnits("10000", 18));
  let userALp = await contract.pool.getLpBalanceOf(userA.address);
  console.log("userA lp balance:", ethers.utils.formatEther(userALp._balance.toString()));


  showTitle("userB price 1100 open m=100 ,l=10,long position");
  await open(userB, ethers.utils.parseUnits("100", 18), 10, 1, ethers.utils.formatBytes32String("yfx"));
  await sleep(1000);
  await setOraclePrice(deployer, ethers.utils.parseUnits("1100", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1100", 8));
  let orderID = await getOrderID(userB);
  let positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);


  showTitle("userB price 1200 close position");
  let userBPositionId = await getPositionID(userB, 1);
  await close(userB, userBPositionId, ethers.utils.parseUnits("10000000000000000", 18), ethers.utils.formatBytes32String("yfx"));
  await setOraclePrice(deployer, ethers.utils.parseUnits("1200", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1200", 8));
  await sleep(1000);
  orderID = await getOrderID(userB);
  positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);


  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);
  r = await contract.router.connect(userB).switchPositionMode(contract.market.address, 1);


  showTitle("userB price 1210 open m=100 ,l=10,long position");
  await open(userB, ethers.utils.parseUnits("100", 18), 10, 1, ethers.utils.formatBytes32String("yfx"));
  await sleep(1000);
  await setOraclePrice(deployer, ethers.utils.parseUnits("1210", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1210", 8));
  orderID = await getOrderID(userB);
  positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);


  showTitle("userB price 1220 open m=100 ,l=10,long position");
  await open(userB, ethers.utils.parseUnits("100", 18), 10, 1, ethers.utils.formatBytes32String("yfx"));
  await sleep(1000);
  await setOraclePrice(deployer, ethers.utils.parseUnits("1220", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1220", 8));
  orderID = await getOrderID(userB);
  positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);


  showTitle("userB price 1230 open m=100 ,l=10,short position");
  await open(userB, ethers.utils.parseUnits("100", 18), 10, -1, ethers.utils.formatBytes32String("yfx"));
  await sleep(1000);
  await setOraclePrice(deployer, ethers.utils.parseUnits("1230", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1230", 8));
  orderID = await getOrderID(userB);
  positionID = await getPositionID(userB, -1);
  await getPosition("userB position info", positionID, orderID);


  showTitle("userB price 1300 close position");
  let longPositionId = await getPositionID(userB, 1);
  let shortPositionId = await getPositionID(userB, -1);
  await close(userB, longPositionId, ethers.utils.parseUnits("10000000000000000000", 18), ethers.utils.formatBytes32String("yfx"));
  await sleep(1000);
  orderID = await getOrderID(userB);
  await close(userB, shortPositionId, ethers.utils.parseUnits("10000000000000000000", 18), ethers.utils.formatBytes32String("yfx"));
  await setOraclePrice(deployer, ethers.utils.parseUnits("1300", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1300", 8));
  await sleep(1000);
  await getPosition("userB position info", longPositionId, orderID);
  orderID = await getOrderID(userB);
  await getPosition("userB position info", shortPositionId, orderID);


  showTitle("userA price 1300 remove liquidity");
  await removeLiquidity(userA, userALp._balance.toString());
  await getRmFee("userA remove liquidity fee:");


  await getBalanceInfo("user balance info", userA, userB, userC, userD, userE, false);
}

/*
  init info: userA,userB,userC,userD balance 1w，userE is inviter，balance 0,default positionMode is OneWay
  1.price 1000,userA add 1w liquidity
  2.price 1100,userB open m=100 ,l=10,long position
  3.price 1150,userC add 1w liquidity
  4.price 1200,userD open m=100 ,l=10,short position ,userB open m=200 ,l=10,short position
  5.price 1210,userD open m=100 ,l=10,short position
  6.price 1220,userD open m=100 ,l=10,long position
  7.price 1300,userB,userD close position,userA,userC remove liquidity
 */
async function testingWithETHAsCollateral(deployer, userA, userB, userC, userD, userE, marketType) {
  showTitle("deploy contract");
  await deploy(deployer, marketType, true);
  // showTitle("init");
  await init(deployer, userA, userB, userC, userD, userE, false);


  showTitle("set price 1000");
  await setPrice(deployer, ethers.utils.parseUnits("1000", 8));
  showTitle("userA price 1000 add liquidity 10000");
  await addLiquidityETH(userA, ethers.utils.parseUnits("10000", 18));
  let userALp = await contract.pool.getLpBalanceOf(userA.address);
  console.log("userA lp balance:", ethers.utils.formatEther(userALp._balance.toString()));


  showTitle("userB price 1100 open m=100 ,l=10,long position");
  await openETH(userB, ethers.utils.parseUnits("100", 18), 10, 1, ethers.utils.formatBytes32String("yfx"));
  await sleep(1000);
  await executeOrder(deployer, ethers.utils.parseUnits("1100", 8));
  let orderID = await getOrderID(userB);
  let positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);


  showTitle("set price 1150");
  await setPrice(deployer, ethers.utils.parseUnits("1150", 8));
  showTitle("userC price 1150 add liquidity 10000");
  await addLiquidityETH(userC, ethers.utils.parseUnits("10000", 18));
  let userCLp = await contract.pool.getLpBalanceOf(userC.address);
  console.log("userC lp balance:", ethers.utils.formatEther(userCLp._balance.toString()));


  showTitle("userD price 1200 open m=100 ,l=10,short position");
  showTitle("userB price 1200 open m=200 ,l=10,short position");
  await openETH(userD, ethers.utils.parseUnits("100", 18), 10, -1, ethers.utils.formatBytes32String("yfx"));
  await openETH(userB, ethers.utils.parseUnits("200", 18), 10, -1, ethers.utils.formatBytes32String("yfx"));
  await executeOrder(deployer, ethers.utils.parseUnits("1200", 8));
  await sleep(1000);
  orderID = await getOrderID(userD);
  positionID = await getPositionID(userD, 1);
  await getPosition("userD position info", positionID, orderID);
  await sleep(1000);
  orderID = await getOrderID(userB);
  positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);

  showTitle("userD price 1210 open m=100 ,l=10,short position");
  await openETH(userD, ethers.utils.parseUnits("100", 18), 10, -1, ethers.utils.formatBytes32String("yfx"));
  await executeOrder(deployer, ethers.utils.parseUnits("1210", 8));
  await sleep(1000);
  orderID = await getOrderID(userD);
  positionID = await getPositionID(userD, 1);
  await getPosition("userD position info", positionID, orderID);


  showTitle("userD price 1220 open m=100 ,l=10,long position");
  await openETH(userD, ethers.utils.parseUnits("100", 18), 10, 1, ethers.utils.formatBytes32String("yfx"));
  await executeOrder(deployer, ethers.utils.parseUnits("1220", 8));
  await sleep(1000);
  orderID = await getOrderID(userD);
  positionID = await getPositionID(userD, 1);
  await getPosition("userD position info", positionID, orderID);

  showTitle("userB,userD price 1300 close position");
  let userBPositionId = await getPositionID(userB, 1);
  let userDPositionId = await getPositionID(userD, 1);
  console.log("userB position id:", userBPositionId.toString());
  await close(userB, userBPositionId, ethers.utils.parseUnits("10000000000000000", 18), ethers.utils.formatBytes32String("yfx"));
  await close(userD, userDPositionId, ethers.utils.parseUnits("10000000000000000", 18), ethers.utils.formatBytes32String("yfx"));
  await executeOrder(deployer, ethers.utils.parseUnits("1300", 8));
  await sleep(1000);
  orderID = await getOrderID(userB);
  positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);
  orderID = await getOrderID(userD);
  positionID = await getPositionID(userD, 1);
  await getPosition("userD position info", positionID, orderID);


  showTitle("userA,userC price 1300 remove liquidity");
  await removeLiquidityETH(userA, userALp._balance.toString());
  await getRmFee("userA remove liquidity fee:");
  await removeLiquidityETH(userC, userCLp._balance.toString());
  await getRmFee("userA+userC remove liquidity fee:");


  await getBalanceInfo("user balance info", userA, userB, userC, userD, userE, true);
}


/*
  init info: userA,userB,userC,userD balance 1w，userE is inviter，balance 0,default positionMode is OneWay
  1.price 1000,userA add 1w liquidity
  2.price 1100,userB open m=100 ,l=10,long position
  3.price 1300,userB close position,userA remove liquidity
 */
async function singleUserTest(deployer, userA, userB, userC, userD, userE, marketType) {
  showTitle("deploy contract");
  await deploy(deployer, marketType, false);
  // showTitle("init");
  await init(deployer, userA, userB, userC, userD, userE, true);


  showTitle("set price 1000");
  await setOraclePrice(deployer, ethers.utils.parseUnits("1000", 8));
  await setPrice(deployer, ethers.utils.parseUnits("1000", 8));
  showTitle("userA price 1000 add liquidity 10000");
  await addLiquidity(userA, ethers.utils.parseUnits("10000", 18));
  let userALp = await contract.pool.getLpBalanceOf(userA.address);
  console.log("userA lp balance:", ethers.utils.formatEther(userALp._balance.toString()));

  showTitle("userB price 1100 open m=100 ,l=10,long position");
  await open(userB, ethers.utils.parseUnits("100", 18), 10, 1, ethers.utils.formatBytes32String("yfx"));
  await sleep(1000);
  await setOraclePrice(deployer, ethers.utils.parseUnits("1100", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1100", 8));
  let orderID = await getOrderID(userB);
  let positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);


  showTitle("userB price 1300 close position");
  let userBPositionId = await getPositionID(userB, 1);
  await close(userB, userBPositionId, ethers.utils.parseUnits("10000000", 18), ethers.utils.formatBytes32String("yfx"));
  await setOraclePrice(deployer, ethers.utils.parseUnits("1300", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1300", 8));
  await sleep(1000);
  orderID = await getOrderID(userB);
  positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);


  showTitle("userA,userC price 1300 remove liquidity");
  await removeLiquidity(userA, userALp._balance.toString());
  await getRmFee("userA remove liquidity fee:");

  await getBalanceInfo("user balance info", userA, userB, userC, userD, userE);
}

/*
  init info: userA,userB,userC,userD balance 1w，userE is inviter，balance 0,default positionMode is OneWay
  1.increase and decrease margin
 */
async function increaseOrDecreseMarginTest(deployer, userA, userB, userC, userD, userE, marketType) {
  showTitle("deploy contract");
  await deploy(deployer, marketType, false);
  // showTitle("init");
  await init(deployer, userA, userB, userC, userD, userE, true);


  showTitle("set price 1000");
  await setOraclePrice(deployer, ethers.utils.parseUnits("1000", 8));
  await setPrice(deployer, ethers.utils.parseUnits("1000", 8));
  showTitle("userA price 1000 add liquidity 10000");
  await addLiquidity(userA, ethers.utils.parseUnits("10000", 18));
  let userALp = await contract.pool.getLpBalanceOf(userA.address);
  console.log("userA lp balance:", ethers.utils.formatEther(userALp._balance.toString()));

  showTitle("userB price 1100 open m=100 ,l=10,long position");
  await setOraclePrice(deployer, ethers.utils.parseUnits("1100", 8));
  await open(userB, ethers.utils.parseUnits("100", 18), 10, 1, ethers.utils.formatBytes32String("yfx"));
  await sleep(1000);
  await executeOrder(deployer, ethers.utils.parseUnits("1100", 8));
  let orderID = await getOrderID(userB);
  let positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);

  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  const Peripherry = await ethers.getContractFactory("Periphery");
  contract.periphery = await Peripherry.attach(contract.periphery.address);


  showTitle("userB decrease margin");
  await setOraclePrice(deployer, ethers.utils.parseUnits("1050", 8));
  await setPrice(deployer, ethers.utils.parseUnits("1050", 8));
  let maxDecrease = await contract.periphery.getMaxDecreaseMargin(contract.market.address, positionID);
  console.log("maxDecrease:", ethers.utils.formatEther(maxDecrease.toString()));
  let add = await contract.router.connect(userB).decreaseMargin(contract.market.address, positionID, maxDecrease);
  await getPosition("userB position info", positionID, orderID);


  showTitle("userB increase margin");
  await contract.router.connect(userB).increaseMargin(contract.market.address, positionID, ethers.utils.parseUnits("100", 18));
  await getPosition("userB position info", positionID, orderID);


  showTitle("userB price 1300 close position");
  let userBPositionId = await getPositionID(userB, 1);
  await close(userB, userBPositionId, ethers.utils.parseUnits("1000000000000000", 18), ethers.utils.formatBytes32String("yfx"));
  await setOraclePrice(deployer, ethers.utils.parseUnits("1300", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1300", 8));
  await sleep(1000);
  orderID = await getOrderID(userB);
  positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);


  showTitle("userA,userC price 1300 remove liquidity");
  await removeLiquidity(userA, userALp._balance.toString());
  await getRmFee("userA remove liquidity fee:");

  await getBalanceInfo("user balance info", userA, userB, userC, userD, userE);
}

/*
  init info: userA,userB,userC,userD balance 1w，userE is inviter，balance 0,default positionMode is OneWay
  1.1100 userB open m=100 ,l=10,long position
  2.2100 userB close position  or 　600 userB close position
 */
async function errorPriceTest(deployer, userA, userB, userC, userD, userE, marketType) {
  showTitle("deploy contract");
  await deploy(deployer, marketType, false);
  // showTitle("init");
  await init(deployer, userA, userB, userC, userD, userE, true);


  showTitle("set price 1000");
  await setOraclePrice(deployer, ethers.utils.parseUnits("1000", 8));
  await setPrice(deployer, ethers.utils.parseUnits("1000", 8));
  showTitle("userA price 1000 add liquidity 10000");
  await addLiquidity(userA, ethers.utils.parseUnits("10000", 18));
  let userALp = await contract.pool.getLpBalanceOf(userA.address);
  console.log("userA lp balance:", ethers.utils.formatEther(userALp._balance.toString()));

  showTitle("userB price 1100 open m=100 ,l=10,long position");
  await open(userB, ethers.utils.parseUnits("100", 18), 10, 1, ethers.utils.formatBytes32String("yfx"));
  await sleep(1000);
  await setOraclePrice(deployer, ethers.utils.parseUnits("1100", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1100", 8));
  let orderID = await getOrderID(userB);
  let positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);


  showTitle("userB price 2100 close position");
  let userBPositionId = await getPositionID(userB, 1);
  await close(userB, userBPositionId, ethers.utils.parseUnits("10000000000000000", 20), ethers.utils.formatBytes32String("yfx"));
  await setOraclePrice(deployer, ethers.utils.parseUnits("994", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("994", 8));
  await sleep(1000);
  orderID = await getOrderID(userB);
  positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);


  showTitle("userA,userC price 1300 remove liquidity");
  await removeLiquidity(userA, userALp._balance.toString());
  await getRmFee("userA remove liquidity fee:");

  await getBalanceInfo("user balance info", userA, userB, userC, userD, userE);
}


/*
  init info: userA,userB,userC,userD balance 1w，userE is inviter，balance 0,default positionMode is OneWay
  1.1100 userB open m=100 ,l=10,long position
  2.userB set 1500 and 1050
  3.1550 system close position or 　900 system close position
 */
async function tpslTest(deployer, userA, userB, userC, userD, userE, marketType) {
  showTitle("deploy contract");
  await deploy(deployer, marketType, false);
  // showTitle("init");
  await init(deployer, userA, userB, userC, userD, userE, true);


  showTitle("set price 1000");
  await setOraclePrice(deployer, ethers.utils.parseUnits("1000", 8));
  await setPrice(deployer, ethers.utils.parseUnits("1000", 8));
  showTitle("userA price 1000 add liquidity 10000");
  await addLiquidity(userA, ethers.utils.parseUnits("10000", 18));
  let userALp = await contract.pool.getLpBalanceOf(userA.address);
  console.log("userA lp balance:", ethers.utils.formatEther(userALp._balance.toString()));

  showTitle("userB price 1100 open m=100 ,l=10,long position");
  await open(userB, ethers.utils.parseUnits("100", 18), 10, 1, ethers.utils.formatBytes32String("yfx"));
  await sleep(1000);
  await setOraclePrice(deployer, ethers.utils.parseUnits("1100", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1100", 8));
  let orderID = await getOrderID(userB);
  let positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);


  showTitle("userB set setTPSLPrice 1500 and 950");
  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  await contract.router.connect(userB).setTPSLPrice(contract.market.address, 1, ethers.utils.parseUnits("1500", 10), ethers.utils.parseUnits("1050", 10));
  await getPosition("userB position info", positionID, orderID);


  showTitle("system price 100 close position");
  let userBPositionId = await getPositionID(userB, 1);
  await setOraclePrice(deployer, ethers.utils.parseUnits("1050", 8));
  liquidate(deployer, 1, 7, ethers.utils.parseUnits("1050", 8));
  await sleep(1000);
  orderID = await getOrderID(userB);
  positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);


  showTitle("userA,userC price 1300 remove liquidity");
  await removeLiquidity(userA, userALp._balance.toString());
  await getRmFee("userA remove liquidity fee:");

  await getBalanceInfo("user balance info", userA, userB, userC, userD, userE);
}


/*
  init info: userA,userB,userC,userD balance 1w，userE is inviter，balance 0,default positionMode is OneWay
  1.1100 userB open m=100 ,l=10,long position
  3.liquidate or taker stop profit
 */
async function liquiditeTest(deployer, userA, userB, userC, userD, userE, marketType) {
  showTitle("deploy contract");
  await deploy(deployer, marketType, false);
  // showTitle("init");
  await init(deployer, userA, userB, userC, userD, userE, true);


  showTitle("set price 1000");
  await setOraclePrice(deployer, ethers.utils.parseUnits("1000", 8));
  await setPrice(deployer, ethers.utils.parseUnits("1000", 8));
  showTitle("userA price 1000 add liquidity 10000");
  await addLiquidity(userA, ethers.utils.parseUnits("10000", 18));
  let userALp = await contract.pool.getLpBalanceOf(userA.address);
  console.log("userA lp balance:", ethers.utils.formatEther(userALp._balance.toString()));

  showTitle("userB price 1100 open m=100 ,l=10,long position");
  await open(userB, ethers.utils.parseUnits("100", 18), 10, 1, ethers.utils.formatBytes32String("yfx"));
  await sleep(1000);
  await setOraclePrice(deployer, ethers.utils.parseUnits("1100", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1100", 8));
  let orderID = await getOrderID(userB);
  let positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);


  //taker profit
  // showTitle("taker profit");
  // await setOraclePrice(deployer, ethers.utils.parseUnits("3000", 8));
  // liquidate(deployer, 1, 5, ethers.utils.parseUnits("3000", 8));
  // await sleep(1000);
  // orderID = await getOrderID(userB);
  // // positionID = await getPositionID(userB, 1);
  // await getPosition("userB position info", 1, orderID);


  //liquidate
  showTitle("liquidate position");
  await setOraclePrice(deployer, ethers.utils.parseUnits("995", 8));
  liquidate(deployer, 1, 4, ethers.utils.parseUnits("995", 8));
  await sleep(1000);
  orderID = await getOrderID(userB);
  positionID = await getPositionID(userB, 1);
  await getPosition("userB position info", positionID, orderID);


  showTitle("userA,userC price 1300 remove liquidity");
  await removeLiquidity(userA, userALp._balance.toString());
  await getRmFee("userA remove liquidity fee:");

  await getBalanceInfo("user balance info", userA, userB, userC, userD, userE);
}

/*
  init info: userA,userB,userC,userD balance 1w，userE is inviter，balance 0,default positionMode is OneWay
  1.userB open m=100 ,l=10,short position ,direction= -1 ,price = 1100;// order 1
  2.userB open m=200 ,l=10,long position ,direction=1 ,price = 1120;// order 2
  3.price 1080 execute order  //position id 1
  4.price 1140 execute order  //position id 1
  5.price 1160 close position  //position id 1, order 2
  6.switch position mode to hedge
  7.price 1170 userB open m=100 ,l=10,long position //position id 2, order 3
  8.userB close position amount =100 ,direction =1 ,price = 1200;  order 4
  9.price 1210 execute order //position id 2
 */
async function triggerOrderTest(deployer, userA, userB, userC, userD, userE, marketType) {
  showTitle("deploy contract");
  await deploy(deployer, marketType, false);
  // showTitle("init");
  await init(deployer, userA, userB, userC, userD, userE, true);


  showTitle("set price 1000");
  await setOraclePrice(deployer, ethers.utils.parseUnits("1000", 8));
  await setPrice(deployer, ethers.utils.parseUnits("1000", 8));
  showTitle("userA price 1000 add liquidity 10000");
  await addLiquidity(userA, ethers.utils.parseUnits("10000", 18));
  let userALp = await contract.pool.getLpBalanceOf(userA.address);
  console.log("userA lp balance:", ethers.utils.formatEther(userALp._balance.toString()));

  showTitle("userB  open m=100 ,l=10,short position,direction= -1 ,price = 1100");
  await openTrigger(userB, ethers.utils.parseUnits("100", 18), 10, 1, ethers.utils.formatBytes32String("yfx"), -1, ethers.utils.parseUnits("1100", 10));
  await sleep(1000);
  let orderID1 = await getOrderID(userB);
  // await getPosition("userB position info", 1, orderID);

  //
  // showTitle("userB open m=200 ,l=10,long position,direction= 1 ,price = 1120");
  // await openTrigger(userB, ethers.utils.parseUnits("100", 18), 10, 1, ethers.utils.formatBytes32String("yfx"), 1, ethers.utils.parseUnits("1120", 10));
  // await sleep(1000);
  // let orderID2 = await getOrderID(userB);
  // await getPosition("userB position info", 1, orderID);


  showTitle("price 1080 execute order");
  await setOraclePrice(deployer, ethers.utils.parseUnits("1080", 8));
  await executeOrderTrigger(deployer, ethers.utils.parseUnits("1080", 8), orderID1);
  await getPosition("userB position info", 1, orderID1);

  // showTitle("price 1140 execute order");
  // await setOraclePrice(deployer, ethers.utils.parseUnits("1140", 8));
  // await executeOrderTrigger(deployer, ethers.utils.parseUnits("1140", 8), orderID2);
  // await getPosition("userB position info", 1, orderID2);


  showTitle("userB price 1160 close position");
  await close(userB, 1, ethers.utils.parseUnits("1000000000", 18), ethers.utils.formatBytes32String("yfx"));
  await setOraclePrice(deployer, ethers.utils.parseUnits("1160", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1160", 8));
  await sleep(1000);
  let orderID = await getOrderID(userB);
  await getPosition("userB position info", 1, orderID);


  showTitle("userB switch to heuge");
  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);
  r = await contract.router.connect(userB).switchPositionMode(contract.market.address, 1);


  showTitle("userB price 1170 open m=100 ,l=10,long position");
  await open(userB, ethers.utils.parseUnits("100", 18), 10, 1, ethers.utils.formatBytes32String("yfx"));
  await sleep(1000);
  await setOraclePrice(deployer, ethers.utils.parseUnits("1170", 8));
  await executeOrder(deployer, ethers.utils.parseUnits("1170", 8));
  let orderID3 = await getOrderID(userB);
  await getPosition("userB position info", 2, orderID3);


  showTitle("userB close position amount =100 ,direction =1 ,price = 1200");
  await closeTrigger(userB, 2, ethers.utils.parseUnits("1000000000", 18), ethers.utils.formatBytes32String("yfx"), 1, ethers.utils.parseUnits("1200", 10));
  await sleep(1000);
  let orderID4 = await getOrderID(userB);


  showTitle("price 1140 execute order");
  await setOraclePrice(deployer, ethers.utils.parseUnits("1210", 8));
  await executeOrderTrigger(deployer, ethers.utils.parseUnits("1210", 8), orderID4);
  await getPosition("userB position info", 2, orderID4);


  showTitle("userA,userC price 1300 remove liquidity");
  await removeLiquidity(userA, userALp._balance.toString());
  await getRmFee("userA remove liquidity fee:");

  await getBalanceInfo("user balance info", userA, userB, userC, userD, userE);
}


async function priceTest(deployer, userA, userB, userC, userD, userE) {

  showTitle("deploy contract");
  await deploy(deployer, 1, false);
  showTitle("init");
  await init(deployer, userA, userB, userC, userD, userE, true);


  const FastPriceFeed = await ethers.getContractFactory("FastPriceFeed");
  contract.fastPriceFeed = await FastPriceFeed.attach(contract.fastPriceFeed.address);

  const MarketPriceFeed = await ethers.getContractFactory("MarketPriceFeed");
  contract.marketPriceFeed = await MarketPriceFeed.attach(contract.marketPriceFeed.address);

  // showTitle("set _minBlockInterval = 100 block");
  await contract.fastPriceFeed.connect(deployer).setMinBlockInterval(0);//_minBlockInterval
  await contract.fastPriceFeed.connect(deployer).setMaxDeviationBasisPoints(500000, 500000);
  
  // showTitle("set price = 1000");
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await setPrice(deployer, ethers.utils.parseUnits("1000", 8));

  // showTitle("1 block delta set price = 1100");
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // try {
  //   await setPriceForTest(deployer, ethers.utils.parseUnits("1100", 8),time);
  // } catch (e) {
  //   console.log("set price error");
  // }
  
  // showTitle("set _maxTimeDeviation = 1s");
  // await contract.fastPriceFeed.connect(deployer).setMaxTimeDeviation(300);//_maxTimeDeviation
  //
  // let time = Date.parse(new Date()) / 1000 - 10;
  // showTitle("10s time delta set price = 1100");
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // try {
  //   await setPriceForTest(deployer, ethers.utils.parseUnits("1100", 8),time);
  // } catch (e) {
  //   console.log("set price error");
  // }

  
  showTitle("_maxPriceUpdateDelay set 5s");
  // //TODO get price abount time
  // await contract.fastPriceFeed.connect(deployer).setMaxPriceUpdateDelay(3600);//_maxPriceUpdateDelay 更新时间 1小时
  //
  // showTitle("set price = 1000");
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await setPrice(deployer, ethers.utils.parseUnits("1000", 8));
  //
  // await getAllPrice();
  //
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  
  showTitle("_priceDuration set 5s");
  // await contract.fastPriceFeed.connect(deployer).setPriceDuration(5, 300);//_priceDuration ，_indexPriceDuration
  // showTitle("set price = 1000");
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await setPrice(deployer, ethers.utils.parseUnits("1000", 8));
  //
  // await getAllPrice();
  //
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  
  showTitle("_maxDeviationBasisPoints set 100");
  // await contract.fastPriceFeed.connect(deployer).setMaxDeviationBasisPoints(100, 1000);//_maxDeviationBasisPoints, _indexMaxDeviationBasisPoints
  // showTitle("set price = 1000");
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setPrice(deployer, ethers.utils.parseUnits("1000", 8));
  //
  // await getAllPrice();
  //
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));
  // await sleep(1000);
  // await setOraclePrice(deployer, ethers.utils.parseUnits("900", 8));


  await getAllPrice();


  async function getAllPrice() {
    showTitle("get last price,offchain price ,chainlink price,trade price, index price");
    r = await contract.fastPriceFeed.prices("ETH_USD");
    console.log("offchain price:", ethers.utils.formatUnits(r.toString(), 10));

    r = await contract.marketPriceFeed.getLatestPrimaryPrice("ETH_USD");
    console.log("chaink price:", ethers.utils.formatUnits(r.toString(), 10));

    r = await contract.marketPriceFeed.priceForTrade("ETH_USD", false);
    console.log("trade min price:", ethers.utils.formatUnits(r.toString(), 10));

    r = await contract.marketPriceFeed.priceForTrade("ETH_USD", true);
    console.log("trade max price:", ethers.utils.formatUnits(r.toString(), 10));

    r = await contract.marketPriceFeed.priceForIndex("ETH_USD", false);
    console.log("index price:", ethers.utils.formatUnits(r.toString(), 10));
  }
}

async function init(deployer, userA, userB, userC, userD, userE, isMint) {
  const TestToken = await ethers.getContractFactory("TestToken");
  contract.testToken = await TestToken.attach(contract.testToken.address);

  const InviteManager = await ethers.getContractFactory("InviteManager");
  contract.inviteManager = await InviteManager.attach(contract.inviteManager.address);

  if (isMint) {
    r = await contract.testToken.connect(deployer).mint(userA.address, ethers.utils.parseUnits("10000", 18));
    r = await contract.testToken.connect(deployer).mint(userB.address, ethers.utils.parseUnits("10000", 18));
    r = await contract.testToken.connect(deployer).mint(userC.address, ethers.utils.parseUnits("10000", 18));
    r = await contract.testToken.connect(deployer).mint(userD.address, ethers.utils.parseUnits("10000", 18));
  }

  r = await contract.inviteManager.connect(userE).registerCode(ethers.utils.formatBytes32String("yfx"));
}

async function liquidate(deployer, id, action, price) {
  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  r = await contract.router.connect(deployer).liquidate(contract.market.address, id, action, ["ETH_USD"], [price], [Date.parse(new Date()).toString().substring(0, 10)]);
}

async function open(taker, margin, leverage, direction, code) {
  const TestToken = await ethers.getContractFactory("TestToken");
  contract.testToken = await TestToken.attach(contract.testToken.address);

  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  r = await contract.testToken.connect(taker).approve(contract.router.address, "100000000000000000000000000000000000");
  let params = {
    "_market": contract.market.address,
    "inviterCode": code,
    "minPrice": "1", //00000000000000000000",
    "maxPrice": "20000000000000000000000000000000000",// 00000000000000000000",
    "margin": margin,
    "leverage": leverage,
    "direction": direction,
    "triggerDirection": 0,
    "triggerPrice": 0,
    "deadline": "1687151195"
  };
  r = await contract.router.connect(taker).takerOpen(params, fee);
}

async function openTrigger(taker, margin, leverage, direction, code, triggleDirection, triggerPrice) {
  const TestToken = await ethers.getContractFactory("TestToken");
  contract.testToken = await TestToken.attach(contract.testToken.address);

  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  r = await contract.testToken.connect(taker).approve(contract.router.address, "100000000000000000000000000000000000");
  let params = {
    "_market": contract.market.address,
    "inviterCode": code,
    "minPrice": "1", //00000000000000000000",
    "maxPrice": "20000000000000000000000000000000000",// 00000000000000000000",
    "margin": margin,
    "leverage": leverage,
    "direction": direction,
    "triggerDirection": triggleDirection,
    "triggerPrice": triggerPrice,
    "deadline": "1687151195"
  };
  r = await contract.router.connect(taker).takerOpen(params, fee);
}

async function openETH(taker, margin, leverage, direction, code) {
  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  let params = {
    "_market": contract.market.address,
    "inviterCode": code,
    "minPrice": "1",
    "maxPrice": "20000000000000000000000000000000000",
    "margin": margin,
    "leverage": leverage,
    "direction": direction,
    "triggerDirection": 0,
    "triggerPrice": 0,
    "deadline": "1687151195"
  };
  let value = margin.add(ethers.utils.parseEther("0.0001"));
  console.log("value:", value.toString());
  let openVaule = { value: value.toString() };
  r = await contract.router.connect(taker).takerOpenETH(params, openVaule);
}

async function close(taker, id, amount, code) {
  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  let params = {
    "_market": contract.market.address,
    "id": id,
    "inviterCode": code,
    "minPrice": "1",
    "maxPrice": "20000000000000000000000000000000000",
    "amount": amount,
    "triggerDirection": 0,
    "triggerPrice": 0,
    "deadline": "1687151195"
  };
  r = await contract.router.connect(taker).takerClose(params, fee);
}

async function closeTrigger(taker, id, amount, code, direction, price) {
  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  let params = {
    "_market": contract.market.address,
    "id": id,
    "inviterCode": code,
    "minPrice": "1",
    "maxPrice": "20000000000000000000000000000000000",
    "amount": amount,
    "triggerDirection": direction,
    "triggerPrice": price,
    "deadline": "1687151195"
  };
  r = await contract.router.connect(taker).takerClose(params, fee);
}

async function addLiquidity(taker, amount) {
  const TestToken = await ethers.getContractFactory("TestToken");
  contract.testToken = await TestToken.attach(contract.testToken.address);

  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  r = await contract.testToken.connect(taker).approve(contract.router.address, "100000000000000000000000000000000000");
  r = await contract.router.connect(taker).addLiquidity(contract.pool.address, amount, "1687151195");
}

async function addLiquidityETH(taker, amount) {
  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  let value = { value: amount.toString() };
  r = await contract.router.connect(taker).addLiquidityETH(contract.pool.address, amount, "1687151195", value);
}

async function removeLiquidity(taker, lpAmount) {
  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  r = await contract.router.connect(taker).removeLiquidity(contract.pool.address, lpAmount, "1687151195");
}

async function removeLiquidityETH(taker, lpAmount) {
  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  r = await contract.router.connect(taker).removeLiquidityETH(contract.pool.address, lpAmount, "1687151195");
}

async function setPrice(deployer, price) {
  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  r = await contract.router.connect(deployer).setPrices(["ETH_USD"], [price], [Date.parse(new Date()).toString().substring(0, 10)]);
}

async function setPriceForTest(deployer, price, time) {
  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  r = await contract.router.connect(deployer).setPrices(["ETH_USD"], [price], time);
}


async function setOraclePrice(deployer, price) {
  const Oracle = await ethers.getContractFactory("OracleTest");
  contract.oracle = await Oracle.attach(contract.oracle.address);

  r = await contract.oracle.connect(deployer).setPrice(price);
}

async function executeOrder(deployer, price) {
  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  r = await contract.router.connect(deployer).batchExecuteOrder(contract.market.address, [], ["ETH_USD"], [price], [Date.parse(new Date()).toString().substring(0, 10)]);
}

async function executeOrderTrigger(deployer, price, triggerId) {
  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  r = await contract.router.connect(deployer).batchExecuteOrder(contract.market.address, [triggerId], ["ETH_USD"], [price], [Date.parse(new Date()).toString().substring(0, 10)]);
}

async function switchPositionMode(taker, mode) {
  const Router = await ethers.getContractFactory("Router");
  contract.router = await Router.attach(contract.router.address);

  r = await contract.router.connect(taker).switchPositionMode(contract.market.address, mode);
}

async function getPositionID(taker, direction) {
  const Periphery = await ethers.getContractFactory("Periphery");
  contract.periphery = await Periphery.attach(contract.periphery.address);

  return await contract.periphery.getPositionId(contract.market.address, taker.address, direction);
}

async function getOrderID(taker) {
  const Periphery = await ethers.getContractFactory("Periphery");
  contract.periphery = await Periphery.attach(contract.periphery.address);

  let ids = await contract.periphery.getOrderIds(contract.market.address, taker.address);
  return ids[ids.length - 1];
}

async function getTriggerOrderID() {
  const Market = await ethers.getContractFactory("Market");
  contract.market = await Market.attach(contract.market.address);

  let id = await contract.market.triggerOrderID();
  return id;
}

//ethers.utils.parseUnits("2000", 8)
//ethers.utils.formatEther()
async function getPosition(str, positionId, orderId) {
  const Periphery = await ethers.getContractFactory("Periphery");
  contract.periphery = await Periphery.attach(contract.periphery.address);

  const Pool = await ethers.getContractFactory("Pool");
  contract.pool = await Pool.attach(contract.pool.address);

  const Market = await ethers.getContractFactory("Market");
  contract.market = await Market.attach(contract.market.address);

  showTitle(str);

  r = await contract.periphery.getPositionStatus(contract.market.address, positionId);
  console.log("positionStatus", r.toString());

  r = await contract.periphery.getPosition(contract.market.address, positionId);
  let res = await contract.periphery.getOrder(contract.market.address, orderId);

  let poolData = await contract.pool.poolDataByMarkets(contract.market.address);
  let poolInterestData = await contract.pool.interestDate(-1);
  let poolInterestData1 = await contract.pool.interestDate(1);
  let sharePrice = { _price: 0 };
  try {
    sharePrice = await contract.pool.getSharePrice();
  } catch (e) {
    console.log(e);
  }

  let shortBIG = await contract.pool.getCurrentBorrowIG(-1);
  let longBIG = await contract.pool.getCurrentBorrowIG(1);

  let result = {
    "shortTotalBorrowShare": ethers.utils.formatEther(poolInterestData.totalBorrowShare.toString()),
    "longTotalBorrowShare": ethers.utils.formatEther(poolInterestData1.totalBorrowShare.toString()),
    "takerTotalMargin": ethers.utils.formatEther(poolData.takerTotalMargin.toString()),
    "poolSharePrice": sharePrice._price.toString(),
    "shortCurrentBorrowIg": shortBIG.toString(),
    "longCurrentBorrowIg": longBIG.toString(),

    "positionid": r._position.id.toString(),
    "direction": r._position.direction.toString(),
    "amount": ethers.utils.formatUnits(r._position.amount.toString(), 20),
    "value": ethers.utils.formatUnits(r._position.value.toString(), 20),
    "takerMargin": ethers.utils.formatEther(r._position.takerMargin.toString()),
    "makerMargin": ethers.utils.formatEther(r._position.makerMargin.toString()),
    "fundingPayment": ethers.utils.formatEther(r._position.fundingPayment.toString()),
    "debtShare": ethers.utils.formatEther(r._position.debtShare.toString()),
    "pnl": ethers.utils.formatEther(r._position.pnl.toString()),
    "lastUpdateTs": r._position.lastUpdateTs.toString(),

    "orderId": res.id.toString(),
    "takerFee": ethers.utils.formatEther(res.takerFee.toString()),
    "feeToInviter": ethers.utils.formatEther(res.feeToInviter.toString()),
    "feeToExchange": ethers.utils.formatEther(res.feeToExchange.toString()),
    "feeToMaker": ethers.utils.formatEther(res.feeToMaker.toString()),
    "feeToDiscount": ethers.utils.formatEther(res.feeToDiscount.toString()),
    "executeFee": ethers.utils.formatEther(res.executeFee.toString()),
    "rlzPnl": ethers.utils.formatEther(res.rlzPnl.toString()),
    "interestPayment": ethers.utils.formatEther(res.interestPayment.toString()),
    "settledfundingPayment": ethers.utils.formatEther(res.fundingPayment.toString()),
    // "toTaker": ethers.utils.formatEther(res.toTaker.toString()),
    "status": res.status.toString() == "1" ? "Opened" : "Fail or cenceled"
  };
  console.log(result);

  try {
    let liqPrice = await contract.periphery.getPositionLiqPrice(contract.market.address, positionId);
    console.log("liqPrice:", ethers.utils.formatUnits(liqPrice.toString(), 8));
  } catch (e) {

  }
}

async function getRmFee(str) {
  const Pool = await ethers.getContractFactory("Pool");
  contract.pool = await Pool.attach(contract.pool.address);

  let poolData = await contract.pool.cumulateRmLiqFee();
  console.log(str + ethers.utils.formatEther(poolData.toString()));
}

async function getBalanceInfo(str, userA, userB, userC, userD, userE, isWETH) {
  if (isWETH) {
    const TestToken = await ethers.getContractFactory("WETH9");
    contract.testToken = await TestToken.attach(contract.testToken.address);
  } else {
    const TestToken = await ethers.getContractFactory("TestToken");
    contract.testToken = await TestToken.attach(contract.testToken.address);
  }

  showTitle(str);
  let balanceA = await contract.testToken.balanceOf(userA.address);
  console.log("userA balance: ", ethers.utils.formatEther(balanceA.toString()));

  let balanceB = await contract.testToken.balanceOf(userB.address);
  console.log("userB balance: ", ethers.utils.formatEther(balanceB.toString()));

  let balanceC = await contract.testToken.balanceOf(userC.address);
  console.log("userC balance: ", ethers.utils.formatEther(balanceC.toString()));

  let balanceD = await contract.testToken.balanceOf(userD.address);
  console.log("userD balance: ", ethers.utils.formatEther(balanceD.toString()));

  let balanceE = await contract.testToken.balanceOf(userE.address);
  console.log("userE balance: ", ethers.utils.formatEther(balanceE.toString()));

  let balanceVault = await contract.testToken.balanceOf(contract.vault.address);
  console.log("vault balance: ", ethers.utils.formatEther(balanceVault.toString()));

  let balancePool = await contract.testToken.balanceOf(contract.pool.address);
  console.log("pool balance: ", ethers.utils.formatEther(balancePool.toString()));

  let riskfunding = await contract.testToken.balanceOf(contract.riskFunding.address);
  console.log("riskfunding balance: ", ethers.utils.formatEther(riskfunding.toString()));

  const Vault = await ethers.getContractFactory("Vault");
  contract.vault = await Vault.attach(contract.vault.address);
  let exchangeFee = await contract.vault.exchangeFees(contract.pool.address);
  console.log("exchangeFee: ", ethers.utils.formatEther(exchangeFee.toString()));

}

function showTitle(str) {
  console.log("=============================" + str + "=============================");
}


async function deploy(deployer, marketType, isWETH) {
  let overrides = { gasLimit: 5000000, gasPrice: 10000000000 };

  let r;
  const Manager = await ethers.getContractFactory("Manager");
  // contract. manager = await Manager.attach("0x9b2edB9e7F1835D311C094B20F00948C3C9F55b5");
  contract.manager = await Manager.deploy(deployer.address);
  await contract.manager.deployed();
  console.log(contract.manager.address);

  const UTP = await ethers.getContractFactory("TradeToken");
  // contract.utp = await UTP.attach("0x3b8691b698D1c07a1A38Aa13FC964cCf34216E1B");
  contract.utp = await UTP.deploy(contract.manager.address, 6, "YFX USDT-valued Trading Proof", "UTP");
  await contract.utp.deployed();
  console.log(contract.utp.address);

  const URP = await ethers.getContractFactory("TradeToken");
  // contract. urp = await URP.attach("0xa9E6D63EA7e7Bc534624546ADb6265dABe3b3640");
  contract.urp = await URP.deploy(contract.manager.address, 6, "YFX USDT-valued Referral Proof", "URP");
  await contract.urp.deployed();
  console.log(contract.urp.address);

  if (isWETH) {
    const TestToken = await ethers.getContractFactory("WETH9");
    // contract. testToken = await TestToken.attach("0x0da11CE4ff5C6448582d001F4ef5Bfa94534A0DB");
    contract.testToken = await TestToken.deploy();
    await contract.testToken.deployed();
    console.log(contract.testToken.address);
  } else {
    const TestToken = await ethers.getContractFactory("TestToken");
    // contract. testToken = await TestToken.attach("0x0da11CE4ff5C6448582d001F4ef5Bfa94534A0DB");
    contract.testToken = await TestToken.deploy("yUSDC", "yUSDC");
    await contract.testToken.deployed();
    console.log(contract.testToken.address);
  }

  const MarketLogic = await ethers.getContractFactory("MarketLogic");
  // contract. marketLogic = await MarketLogic.attach("0xfD76F9A6247c3517Cc496eD7880A60A15aE70a62");
  contract.marketLogic = await MarketLogic.deploy(contract.manager.address);
  await contract.marketLogic.deployed();
  console.log(contract.marketLogic.address);

  const FundingLogic = await ethers.getContractFactory("FundingLogic");
  // contract. fundingLogic = await FundingLogic.attach("0x60F715bf8fd297444743040f4714c9afA99c0D16");
  contract.fundingLogic = await FundingLogic.deploy(contract.manager.address, "100000000000000");
  await contract.fundingLogic.deployed();
  console.log(contract.fundingLogic.address);

  const InterestLogic = await ethers.getContractFactory("InterestLogic");
  // contract. interestLogic = await InterestLogic.attach("0xC3750BbFeF915743c9A2511a803C24Dbf8C79360");
  contract.interestLogic = await InterestLogic.deploy(contract.manager.address);
  await contract.interestLogic.deployed();
  console.log(contract.interestLogic.address);

  const RiskFunding = await ethers.getContractFactory("RiskFunding");
  // contract. riskFunding = await RiskFunding.attach("0x2F7DD9e1Be38205fdEa868A7C3785C77b48196E0");
  contract.riskFunding = await RiskFunding.deploy(contract.manager.address);
  await contract.riskFunding.deployed();
  console.log(contract.riskFunding.address);

  const InviteManager = await ethers.getContractFactory("InviteManager");
  // contract. inviteManager = await InviteManager.attach("0x3e6bD5b9F4c9234540f1511bcfccB2bdAf9e5B7c");
  contract.inviteManager = await InviteManager.deploy(contract.manager.address);
  await contract.inviteManager.deployed();
  console.log(contract.inviteManager.address);


  const Vault = await ethers.getContractFactory("Vault");
  // contract. vault = await Vault.attach("0xa378a8E85908c5CECf645d7A1525D1Bef55e76eb");
  contract.vault = await Vault.deploy(contract.manager.address, "0xa378a8E85908c5CECf645d7A1525D1Bef55e76eb");
  await contract.vault.deployed();
  console.log(contract.vault.address);

  const FastPriceFeed = await ethers.getContractFactory("FastPriceFeed");
  // contract. fastPriceFeed = await FastPriceFeed.attach("0xc3C6410db37e2dBf14F4EDEe3CdAc45C39d8de84");
  contract.fastPriceFeed = await FastPriceFeed.deploy(contract.manager.address, 300, 300, 3600, 0, 1000, 1000);
  await contract.fastPriceFeed.deployed();
  console.log(contract.fastPriceFeed.address);

  const MarketPriceFeed = await ethers.getContractFactory("MarketPriceFeed");
  // contract. marketPriceFeed = await MarketPriceFeed.attach("0x486a928b37a0F8099A7F508A040034Cc13EA74F1");
  contract.marketPriceFeed = await MarketPriceFeed.deploy(contract.manager.address);
  await contract.marketPriceFeed.deployed();
  console.log(contract.marketPriceFeed.address);

  const OracleTest = await ethers.getContractFactory("OracleTest");
  // contract. oracleTest = await OracleTest.attach("0x486a928b37a0F8099A7F508A040034Cc13EA74F1");
  contract.oracle = await OracleTest.deploy(contract.manager.address);
  await contract.oracle.deployed();
  console.log(contract.oracle.address);

  const Periphery = await ethers.getContractFactory("Periphery");
  // contract. periphery = await Periphery.attach("0x947c05134D0e99cA288eD7ad9F1A3Ef029506F56");
  contract.periphery = await Periphery.deploy(contract.manager.address, contract.marketPriceFeed.address);
  await contract.periphery.deployed();
  console.log(contract.periphery.address);

  const Router = await ethers.getContractFactory("Router");
  // contract. router = await Router.attach("0x25bc95EDD969f87446644085e3d19C05CdF452bD");
  contract.router = await Router.deploy(contract.manager.address, contract.testToken.address);//TODO different chain should be input different WETH address
  await contract.router.deployed();
  console.log(contract.router.address);

  //set inviteManager params
  r = await contract.inviteManager.connect(deployer).setTier(0, 100000, 100000);
  r = await contract.inviteManager.connect(deployer).setTradeToken(contract.utp.address);
  r = await contract.inviteManager.connect(deployer).setInviteToken(contract.urp.address);
  r = await contract.inviteManager.connect(deployer).setIsUTPPaused(false);
  r = await contract.inviteManager.connect(deployer).setIsURPPaused(false);

  //set fastPriceFeed params
  r = await contract.fastPriceFeed.connect(deployer).setMarketPriceFeed(contract.marketPriceFeed.address);
  r = await contract.fastPriceFeed.connect(deployer).setMaxTimeDeviation(3600);
  r = await contract.fastPriceFeed.connect(deployer).setSpreadBasisPointsIfInactive(20);
  r = await contract.fastPriceFeed.connect(deployer).setSpreadBasisPointsIfChainError(500);
  r = await contract.fastPriceFeed.connect(deployer).setIsSpreadEnabled(false);
  r = await contract.fastPriceFeed.connect(deployer).setPriceDataInterval(60);
  r = await contract.fastPriceFeed.connect(deployer).setMinAuthorizations(1);
  // r = await marketPriceFeed.connect(deployer).setChainlinkFlags("0x3c14e07edd0dc67442fa96f1ec6999c57e810a83");
  r = await contract.marketPriceFeed.connect(deployer).setSecondaryPriceFeed(contract.fastPriceFeed.address);
  r = await contract.marketPriceFeed.connect(deployer).setIsSecondaryPriceEnabled(true);
  r = await contract.marketPriceFeed.connect(deployer).setPriceSampleSpace(1);
  r = await contract.marketPriceFeed.connect(deployer).setMaxStrictPriceDeviation("100000000");


  //add pair should be done by controller
  r = await contract.fastPriceFeed.connect(deployer).setTokens(["ETH_USD", "BTC_USD"], [8, 8]);
  r = await contract.fastPriceFeed.connect(deployer).setMaxCumulativeDeltaDiffs(["ETH_USD"], [1000000]);
  r = await contract.marketPriceFeed.connect(deployer).setAdjustment("ETH_USD", false, 0);
  r = await contract.marketPriceFeed.connect(deployer).setSpreadBasisPoints("ETH_USD", 0);
  r = await contract.marketPriceFeed.connect(deployer).setTokenConfig("ETH_USD", contract.oracle.address, 8, false);//arbtrium goerli


  //set manager params
  r = await contract.manager.connect(deployer).modifyLiquidator(deployer.address, true);
  r = await contract.manager.connect(deployer).modifyRiskFunding(contract.riskFunding.address);
  r = await contract.manager.connect(deployer).modifyOrderNumLimit(5);
  r = await contract.manager.connect(deployer).modifyRouter(contract.router.address);
  r = await contract.manager.connect(deployer).addSigner("0xA4Eb0145DBC63a4871aC6Cab039612A1D9224cA7");
  r = await contract.manager.connect(deployer).addSigner(deployer.address);
  r = await contract.manager.connect(deployer).modifyVault(contract.vault.address);
  // r = await manager.connect(deployer).modifyExecuteLiquidateFee(deployer.address);
  r = await contract.manager.connect(deployer).modifyInviteManager(contract.inviteManager.address);
  r = await contract.manager.connect(deployer).modifyCancelElapse(300);
  r = await contract.manager.connect(deployer).modifyCommunityExecuteOrderDelay(600);
  r = await contract.manager.connect(deployer).modifyTriggerOrderDuration(604800);
  r = await contract.manager.connect(deployer).modifyFundingStatus(false);
  r = await contract.manager.connect(deployer).unpause();

  r = await contract.fundingLogic.connect(deployer).updateMarketPriceFeed(contract.marketPriceFeed.address);
  r = await contract.marketLogic.connect(deployer).updateMarketPriceFeed(contract.marketPriceFeed.address);
  r = await contract.riskFunding.connect(deployer).setExecuteLiquidateFee("5000000000000000000");

  const Pool = await ethers.getContractFactory("Pool");
  contract.pool = await Pool.deploy(contract.manager.address, contract.testToken.address, "0xa378a8E85908c5CECf645d7A1525D1Bef55e76eb", "YFX LP (USDC)", "YFX LP (USDC)");
  await contract.pool.deployed();
  console.log(contract.pool.address);

  const Market = await ethers.getContractFactory("Market");
  contract.market = await Market.deploy(contract.manager.address, contract.marketLogic.address, contract.fundingLogic.address);
  await contract.market.deployed();
  console.log(contract.market.address);

  //set pool param interestLogic address
  r = await contract.pool.connect(deployer).setInterestLogic(contract.interestLogic.address);
  r = await contract.pool.connect(deployer).setMarketPriceFeed(contract.marketPriceFeed.address);
  // set pen rate and open limit
  // openFunds = min(80%, 100000)
  r = await contract.pool.connect(deployer).setOpenRateAndLimit(contract.market.address, 1e6, ethers.utils.parseEther("10000000"));
  //0.0001 / hour , 0.000100000000000000000000000 * 1e27 = 100000000000000000000000
  r = await contract.interestLogic.connect(deployer).updateRatePerHour(contract.pool.address, "100000000000000000000000");

  //set Router params
  r = await contract.router.connect(deployer).setConfigParams(contract.fastPriceFeed.address, contract.riskFunding.address, contract.inviteManager.address, contract.marketLogic.address, 10);

  //set Market params
  let config = {
    "mm": 5000,
    "liquidateRate": 2000,
    "tradeFeeRate": 500,
    "makerFeeRate": 0,
    "createOrderPaused": false,
    "setTPSLPricePaused": false,
    "createTriggerOrderPaused": false,
    "updateMarginPaused": false,
    "multiplier": marketType == 2 ? 100000 : 1000000,
    "marketAssetPrecision": ethers.utils.parseUnits("1", 18),
    "DUST": ethers.utils.parseUnits("1", 10),
    "takerLeverageMin": 1,
    "takerLeverageMax": 100,
    "dMMultiplier": 2,
    "takerMarginMin": ethers.utils.parseUnits("10", 18),
    "takerMarginMax": ethers.utils.parseUnits("10000", 18),
    "takerValueMin": ethers.utils.parseUnits("100", 20),
    "takerValueMax": ethers.utils.parseUnits("10000", 20),
    "takerValueLimit": ethers.utils.parseUnits("300000", 20)
  };

  //create pair
  r = await contract.manager.connect(deployer).createPair(contract.pool.address, contract.market.address, "ETH_USD", contract.testToken.address, marketType, config, overrides);
}

function sleep(time) {
  return new Promise((resolve) => setTimeout(resolve, time));
}


/**
 * 1.singleUserTest 
 * 2.multipleUserTest
 * 3.triggerOrderTest
 * 4.postionModeTest
 * 5.increaseOrDecreseMarginTest
 * 6.errorPriceTest
 * 7.tpslTest
 * 8.liquiditeTest
 * 9.priceTest
 */
async function main() {
  let [deployer, userA, userB, userC, userD, userE] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Account balance:", (await deployer.getBalance()).toString());
  console.log("Deploying contracts with the account:", userA.address);
  console.log("Deploying contracts with the account:", userC.address);
  console.log("Deploying contracts with the account:", userD.address);
  console.log("Deploying contracts with the account:", userE.address);

  //marketType 0,1,2
  await singleUserTest(deployer, userA, userB, userC, userD, userE, 0);
}


main().then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
