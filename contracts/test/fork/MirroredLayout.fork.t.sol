// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {PlumbBidVault} from "../../src/PlumbBidVault.sol";
import {PegMath} from "../../src/libraries/PegMath.sol";
import {ICLPool, ICLFactory, INonfungiblePositionManager, ICLGauge} from "../../src/interfaces/IMezoCL.sol";
import {ICLSwapRouter} from "../../src/interfaces/ICLSwapRouter.sol";
import {IMUSDSavingsRate} from "../../src/interfaces/IMUSDSavingsRate.sol";
import {MockUSD} from "../mocks/MockUSD.sol";
import {MezoFork, Mezo} from "./MezoFork.sol";

/// On Mezo testnet, MUSD sorts before mUSDC, so USD is token1: the mirror of mainnet.
/// This suite builds that layout on the mainnet fork with Mezo's real CL factory and runs the
/// vault through its whole life, which is exactly what DeployTestnet.s.sol sets up.
contract MirroredLayoutForkTest is MezoFork {
    ICLFactory internal constant FACTORY = ICLFactory(0xBB24AF5c6fB88F1d191FA76055e30BF881BeEb79);
    // Above MUSD (0xdD46...) so that MUSD becomes token0.
    address internal constant USD = 0xFFfffFFfFFfffFfFffFFfFfFfFffFfffFFFFFf01;

    ICLPool internal mirrored;
    PlumbBidVault internal vault;
    address internal alice = makeAddr("alice");

    function setUp() public {
        _fork();
        vm.etch(USD, address(new MockUSD()).code);

        int24 exact = PegMath.parTick(false, 12);
        int24 par = PegMath.ceilToSpacing(exact, 10);
        int24 open = PegMath.toTick(100, par, -1); // $0.99
        mirrored = ICLPool(FACTORY.createPool(Mezo.MUSD, USD, 10, TickMath.getSqrtRatioAtTick(open)));
        mirrored.increaseObservationCardinalityNext(100);
        assertEq(mirrored.token0(), Mezo.MUSD, "MUSD must be token0 here");

        // Mainnet-shaped book: 50k MUSD offered from $0.99 to $1.00, and a thin bid.
        (int24 a, int24 b) = PegMath.toTickRange(0, 90, par, -1);
        _mint(a, b, 50_000e18, 0);
        (a, b) = PegMath.toTickRange(110, 150, par, -1);
        _mint(a, b, 0, 2_000e6);
        _settle(1 hours); // build TWAP history

        vault = new PlumbBidVault(
            PlumbBidVault.Params({
                pool: mirrored,
                nfpm: nfpm,
                gauge: ICLGauge(address(0)),
                smusd: IMUSDSavingsRate(Mezo.SMUSD),
                usd: USD,
                musd: Mezo.MUSD,
                treasury: makeAddr("treasury"),
                incentiveSink: address(0),
                twapWindow: 600,
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
                depositCap: 0,
                bandWidth: 0,
                bandBps: 0
            }),
            "Plumb MUSD Bid",
            "plumbBID"
        );
    }

    function _mint(int24 tl, int24 tu, uint256 musdAmt, uint256 usdAmt) internal {
        address lp = makeAddr("lp");
        deal(Mezo.MUSD, lp, musdAmt);
        deal(USD, lp, usdAmt);
        vm.startPrank(lp);
        IERC20(Mezo.MUSD).approve(address(nfpm), musdAmt);
        IERC20(USD).approve(address(nfpm), usdAmt);
        nfpm.mint(
            INonfungiblePositionManager.MintParams({
                token0: Mezo.MUSD,
                token1: USD,
                tickSpacing: 10,
                tickLower: tl,
                tickUpper: tu,
                amount0Desired: musdAmt,
                amount1Desired: usdAmt,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp,
                deadline: block.timestamp,
                sqrtPriceX96: 0
            })
        );
        vm.stopPrank();
    }

    function _sell(address tokenIn, address tokenOut, uint256 amount) internal returns (uint256) {
        address t = makeAddr("trader");
        deal(tokenIn, t, amount);
        vm.startPrank(t);
        IERC20(tokenIn).approve(address(router), amount);
        uint256 out = router.exactInputSingle(
            ICLSwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                tickSpacing: 10,
                recipient: t,
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
        return out;
    }

    function _deposit(uint256 amount) internal returns (uint256 shares) {
        deal(USD, alice, amount);
        vm.startPrank(alice);
        IERC20(USD).approve(address(vault), amount);
        shares = vault.depositAndDeploy(amount, 0, alice);
        vm.stopPrank();
    }

    function test_layoutIsMirrored() public view {
        assertFalse(vault.usdIsToken0());
        assertEq(vault.dir(), -1);
        assertApproxEqAbs(vault.currentDepeg(), 100, 1);
    }

    function test_bidSitsBelowMarketInMirroredLayout() public {
        _deposit(10_000e6);
        (uint256 id,) = vault.bid();
        (,,,,, int24 tl, int24 tu,,,,,) = nfpm.positions(id);
        (, int24 spot,,,,) = mirrored.slot0();
        // USD is token1: cheaper MUSD means a LOWER tick, so the bid sits below the spot tick.
        assertLt(tu, spot);
        (,,, uint256 bidUsd, uint256 bidMusd,,) = vault.holdings();
        assertEq(bidMusd, 0);
        assertApproxEqAbs(bidUsd, 10_000e6, 2);
    }

    function test_bidAddsDepthInMirroredLayout() public {
        uint256 snap = vm.snapshotState();
        uint256 before = _sell(Mezo.MUSD, USD, 10_000e18);
        vm.revertToState(snap);
        _deposit(10_000e6);
        uint256 afterDeposit = _sell(Mezo.MUSD, USD, 10_000e18);
        assertGt(afterDeposit, before + 7_000e6);
    }

    function test_fullCycleInMirroredLayout() public {
        uint256 shares = _deposit(10_000e6);
        _sell(Mezo.MUSD, USD, 6_000e18); // fill part of the bid
        _settle(30 minutes);
        vault.rebalance();
        (,, uint256 parked,,,,) = vault.holdings();
        assertGt(parked, 0, "bought MUSD parked in sMUSD");

        // Demand returns and lifts MUSD to just under $1.
        while ((-1) * (_tick() - vault.parTick()) > 10) _sell(USD, Mezo.MUSD, 5_000e6);
        _settle(30 minutes);
        vault.rebalance();
        (uint256 askId,) = vault.ask();
        assertGt(askId, 0);
        (,,,,, int24 tl,,,,,,) = nfpm.positions(askId);
        // Mirrored: dearer MUSD = higher tick, so the ask starts at or above par.
        assertGe(tl, vault.parTick(), "never sell below $1");

        vm.prank(alice);
        (uint256 u, uint256 m) = vault.redeem(shares, 0, 0, alice);
        assertGt(u + m / 1e12, 9_800e6);
    }

    /// The band on the live price, in the mirrored layout Mezo testnet uses. Like any live
    /// pool, this one gets two-sided liquidity in the tick slot around the price first.
    function test_bandInMirroredLayout() public {
        (int24 sa, int24 sb) = PegMath.toTickRange(90, 110, vault.parTick(), -1);
        _mint(sa, sb, 5_000e18, 5_000e6);
        _settle(15 minutes);
        _deployBandVault();
        _bandCycle(true);
    }

    /// Same layout with nothing in the price's slot: the band's swap crosses empty ticks and
    /// buys nothing. The deposit must still work, the band is skipped, and no value is lost.
    function test_bandSkipsSafelyWhenThePriceSlotIsEmpty() public {
        _deployBandVault();
        _bandCycle(false);
    }

    function _deployBandVault() internal {
        PlumbBidVault.Params memory p = PlumbBidVault.Params({
            pool: mirrored,
            nfpm: nfpm,
            gauge: ICLGauge(address(0)),
            smusd: IMUSDSavingsRate(Mezo.SMUSD),
            usd: USD,
            musd: Mezo.MUSD,
            treasury: makeAddr("treasury"),
            incentiveSink: address(0),
            twapWindow: 600,
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
            depositCap: 0,
            bandWidth: 10,
            bandBps: 5_000
        });
        vault = new PlumbBidVault(p, "Plumb MUSD Bid", "plumbBID");
    }

    function _bandCycle(bool expectBand) internal {
        uint256 shares = _deposit(10_000e6);
        (uint256 bandId,) = vault.band();
        if (!expectBand) {
            assertEq(bandId, 0, "no band from an empty slot");
            (uint256 bid_,) = vault.bid();
            assertGt(bid_, 0, "the bid still goes up");
            assertGe(vault.totalAssets(), 9_980e6);
            vm.prank(alice);
            (uint256 u0, uint256 m0) = vault.redeem(shares, 0, 0, alice);
            assertGt(u0 + m0 / 1e12, 9_980e6);
            return;
        }
        assertGt(bandId, 0, "band placed");
        (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = nfpm.positions(bandId);
        int24 spot = _tick();
        assertTrue(tl <= spot && spot < tu, "band contains the price");
        assertGt(liq, 0);
        // Never bought MUSD above $1: mirrored, dearer MUSD is a higher tick.
        assertLe(spot, vault.parTick());

        (uint256 bidId,) = vault.bid();
        (,,,,, int24 bl, int24 bu,,,,,) = nfpm.positions(bidId);
        // The bid never overlaps the band. It may start lower: it stays under the TWAP too,
        // and here the band's own swap moved the thin pool's spot above the TWAP.
        assertLe(bu, tl, "bid sits at or below the band's cheap edge");
        assertLt(bl, bu);
        assertGe(vault.totalAssets(), 9_980e6, "band funding cost under 0.2%");

        _sell(Mezo.MUSD, USD, 6_000e18);
        _settle(30 minutes);
        vault.rebalance();
        vm.prank(alice);
        (uint256 u, uint256 m) = vault.redeem(shares, 0, 0, alice);
        assertGt(u + m / 1e12, 9_800e6);
    }

    function _tick() internal view returns (int24 t) {
        (, t,,,,) = mirrored.slot0();
    }
}
