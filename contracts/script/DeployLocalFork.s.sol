// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {PlumbBidVault} from "../src/PlumbBidVault.sol";
import {ICLPool, INonfungiblePositionManager, ICLGauge} from "../src/interfaces/IMezoCL.sol";
import {IMUSDSavingsRate} from "../src/interfaces/IMUSDSavingsRate.sol";

/// For keeper and app testing on a local anvil fork of Mezo mainnet. The gauge is left out
/// because anvil cannot execute Mezo's MEZO precompile.
contract DeployLocalFork is Script {
    function run() external {
        vm.startBroadcast();
        PlumbBidVault vault = new PlumbBidVault(
            PlumbBidVault.Params({
                pool: ICLPool(0xCC372B7E15535aB225fe17c1075831D38ef7aC1a),
                nfpm: INonfungiblePositionManager(0x509Bc221df2B83927c695FA0bb0f5B21053C874c),
                gauge: ICLGauge(address(0)),
                smusd: IMUSDSavingsRate(0xb4D498029af77680cD1eF828b967f010d06C51CC),
                usd: 0x04671C72Aab5AC02A03c1098314b1BB6B560c197,
                musd: 0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186,
                treasury: msg.sender,
                incentiveSink: address(0),
                twapWindow: 1800,
                maxTwapDeviation: 30,
                bidWidth: 200,
                askWidth: 50,
                floorDepeg: 400,
                nearParDepeg: 20,
                maxInventoryBps: 6_000,
                feeBps: 1_000,
                incentiveBps: 0,
                keeperBps: 100,
                minRebalanceInterval: 10 minutes,
                depositCap: 0
            }),
            "Plumb MUSD Bid",
            "plumbBID"
        );
        vm.stopBroadcast();
        console2.log("vault", address(vault));
    }
}
