// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {PlumbBidVault} from "../src/PlumbBidVault.sol";
import {PegMath} from "../src/libraries/PegMath.sol";
import {ICLPool, ICLFactory, INonfungiblePositionManager, ICLGauge} from "../src/interfaces/IMezoCL.sol";
import {IMUSDSavingsRate} from "../src/interfaces/IMUSDSavingsRate.sol";

/// Deploys Plumb on Mezo testnet (chain 31611).
///
/// Testnet has no MUSD/mUSDC concentrated pool, so this script creates one with the same
/// fee tier and tick spacing as mainnet, opens it at the mainnet price ($0.99), and seeds
/// it with a MUSD sell wall shaped like mainnet's (MUSD offered from $0.99 up to $1.00).
/// Mezo's testnet gauge voter has not whitelisted mUSDC, so the vault runs without a gauge.
///
/// Env:
///   PRIVATE_KEY        deployer key (testnet only)
///   WALL_MUSD          MUSD to seed as the sell wall, in wei (default 1000e18)
///   TWAP_WINDOW        seconds (default 600 on testnet so the demo is usable sooner)
contract DeployTestnet is Script {
    address constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address constant MUSDC = 0xe1a26db653708A2AD8F824E92Db9852410e33A59;
    ICLFactory constant FACTORY = ICLFactory(0x7B61BC8Aa460476d142F1CD107A47297002f69ff);
    INonfungiblePositionManager constant NFPM =
        INonfungiblePositionManager(0x9B753e11bFEd0D88F6e1D2777E3c7dac42F96062);
    int24 constant SPACING = 10;
    int24 constant OPEN_DEPEG = 100; // $0.99, where mainnet trades today

    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);
        uint256 wall = vm.envOr("WALL_MUSD", uint256(1_000e18));
        uint32 twapWindow = uint32(vm.envOr("TWAP_WINDOW", uint256(600)));

        // On testnet MUSD sorts before mUSDC, so USD is token1: the mirror of mainnet.
        bool usdIsToken0 = MUSDC < MUSD;
        int24 dir = PegMath.direction(usdIsToken0);
        int24 exactPar = PegMath.parTick(usdIsToken0, 12);
        int24 par = dir > 0 ? PegMath.floorToSpacing(exactPar, SPACING) : PegMath.ceilToSpacing(exactPar, SPACING);

        vm.startBroadcast(key);

        address pool = FACTORY.getPool(MUSD, MUSDC, SPACING);
        if (pool == address(0)) {
            int24 openTick = PegMath.toTick(OPEN_DEPEG, par, dir);
            pool = FACTORY.createPool(MUSD, MUSDC, SPACING, TickMath.getSqrtRatioAtTick(openTick));
            ICLPool(pool).increaseObservationCardinalityNext(200);
            console2.log("created pool", pool);
        }

        // Seed the sell wall: MUSD-only liquidity from just above the price up to $1.
        if (wall > 0 && IERC20(MUSD).balanceOf(deployer) >= wall) {
            (int24 tl, int24 tu) = PegMath.toTickRange(0, OPEN_DEPEG - SPACING, par, dir);
            IERC20(MUSD).approve(address(NFPM), wall);
            (address t0, address t1) = MUSD < MUSDC ? (MUSD, MUSDC) : (MUSDC, MUSD);
            NFPM.mint(
                INonfungiblePositionManager.MintParams({
                    token0: t0,
                    token1: t1,
                    tickSpacing: SPACING,
                    tickLower: tl,
                    tickUpper: tu,
                    amount0Desired: t0 == MUSD ? wall : 0,
                    amount1Desired: t1 == MUSD ? wall : 0,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: deployer,
                    // Generous deadline: forge stamps block.timestamp from its local simulation,
                    // which is already in the past when the real transaction is mined.
                    deadline: block.timestamp + 1 hours,
                    sqrtPriceX96: 0
                })
            );
        }

        PlumbBidVault vault = new PlumbBidVault(
            PlumbBidVault.Params({
                pool: ICLPool(pool),
                nfpm: NFPM,
                gauge: ICLGauge(address(0)),
                smusd: IMUSDSavingsRate(address(0)),
                usd: MUSDC,
                musd: MUSD,
                treasury: deployer,
                incentiveSink: address(0),
                twapWindow: twapWindow,
                maxTwapDeviation: 30,
                bidWidth: 200,
                askWidth: 50,
                floorDepeg: 400,
                nearParDepeg: 20,
                maxInventoryBps: 6_000,
                feeBps: 1_000,
                incentiveBps: 0,
                keeperBps: 100,
                minRebalanceInterval: 5 minutes,
                depositCap: 0
            }),
            "Plumb MUSD Bid",
            "plumbBID"
        );
        vm.stopBroadcast();

        console2.log("pool ", pool);
        console2.log("vault", address(vault));
        // The deployment file is written by scripts/record-testnet.sh only after checking that
        // each address has code on chain, so a failed or simulated run can't leave fake addresses.
    }
}
