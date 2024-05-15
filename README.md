# YFX Contract V4 Core

YFX is a decentralized perpetual exchange with up to 100x leverage, high liquidity, low fees, and no transaction slippage.
YFX adopts the PvPool (PvP) trading mechanism, allowing traders and liquidity pools to trade directly. Liquidity providers can add or remove liquidity for linear, inverse, and quanto contracts to or from single-asset pools with no impermanent loss. Liquidity providers can earn transaction fees and profit from selling LP tokens at a higher price.

## WebSites
|  Chain |  Domain  |
| ------------ | ------------ |
|Main| [https://www.yfx.com/](https://www.yfx.com/?utm_source=github "https://www.yfx.com/")  |
|Arbitrum (v4)| [https://app.yfx.com/](https://app.yfx.com/?utm_source=github "https://app.yfx.com/")|

## QuickStart
```shell
npm install
hardhat compile
```
## Audit Report

- Certick: [https://skynet.certik.com/projects/yfx](https://skynet.certik.com/projects/yfx)

## Deployed Addresses (Arbitrum One)

- Main Contract

| Contract | Address  |	
|:--------| :---------|
|Manager.sol| [0xFE1ca968afbadEd3BF2CB685451C858Deb46Ce31](https://arbiscan.io/address/0xFE1ca968afbadEd3BF2CB685451C858Deb46Ce31) |
|MarketLogic.sol|[0xd5bF2fdAf3a44198C50EB82223F4a3fcfa3575da](https://arbiscan.io/address/0xd5bF2fdAf3a44198C50EB82223F4a3fcfa3575da)|
|Order.sol|[0xf87Bd7eEC985fb13E903EEF0E2C1f53a73537477](https://arbiscan.io/address/0xf87Bd7eEC985fb13E903EEF0E2C1f53a73537477)|
|FundingLogic.sol|[0xcFF03d6414Df38568E375F43c5E2eF539da6438a](https://arbiscan.io/address/0xcFF03d6414Df38568E375F43c5E2eF539da6438a)|
|InterestLogic.sol|[0x0aCEeA0486F3Bcc178D069De4C9133FF2697a7C2](https://arbiscan.io/address/0x0aCEeA0486F3Bcc178D069De4C9133FF2697a7C2)|
|RiskFunding.sol|[0x3c6DBAed544b49C71E2b6f4bb75c010EE15C1a53](https://arbiscan.io/address/0x3c6DBAed544b49C71E2b6f4bb75c010EE15C1a53)|
|InviteManager.sol|[0x39c28F77c6B5D84a4CbF1cA3d84d705912e78523](https://arbiscan.io/address/0x39c28F77c6B5D84a4CbF1cA3d84d705912e78523)|
|Vault.sol|[0x50b516a9DB620aB67A33d895DAF4Bd1c294b9517](https://arbiscan.io/address/0x50b516a9DB620aB67A33d895DAF4Bd1c294b9517)|
|FastPriceFeed.sol|[0x91D8645D1c693173D7E6173052dF77D4ACcC8407](https://arbiscan.io/address/0x91D8645D1c693173D7E6173052dF77D4ACcC8407)|
|PriceHelper.sol|[0x01706Ed01c9BBA4a9c80313de48caEDF301E0d0a](https://arbiscan.io/address/0x01706Ed01c9BBA4a9c80313de48caEDF301E0d0a)|
|MarketPriceFeed.sol|[0xa8F067A0da170e60203a5f0bcDD3C93C546e0d9C](https://arbiscan.io/address/0xa8F067A0da170e60203a5f0bcDD3C93C546e0d9C)|
|Periphery.sol|[0xD95507eb291a59e6B8b0BfBae4Da884Cc58cE395](https://arbiscan.io/address/0xD95507eb291a59e6B8b0BfBae4Da884Cc58cE395)|
|PeripheryForEarn.sol|[0x4336E9073979c66caabEb9c5BEf47D15234E891f](https://arbiscan.io/address/0x4336E9073979c66caabEb9c5BEf47D15234E891f)|
|Router.sol|[0xcC619251bB94b7605A7Ea7391fEB7D18C32552D5](https://arbiscan.io/address/0xcC619251bB94b7605A7Ea7391fEB7D18C32552D5)|
|ExecutorRouter.sol|[0x326c2022F0eb6979d78B6e6E64b5b7d2A143aEc2](https://arbiscan.io/address/0x326c2022F0eb6979d78B6e6E64b5b7d2A143aEc2)|

- Markets

| Market Symbol | Margin Asset | Type | Address | Pool |
|:-------------------|:------------------|:-----------------|:--------------|:--------------|
| BTC_USD | [USDC](https://arbiscan.io/address/0xaf88d065e77c8cC2239327C5EDb3A432268e5831) | Linear | [0x2C05422A5Ea16c9AcB104cFD874aE2eFaf4b9945](https://arbiscan.io/address/0x2C05422A5Ea16c9AcB104cFD874aE2eFaf4b9945) |[0x10FAd92D4A3ae2AB1a1238850A5bd0B62E3a686c](https://arbiscan.io/address/0x10FAd92D4A3ae2AB1a1238850A5bd0B62E3a686c) |
| ETH_USD | [USDC](https://arbiscan.io/address/0xaf88d065e77c8cC2239327C5EDb3A432268e5831) | Linear | [0x9eF06FEA110F3AB5865726EcFECb21378B2ffdd0](https://arbiscan.io/address/0x9eF06FEA110F3AB5865726EcFECb21378B2ffdd0) |[0x2169318670BaCcfc5c6BD126bAc61Fc7abf5b20A](https://arbiscan.io/address/0x2169318670BaCcfc5c6BD126bAc61Fc7abf5b20A) |
| ARB_USD | [USDC](https://arbiscan.io/address/0xaf88d065e77c8cC2239327C5EDb3A432268e5831) | Linear | [0x6A5f6e627C8Bc8ff88bF6C38c38DA00FBeec79A1](https://arbiscan.io/address/0x6A5f6e627C8Bc8ff88bF6C38c38DA00FBeec79A1) |[0x79e107c3F9Fabae9D1830DB0BB1238D0eB7DccA0](https://arbiscan.io/address/0x79e107c3F9Fabae9D1830DB0BB1238D0eB7DccA0) |
| SOL_USD | [USDC](https://arbiscan.io/address/0xaf88d065e77c8cC2239327C5EDb3A432268e5831) | Linear | [0x60bb481fa62E451dD5eC33a60bAdc947C44Fe241](https://arbiscan.io/address/0x60bb481fa62E451dD5eC33a60bAdc947C44Fe241) |[0x888630Ea8f1480CA616B133b3dC62cB36F318f1e](https://arbiscan.io/address/0x888630Ea8f1480CA616B133b3dC62cB36F318f1e) |
| DOGE_USD | [USDC](https://arbiscan.io/address/0xaf88d065e77c8cC2239327C5EDb3A432268e5831) | Linear | [0x6AEacEc464e7F563013faccEF33b2Cf7F57D59c0](https://arbiscan.io/address/0x6AEacEc464e7F563013faccEF33b2Cf7F57D59c0) | [0x157EDcd0A7C6eF96E296EA06D489244F872BDbfa](https://arbiscan.io/address/0x157EDcd0A7C6eF96E296EA06D489244F872BDbfa) |
| ETH_USD | [ETH](https://arbiscan.io/address/0x82aF49447D8a07e3bd95BD0d56f35241523fBab1)| Inverse | [0xDAbBE11e04a7417BeAA3Fe3FabC03014e8158Fbd](https://arbiscan.io/address/0xDAbBE11e04a7417BeAA3Fe3FabC03014e8158Fbd) |[0xF96C4c923Fc500ba49160F1Cab504646456d31A5](https://arbiscan.io/address/0xF96C4c923Fc500ba49160F1Cab504646456d31A5) |
| ARB_USD | [ARB](https://arbiscan.io/address/0x912CE59144191C1204E64559FE8253a0e49E6548)| Inverse | [0x990809b7a5F470AC15FB63A26E7427F01fC703B9](https://arbiscan.io/address/0x990809b7a5F470AC15FB63A26E7427F01fC703B9) |[0x2a79b129Ae673e853E8Dea173849d226cf2a5a50](https://arbiscan.io/address/0x2a79b129Ae673e853E8Dea173849d226cf2a5a50) |
| BTC_USD | [ARB](https://arbiscan.io/address/0x912CE59144191C1204E64559FE8253a0e49E6548)| Quanto | [0x99B310BAD4E13bE39121CD44FA3Aeb726b1Fa5Ab](https://arbiscan.io/address/0x99B310BAD4E13bE39121CD44FA3Aeb726b1Fa5Ab) |[0xa4a7C69A46CDE5B956D4b312a4143932d0b4fBFd](https://arbiscan.io/address/0xa4a7C69A46CDE5B956D4b312a4143932d0b4fBFd) |
| ETH_USD | [ARB](https://arbiscan.io/address/0x912CE59144191C1204E64559FE8253a0e49E6548)| Quanto | [0x41b98BD7e577D61142d64cdb6b94011C636fBaf2](https://arbiscan.io/address/0x41b98BD7e577D61142d64cdb6b94011C636fBaf2) |[0x1e5Ad8D74680122Cc8fc27A85f883Bd6fcBDeF3d](https://arbiscan.io/address/0x1e5Ad8D74680122Cc8fc27A85f883Bd6fcBDeF3d) |
| BTC_USD | [YFX](https://arbiscan.io/address/0x569deb225441fd18bde18aed53e2ec7eb4e10d93)| Quanto | [0xC57eA5D83598761B6a899649DAD8f7A2A3df49De](https://arbiscan.io/address/0xC57eA5D83598761B6a899649DAD8f7A2A3df49De) |[0x7dfe5D32C7f61C4aAbC40443C7ad13F38EDBb6DA](https://arbiscan.io/address/0x7dfe5D32C7f61C4aAbC40443C7ad13F38EDBb6DA) |
| ETH_USD | [YFX](https://arbiscan.io/address/0x569deb225441fd18bde18aed53e2ec7eb4e10d93)| Quanto | [0xD7a9479ae09F46DD09E143C424fC002563E9296F](https://arbiscan.io/address/0xD7a9479ae09F46DD09E143C424fC002563E9296F) |[0xdF90d70dA2282202D065E0b48113C0231d5A0c84](https://arbiscan.io/address/0xdF90d70dA2282202D065E0b48113C0231d5A0c84) |
