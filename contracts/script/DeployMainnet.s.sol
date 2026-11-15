// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {PlumbBidVault} from "../src/PlumbBidVault.sol";
import {ICLPool, INonfungiblePositionManager, ICLGauge, IPoolsVoter} from "../src/interfaces/IMezoCL.sol";
import {IMUSDSavingsRate} from "../src/interfaces/IMUSDSavingsRate.sol";

/// Deploys a capped Plumb vault on Mezo mainnet (chain 31612): the real MUSD/mUSDC pool, its
/// gauge, sMUSD for bought MUSD, and the gauge's voting-reward contract for the 10% of MEZO
/// that goes back to veBTC voters on this pool.
///
/// Book: a one-slot band on the live price, then a bid from the band's cheap edge down
/// 140 ticks (to about $0.98). No bids or deposits below $0.97.
///
/// Env:
///   PRIVATE_KEY   deployer key; the deployer is also the treasury that receives the 10% fee
///   DEPOSIT_CAP   most USD the vault accepts, in mUSDC raw units (6 decimals). Required.
contract DeployMainnet is Script {
    address constant MUSD = 0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186;
    address constant MUSDC = 0x04671C72Aab5AC02A03c1098314b1BB6B560c197;
    address constant POOL = 0xCC372B7E15535aB225fe17c1075831D38ef7aC1a;
    address constant NFPM = 0x509Bc221df2B83927c695FA0bb0f5B21053C874c;
    address constant GAUGE = 0x6d446E27505c71EE39D632488cE849fEF6aFFc57;
    address constant POOLS_VOTER = 0x48233cCC97B87Ba93bCA212cbEe48e3210211f03;
    address constant SMUSD = 0xb4D498029af77680cD1eF828b967f010d06C51CC;

    function run() external returns (PlumbBidVault vault) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        uint256 cap = vm.envUint("DEPOSIT_CAP");
        require(cap > 0 && cap <= 100_000e6, "set DEPOSIT_CAP (max 100k mUSDC)");
        address deployer = vm.addr(key);
        address bribe = IPoolsVoter(POOLS_VOTER).gaugeToBribe(GAUGE);
        require(ICLGauge(GAUGE).pool() == POOL, "gauge/pool mismatch");

        vm.startBroadcast(key);
        vault = new PlumbBidVault(
            PlumbBidVault.Params({
                pool: ICLPool(POOL),
                nfpm: INonfungiblePositionManager(NFPM),
                gauge: ICLGauge(GAUGE),
                smusd: IMUSDSavingsRate(SMUSD),
                usd: MUSDC,
                musd: MUSD,
                treasury: deployer,
                incentiveSink: bribe,
                twapWindow: 1800,
                maxTwapDeviation: 30,
                bidWidth: 140,
                askWidth: 50,
                floorDepeg: 300,
                nearParDepeg: 20,
                maxInventoryBps: 6_000,
                feeBps: 1_000,
                incentiveBps: 1_000,
                keeperBps: 100,
                minRebalanceInterval: 30 minutes,
                depositCap: cap,
                bandWidth: 10,
                bandBps: 5_000
            }),
            "Plumb MUSD Bid",
            "plumbBID"
        );
        vm.stopBroadcast();

        console2.log("vault", address(vault));
        console2.log("bribe", bribe);
        console2.log("depeg ticks now", vault.currentDepeg());
    }
}
