// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlumbBidVault} from "../../src/PlumbBidVault.sol";
import {ICLGauge} from "../../src/interfaces/IMezoCL.sol";
import {IMUSDSavingsRate} from "../../src/interfaces/IMUSDSavingsRate.sol";
import {PrecompileERC20} from "../mocks/PrecompileERC20.sol";
import {MezoFork, Mezo} from "./MezoFork.sol";

/// Replays the thinnest moment in the depth history: block 12,685,218 on Oct 22, when a
/// 10,000 MUSD sale on the MUSD/mUSDC pool would have paid about $11. What would the same
/// sale have paid with a $25k Plumb bid in the book?
contract Oct22ReplayForkTest is MezoFork {
    uint256 internal constant OCT22_BLOCK = 12_685_218;

    function test_oct22SaleWithAndWithoutPlumb() public {
        vm.createSelectFork(vm.envString("MEZO_RPC_URL"), OCT22_BLOCK);
        vm.etch(Mezo.MEZO, address(new PrecompileERC20()).code);
        deal(Mezo.MEZO, Mezo.GAUGE, 50_000_000e18);

        uint256 without = _quoteSellMusd(10_000e18);

        PlumbBidVault vault = new PlumbBidVault(
            PlumbBidVault.Params({
                pool: pool,
                nfpm: nfpm,
                gauge: gauge,
                smusd: IMUSDSavingsRate(Mezo.SMUSD),
                usd: Mezo.MUSDC,
                musd: Mezo.MUSD,
                treasury: makeAddr("treasury"),
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
        address lp = makeAddr("lp");
        deal(Mezo.MUSDC, lp, 25_000e6);
        vm.startPrank(lp);
        IERC20(Mezo.MUSDC).approve(address(vault), 25_000e6);
        vault.depositAndDeploy(25_000e6, 0, lp);
        vm.stopPrank();

        uint256 with = _quoteSellMusd(10_000e18);
        console2.log("Oct 22, USD for 10k MUSD without Plumb:", without);
        console2.log("Oct 22, USD for 10k MUSD with $25k bid:", with);
        assertLt(without, 100e6);
        assertGt(with, 9_500e6);
    }
}
