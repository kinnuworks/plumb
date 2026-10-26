// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PlumbQuoter} from "../../src/PlumbQuoter.sol";
import {MezoFork, Mezo} from "./MezoFork.sol";

contract PlumbQuoterForkTest is MezoFork {
    PlumbQuoter internal quoter;

    function setUp() public {
        _fork();
        quoter = new PlumbQuoter();
    }

    function test_quoteMatchesARealSale() public {
        uint256 size = 20_000e18;
        // MUSD is token1 on mainnet, so selling MUSD is oneForZero.
        (uint256 quoted, int24 tickAfter) = quoter.quoteExactIn(pool, false, size);
        int24 tickBefore = _spotTick();
        uint256 real = _swap(Mezo.MUSD, Mezo.MUSDC, size);
        assertEq(quoted, real);
        assertEq(tickAfter, _spotTick());
        assertGt(tickAfter, tickBefore, "selling MUSD makes it cheaper");
    }

    function test_quoteLeavesPoolUntouched() public {
        (uint160 before,,,,,) = pool.slot0();
        quoter.quoteExactIn(pool, false, 50_000e18);
        (uint160 afterQuote,,,,,) = pool.slot0();
        assertEq(before, afterQuote);
    }

    function test_curveIsMonotonic() public {
        uint256[] memory sizes = new uint256[](4);
        sizes[0] = 1_000e18;
        sizes[1] = 10_000e18;
        sizes[2] = 50_000e18;
        sizes[3] = 100_000e18;
        uint256[] memory outs = quoter.quoteCurve(pool, false, sizes);
        for (uint256 i = 1; i < outs.length; i++) assertGe(outs[i], outs[i - 1]);
    }

    function test_rejectsForeignCallbacks() public {
        vm.expectRevert(PlumbQuoter.NotPool.selector);
        quoter.uniswapV3SwapCallback(1, 1, "");
    }
}
