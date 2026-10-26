// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {PegMath} from "../../src/libraries/PegMath.sol";

contract PegMathTest is Test {
    function test_parTickMainnetOrientation() public pure {
        // USD (6 dp) is token0: at par the pool price is 1e12 raw MUSD per raw USD.
        int24 t = PegMath.parTick(true, 12);
        assertEq(t, 276324);
    }

    function test_parTickTestnetOrientation() public pure {
        // USD is token1: at par the pool price is 1e-12, the mirror image.
        int24 t = PegMath.parTick(false, 12);
        assertEq(t, -276325);
    }

    function test_parTickSameDecimals() public pure {
        assertEq(PegMath.parTick(true, 0), 0);
        assertEq(PegMath.parTick(false, 0), 0);
    }

    function testFuzz_floorAndCeilBracketTheInput(int24 x, uint8 s) public pure {
        int24 spacing = int24(uint24(bound(s, 1, 200)));
        x = int24(bound(x, -800_000, 800_000));
        int24 f = PegMath.floorToSpacing(x, spacing);
        int24 c = PegMath.ceilToSpacing(x, spacing);
        assertEq(f % spacing, 0);
        assertEq(c % spacing, 0);
        assertLe(f, x);
        assertGe(c, x);
        assertLt(x - f, spacing);
        assertLt(c - x, spacing);
    }

    function testFuzz_depegRoundTrips(int24 tick, bool usdIsToken0) public pure {
        tick = int24(bound(tick, -800_000, 800_000));
        int24 par = PegMath.parTick(usdIsToken0, 12);
        int24 d = PegMath.direction(usdIsToken0);
        assertEq(PegMath.toTick(PegMath.toDepeg(tick, par, d), par, d), tick);
    }

    function testFuzz_cheaperMusdMeansHigherDepeg(int24 tick, bool usdIsToken0) public pure {
        // Moving one tick in the "MUSD cheaper" direction raises depeg by one in both layouts.
        tick = int24(bound(tick, -800_000, 800_000));
        int24 par = PegMath.parTick(usdIsToken0, 12);
        int24 d = PegMath.direction(usdIsToken0);
        assertEq(PegMath.toDepeg(tick + d, par, d), PegMath.toDepeg(tick, par, d) + 1);
    }

    function testFuzz_tickRangeIsOrdered(int24 lo, int24 width, bool usdIsToken0) public pure {
        lo = int24(bound(lo, -1000, 1000));
        width = int24(bound(width, 1, 1000));
        int24 par = PegMath.parTick(usdIsToken0, 12);
        (int24 a, int24 b) = PegMath.toTickRange(lo, lo + width, par, PegMath.direction(usdIsToken0));
        assertLt(a, b);
        assertEq(b - a, width);
    }

    function testFuzz_musdValueIsSymmetricAcrossLayouts(uint96 amount, int24 depeg) public pure {
        // The same economic price must value MUSD the same whichever token is token0.
        depeg = int24(bound(depeg, -500, 500));
        uint256 musdAmount = bound(uint256(amount), 1e18, 1e30); // 1 to 1e12 MUSD
        int24 parA = PegMath.parTick(true, 12);
        int24 parB = PegMath.parTick(false, 12);
        uint256 a = PegMath.musdToUsd(
            musdAmount, TickMath.getSqrtRatioAtTick(PegMath.toTick(depeg, parA, 1)), true
        );
        uint256 b = PegMath.musdToUsd(
            musdAmount, TickMath.getSqrtRatioAtTick(PegMath.toTick(depeg, parB, -1)), false
        );
        assertApproxEqRel(a, b, 2e14); // within 0.02%; the two pars differ by one tick
    }

    function test_musdAtParIsWorthOneDollar() public pure {
        uint160 sqrtPar = TickMath.getSqrtRatioAtTick(PegMath.parTick(true, 12));
        uint256 usdValue = PegMath.musdToUsd(1_000e18, sqrtPar, true);
        assertApproxEqRel(usdValue, 1_000e6, 1e14);
    }
}
