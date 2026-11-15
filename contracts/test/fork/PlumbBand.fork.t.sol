// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";

import {PlumbBidVault} from "../../src/PlumbBidVault.sol";
import {PegBook} from "../../src/PegBook.sol";
import {IMUSDSavingsRate} from "../../src/interfaces/IMUSDSavingsRate.sol";
import {MezoFork, Mezo} from "./MezoFork.sol";

/// Wave 2: the market band. A position on the live price, staked in Mezo's gauge, so the
/// vault earns MEZO while MUSD trades normally, with the backstop bid starting where the band
/// ends. Mezo mainnet fork; nothing here is mocked except the MEZO precompile.
contract PlumbBandForkTest is MezoFork {
    PlumbBidVault internal vault;
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    address internal bribe;

    function setUp() public {
        _fork();
        bribe = _bribe();
        vault = _deploy(10, 5_000);
        vm.label(address(vault), "PlumbBidVault");
    }

    function _deploy(int24 bandWidth, uint16 bandBps) internal returns (PlumbBidVault) {
        return new PlumbBidVault(
            PlumbBidVault.Params({
                pool: pool,
                nfpm: nfpm,
                gauge: gauge,
                smusd: IMUSDSavingsRate(address(smusd)),
                usd: Mezo.MUSDC,
                musd: Mezo.MUSD,
                treasury: treasury,
                incentiveSink: bribe,
                twapWindow: 1800,
                maxTwapDeviation: 30,
                bidWidth: 200,
                askWidth: 50,
                floorDepeg: 400,
                nearParDepeg: 20,
                maxInventoryBps: 6_000,
                feeBps: 1_000,
                incentiveBps: 1_000,
                keeperBps: 100,
                minRebalanceInterval: 10 minutes,
                depositCap: 0,
                bandWidth: bandWidth,
                bandBps: bandBps
            }),
            "Plumb MUSD Bid",
            "plumbBID"
        );
    }

    function _depositFor(PlumbBidVault v, address who, uint256 usdAmount) internal returns (uint256 shares) {
        deal(Mezo.MUSDC, who, usdAmount);
        vm.startPrank(who);
        usdc.approve(address(v), usdAmount);
        shares = v.depositAndDeploy(usdAmount, 0, who);
        vm.stopPrank();
    }

    function _depeg() internal view returns (int24) {
        return (_spotTick() - vault.parTick()) * vault.dir();
    }

    function _sellUntilDepeg(int24 target) internal {
        for (uint256 i; i < 200; i++) {
            if (_depeg() >= target) return;
            _swap(Mezo.MUSD, Mezo.MUSDC, 20_000e18);
        }
        revert("could not reach target");
    }

    // ------------------------------------------------------------------
    // Placement
    // ------------------------------------------------------------------

    function test_bandStraddlesThePriceAndIsStaked() public {
        _depositFor(vault, alice, 20_000e6);

        (uint256 tokenId, bool staked) = vault.band();
        assertGt(tokenId, 0, "band placed");
        assertTrue(staked, "band staked in the gauge");
        assertTrue(gauge.stakedContains(address(vault), tokenId));

        (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = nfpm.positions(tokenId);
        int24 spot = _spotTick();
        assertLe(tl, spot, "band must contain the price");
        assertGt(tu, spot, "band must contain the price");
        assertEq(tu - tl, vault.bandWidth());
        assertGt(liq, 0);

        (uint256 bandUsd, uint256 bandMusd) = vault.bandHoldings();
        assertGt(bandUsd, 0, "band holds USD");
        assertGt(bandMusd, 0, "band holds MUSD");
        console2.log("band USD :", bandUsd);
        console2.log("band MUSD:", bandMusd);
    }

    function test_bidStartsWhereTheBandEnds() public {
        _depositFor(vault, alice, 20_000e6);
        (uint256 bandId,) = vault.band();
        (uint256 bidId,) = vault.bid();
        assertGt(bidId, 0, "backstop bid placed");
        (,,,,, int24 bandLo, int24 bandHi,,,,,) = nfpm.positions(bandId);
        (,,,,, int24 bidLo, int24 bidHi,,,,,) = nfpm.positions(bidId);
        // Mainnet: a higher tick is cheaper MUSD, so the bid sits above the band, touching it.
        assertEq(bidLo, bandHi, "no gap between band and bid");
        assertGt(bandHi, bandLo);
        // The bid stops at the floor: no bids deeper than ~$0.96.
        assertLe(bidHi, vault.parTick() + vault.floorDepeg());
        (,,, uint256 bidUsd, uint256 bidMusd,,) = vault.holdings();
        assertEq(bidMusd, 0, "bid holds only USD");
        assertGt(bidUsd, 0);
    }

    function test_depositKeepsItsValue() public {
        // Funding the band swaps part of the deposit through the pool. That must cost no more
        // than the pool fee and the band's spread.
        _depositFor(vault, alice, 20_000e6);
        assertGe(vault.totalAssets(), 19_960e6, "band funding lost more than 0.2%");
    }

    // ------------------------------------------------------------------
    // The Wave 2 point: income while the peg holds
    // ------------------------------------------------------------------

    function test_bandEarnsMezoWhileThePegHolds() public {
        PlumbBidVault bidOnly = _deploy(0, 0);
        _depositFor(vault, alice, 20_000e6);
        _depositFor(bidOnly, bob, 20_000e6);

        // A quiet day: nobody sells, the price stays in its tick.
        _settle(1 days);

        vm.prank(alice);
        uint256 withBand = vault.claimMezo(alice);
        vm.prank(bob);
        uint256 withoutBand = bidOnly.claimMezo(bob);
        console2.log("MEZO in a quiet day, band + bid:", withBand);
        console2.log("MEZO in a quiet day, bid only:  ", withoutBand);
        assertGt(withBand, 0, "band must earn while the peg holds");
        assertEq(withoutBand, 0, "a bid below the market earns nothing in range");
    }

    // ------------------------------------------------------------------
    // The backstop
    // ------------------------------------------------------------------

    function test_backstopCatchesALargeSale() public {
        uint256 sell = 400_000e18;
        uint256 before = _quoteSellMusd(sell);
        _depositFor(vault, alice, 50_000e6);
        uint256 afterDeposit = _quoteSellMusd(sell);
        console2.log("USD for 400k MUSD before:", before);
        console2.log("USD for 400k MUSD after: ", afterDeposit);
        assertGt(afterDeposit, before + 40_000e6, "the book must absorb most of its size");
    }

    function test_sellOffParksMusdAndBandFollowsThePrice() public {
        _depositFor(vault, alice, 20_000e6);
        // Stop the sale at ~$0.99: below the live tick and Plumb's bid the pool holds almost
        // no USD, so an unlimited sale would fall to the bottom of the tick range.
        _swapToTick(Mezo.MUSD, Mezo.MUSDC, 1_000_000e18, vault.parTick() + 100 * vault.dir());
        _settle(1 hours);

        vm.prank(keeper);
        vault.rebalance();
        (uint256 iu, uint256 im, uint256 pk, uint256 bu, uint256 bm,,) = vault.holdings();
        console2.log("idle usd, idle musd, parked:", iu, im, pk);
        console2.log("bid usd, bid musd:", bu, bm);
        (uint256 bid_,) = vault.bid();
        console2.log("bid id, depeg:", bid_, uint256(int256(vault.currentDepeg())));

        (, uint256 idleMusd, uint256 parked,,,,) = vault.holdings();
        assertGt(parked, 0, "bought MUSD earns in sMUSD");
        assertEq(idleMusd, 0, "nothing left idle");

        (uint256 bandId, bool staked) = vault.band();
        assertTrue(staked);
        (,,,,, int24 tl, int24 tu,,,,,) = nfpm.positions(bandId);
        int24 spot = _spotTick();
        assertTrue(tl <= spot && spot < tu, "band re-centred on the new price");
    }

    function test_noBandOrBidBelowTheFloor() public {
        _depositFor(vault, alice, 10_000e6);
        _swap(Mezo.MUSD, Mezo.MUSDC, 5_000_000e18);
        _settle(2 hours);
        assertGe(vault.currentDepeg(), vault.floorDepeg());

        vm.prank(keeper);
        vault.rebalance();
        (uint256 bandId,) = vault.band();
        (uint256 bidId,) = vault.bid();
        assertEq(bandId, 0, "no band below the floor");
        assertEq(bidId, 0, "no bid below the floor");

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        (uint256 u, uint256 m) = vault.redeem(shares, 0, 0, alice);
        assertGt(u + m, 0);
    }

    // ------------------------------------------------------------------
    // Earlier attacks, re-run with the band live
    // ------------------------------------------------------------------

    function test_fullExitLeavesNothingBehind() public {
        uint256 shares = _depositFor(vault, alice, 12_345e6);
        _swap(Mezo.MUSD, Mezo.MUSDC, 20_000e18);
        vm.prank(alice);
        vault.redeem(shares, 0, 0, alice);

        assertEq(vault.totalSupply(), 0);
        (uint256 iu, uint256 im, uint256 p, uint256 bu, uint256 bm, uint256 au, uint256 am) = vault.holdings();
        (uint256 nu, uint256 nm) = vault.bandHoldings();
        assertLe(iu + bu + au + nu, 2, "dust only");
        assertLe(im + p + bm + am + nm, 2e12, "dust only");
    }

    function test_redeemIsProRataInKind() public {
        uint256 a = _depositFor(vault, alice, 30_000e6);
        _settle(15 minutes);
        uint256 b = _depositFor(vault, bob, 10_000e6);
        assertApproxEqRel(a, b * 3, 2e15);

        vm.prank(bob);
        (uint256 u, uint256 m) = vault.redeem(b, 0, 0, bob);
        assertGt(m, 0, "bob gets his slice of the band's MUSD");
        assertApproxEqRel(u + m / 1e12, 10_000e6, 1e16);
    }

    function test_flashDepositCannotSnipeMezo() public {
        _depositFor(vault, alice, 20_000e6);
        _settle(1 days); // a day of rewards sits unharvested in the gauge

        address attacker = makeAddr("attacker");
        uint256 loan = 2_000_000e6;
        deal(Mezo.MUSDC, attacker, loan);
        vm.startPrank(attacker);
        usdc.approve(address(vault), loan);
        uint256 shares = vault.deposit(loan, 0, attacker);
        uint256 sniped = vault.claimMezo(attacker);
        vault.redeem(shares, 0, 0, attacker);
        vm.stopPrank();

        vm.prank(alice);
        uint256 earned = vault.claimMezo(alice);
        assertEq(sniped, 0, "attacker took rewards earned before their deposit");
        assertGt(earned, 0);
    }

    function test_depositRedeemRoundTripNeverProfits() public {
        _depositFor(vault, alice, 20_000e6);
        _settle(1 hours);

        address arb = makeAddr("arb");
        uint256 amount = 100_000e6;
        deal(Mezo.MUSDC, arb, amount);
        vm.startPrank(arb);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.depositAndDeploy(amount, 0, arb);
        (uint256 usdOut, uint256 musdOut) = vault.redeem(shares, 0, 0, arb);
        vm.stopPrank();

        // Value what came out at the live price, capped at $1, as the vault does.
        (uint160 sqrtSpot,,,,,) = pool.slot0();
        uint256 musdValue = (musdOut * (1 << 96) / sqrtSpot) * (1 << 96) / sqrtSpot;
        if (musdValue > musdOut / 1e12) musdValue = musdOut / 1e12;
        console2.log("USD in: ", amount);
        console2.log("USD out:", usdOut + musdValue);
        assertLe(usdOut + musdValue, amount, "round trip must not profit");
    }

    function test_rebalanceRefusesManipulatedPrice() public {
        _depositFor(vault, alice, 10_000e6);
        _settle(15 minutes);
        _sellUntilDepeg(vault.currentDepeg() + 40);
        vm.expectPartialRevert(PegBook.PriceUnstable.selector);
        vault.rebalance();
    }

    function test_bandSwapNeverBuysAboveTheLimit() public {
        // Someone lifts MUSD in this block, inside the TWAP tolerance. The band's swap is
        // capped at the TWAP price minus the tolerance and never above $1.
        _settle(15 minutes);
        int24 twapDepeg = vault.currentDepeg();
        _swapToTick(Mezo.MUSDC, Mezo.MUSD, 5_000_000e6, vault.parTick() + (twapDepeg - 25) * vault.dir());
        _depositFor(vault, alice, 20_000e6);
        int24 after_ = _depeg();
        assertGe(after_, twapDepeg - vault.maxTwapDeviation(), "swap pushed MUSD past the limit");
        assertGe(after_, 0, "bought MUSD above $1");
    }

    function test_badBandParamsRejected() public {
        vm.expectRevert(PlumbBidVault.BadParams.selector);
        _deploy(15, 5_000); // not a multiple of the pool's 10-tick spacing
        vm.expectRevert(PlumbBidVault.BadParams.selector);
        _deploy(10, 10_001);
    }
}
