// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {PlumbBidVault} from "../../src/PlumbBidVault.sol";
import {PegBook} from "../../src/PegBook.sol";
import {ICLGauge} from "../../src/interfaces/IMezoCL.sol";
import {IMUSDSavingsRate} from "../../src/interfaces/IMUSDSavingsRate.sol";
import {MezoFork, Mezo} from "./MezoFork.sol";

/// Fork tests against Mezo mainnet: the real MUSD/mUSDC pool, its gauge, the sMUSD vault
/// and the CL router. Nothing here is mocked.
contract PlumbBidVaultForkTest is MezoFork {
    PlumbBidVault internal vault;
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        _fork();
        vault = _deploy(address(smusd), _bribe());
        vm.label(address(vault), "PlumbBidVault");
    }

    function _deploy(address smusd_, address bribe_) internal returns (PlumbBidVault) {
        return new PlumbBidVault(
            PlumbBidVault.Params({
                pool: pool,
                nfpm: nfpm,
                gauge: gauge,
                smusd: IMUSDSavingsRate(smusd_),
                usd: Mezo.MUSDC,
                musd: Mezo.MUSD,
                treasury: treasury,
                incentiveSink: bribe_,
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
                depositCap: 0
            }),
            "Plumb MUSD Bid",
            "plumbBID"
        );
    }

    function _depositFor(address who, uint256 usdAmount) internal returns (uint256 shares) {
        deal(Mezo.MUSDC, who, usdAmount);
        vm.startPrank(who);
        usdc.approve(address(vault), usdAmount);
        shares = vault.depositAndDeploy(usdAmount, 0, who);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Configuration read from the live pool
    // ------------------------------------------------------------------

    function test_parTickPricesOneMusdAtOneDollar() public view {
        // USD (6 decimals) is token0 on mainnet, so at par the raw price is 1e12 MUSD per USD.
        assertTrue(vault.usdIsToken0());
        uint160 sqrtPar = TickMath.getSqrtRatioAtTick(vault.parTick());
        uint256 rawPrice = (uint256(sqrtPar) * uint256(sqrtPar)) >> 192;
        // Par is snapped to the 10-tick grid on the dear side: MUSD worth $1.000 to $1.001.
        assertGe(rawPrice, 0.999e12);
        assertLe(rawPrice, 1e12);
        assertEq(vault.parTick() % vault.tickSpacing(), 0);
    }

    function test_liveMusdIsBelowPeg() public view {
        int24 depeg = vault.currentDepeg();
        console2.log("MUSD depeg ticks at fork block:", depeg);
        assertGt(depeg, 50); // about $0.99
        assertLt(depeg, 200);
    }

    // ------------------------------------------------------------------
    // Deposits place a single-sided bid below the market
    // ------------------------------------------------------------------

    function test_depositPlacesStakedBidBelowMarket() public {
        _depositFor(alice, 25_000e6);

        (uint256 tokenId, bool staked) = vault.bid();
        assertGt(tokenId, 0);
        assertTrue(staked, "bid should be staked in the gauge");
        assertTrue(gauge.stakedContains(address(vault), tokenId));

        (,,,,, int24 tl, int24 tu,,,,,) = nfpm.positions(tokenId);
        // Higher tick = cheaper MUSD on mainnet. A bid sits strictly above the spot tick.
        assertGt(tl, _spotTick(), "bid must be below the market price");
        assertEq(tu - tl, vault.bidWidth());

        (uint256 idleUsd,,, uint256 bidUsd, uint256 bidMusd,,) = vault.holdings();
        assertEq(bidMusd, 0, "bid must hold only USD");
        assertApproxEqAbs(bidUsd + idleUsd, 25_000e6, 2);
        assertApproxEqAbs(vault.totalAssets(), 25_000e6, 2);
    }

    function test_depositMakesSellingMusdCheaper() public {
        // The pool's ~$38.6k of USD sits within a few ticks of the price. A 100k MUSD sell
        // drains it and the price falls through empty ticks. Plumb's bid catches that sale.
        uint256 sell = 100_000e18;
        uint256 before = _quoteSellMusd(sell);

        _depositFor(alice, 25_000e6);
        uint256 afterDeposit = _quoteSellMusd(sell);

        console2.log("USD for 100k MUSD before:", before);
        console2.log("USD for 100k MUSD after: ", afterDeposit);
        assertGt(afterDeposit, before + 20_000e6, "the bid must absorb most of its size");
    }

    // ------------------------------------------------------------------
    // A sell-off fills the bid, and MUSD is parked in sMUSD
    // ------------------------------------------------------------------

    function test_sellOffFillsBidAndInventoryIsParked() public {
        _depositFor(alice, 25_000e6);
        _swap(Mezo.MUSD, Mezo.MUSDC, 60_000e18); // drain the pool's USD and push into the bid

        // holdings() prices at the TWAP on purpose, so let it catch up before reading fills.
        _settle(1 hours);
        (,,, uint256 bidUsd, uint256 bidMusd,,) = vault.holdings();
        assertGt(bidMusd, 0, "bid should have bought MUSD");
        assertLt(bidUsd, 25_000e6);

        vm.prank(keeper);
        vault.rebalance();

        (, uint256 idleMusd, uint256 parked,,,,) = vault.holdings();
        assertEq(idleMusd, 0);
        assertGt(parked, 0, "bought MUSD should earn in sMUSD");
        assertEq(IMUSDSavingsRate(Mezo.SMUSD).balanceOf(address(vault)), parked);
    }

    function test_mezoStreamsToHolders() public {
        _depositFor(alice, 25_000e6);
        _swap(Mezo.MUSD, Mezo.MUSDC, 50_000e18); // move the price into the bid so it earns
        _settle(1 days);

        uint256 treasuryBefore = mezo.balanceOf(treasury);
        vm.prank(alice);
        uint256 claimed = vault.claimMezo(alice);

        console2.log("MEZO to alice after a day in range:", claimed);
        assertGt(claimed, 0);
        assertGt(mezo.balanceOf(treasury), treasuryBefore);
        assertEq(mezo.balanceOf(alice), claimed);
    }

    // ------------------------------------------------------------------
    // Redemptions
    // ------------------------------------------------------------------

    function test_redeemIsProRataInKind() public {
        uint256 aShares = _depositFor(alice, 30_000e6);
        _settle(15 minutes);
        uint256 bShares = _depositFor(bob, 10_000e6);
        assertApproxEqRel(aShares, bShares * 3, 1e15);

        _swap(Mezo.MUSD, Mezo.MUSDC, 50_000e18); // vault now holds both tokens

        vm.prank(bob);
        (uint256 usdOut, uint256 musdOut) = vault.redeem(bShares, 0, 0, bob);

        assertEq(usdc.balanceOf(bob), usdOut);
        assertEq(musd.balanceOf(bob), musdOut);
        assertGt(musdOut, 0, "bob shares the MUSD the bid bought");
        // bob put in 10k USD; at worst his MUSD is worth the pool price (about $0.99)
        assertApproxEqRel(usdOut + musdOut / 1e12, 10_000e6, 2e16);
        assertEq(vault.balanceOf(bob), 0);
    }

    function test_fullExitLeavesNothingBehind() public {
        uint256 shares = _depositFor(alice, 12_345e6);
        _swap(Mezo.MUSD, Mezo.MUSDC, 20_000e18);

        vm.prank(alice);
        vault.redeem(shares, 0, 0, alice);

        assertEq(vault.totalSupply(), 0);
        (uint256 idleUsd, uint256 idleMusd, uint256 parked, uint256 bu, uint256 bm, uint256 au, uint256 am) =
            vault.holdings();
        assertLe(idleUsd + bu + au, 1, "dust only");
        assertLe(idleMusd + parked + bm + am, 1e12, "dust only");
    }

    function test_redeemSlippageGuard() public {
        uint256 shares = _depositFor(alice, 5_000e6);
        vm.prank(alice);
        vm.expectRevert(PlumbBidVault.Slippage.selector);
        vault.redeem(shares, 5_001e6, 0, alice);
    }

    // ------------------------------------------------------------------
    // Manipulation and circuit breakers
    // ------------------------------------------------------------------

    function test_rebalanceRefusesManipulatedPrice() public {
        _depositFor(alice, 10_000e6);
        _settle(15 minutes);
        // A whale dumps in the same block. The spot price leaves the TWAP behind.
        _swap(Mezo.MUSD, Mezo.MUSDC, 2_000_000e18);
        vm.expectPartialRevert(PegBook.PriceUnstable.selector);
        vault.rebalance();
    }

    function test_depositRefusesManipulatedPrice() public {
        _swap(Mezo.MUSD, Mezo.MUSDC, 80_000e18); // dump MUSD in this block
        deal(Mezo.MUSDC, alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vm.expectPartialRevert(PegBook.PriceUnstable.selector);
        vault.deposit(1_000e6, 0, alice);
        vm.stopPrank();
    }

    function test_noBidsAndNoDepositsBelowFloor() public {
        _depositFor(alice, 10_000e6);
        // A 5M MUSD dump eats every bid, ours included, and the price falls past the floor.
        _swap(Mezo.MUSD, Mezo.MUSDC, 5_000_000e18);
        _settle(2 hours);
        assertGe(vault.currentDepeg(), vault.floorDepeg());

        vm.prank(keeper);
        vault.rebalance();
        (uint256 tokenId,) = vault.bid();
        assertEq(tokenId, 0, "no new bid below the floor");

        deal(Mezo.MUSDC, bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1_000e6);
        vm.expectPartialRevert(PlumbBidVault.DepositsPaused.selector);
        vault.deposit(1_000e6, 0, bob);
        vm.stopPrank();

        // Alice can still leave with her share in kind.
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdOut, uint256 musdOut) = vault.redeem(shares, 0, 0, alice);
        assertGt(usdOut + musdOut, 0);
    }

    function test_rebalanceCooldown() public {
        _depositFor(alice, 1_000e6);
        vm.expectPartialRevert(PlumbBidVault.RebalanceTooSoon.selector);
        vault.rebalance();
    }

    function test_firstDepositorCannotInflateShares() public {
        // Attacker deposits 1 wei, then donates a lot to the vault.
        deal(Mezo.MUSDC, address(this), 1);
        usdc.approve(address(vault), 1);
        vault.deposit(1, 0, address(this));
        deal(Mezo.MUSDC, address(vault), 100_000e6 + 1);

        // The victim still receives shares worth close to their deposit.
        uint256 shares = _depositFor(alice, 10_000e6);
        assertGt(shares, 0);
        uint256 value = (vault.totalAssets() * shares) / vault.totalSupply();
        // The donation is shared with the victim instead of stolen from them.
        assertGe(value, 9_990e6);
    }

    // ------------------------------------------------------------------
    // Attacks found in blind judging
    // ------------------------------------------------------------------

    /// A flash-loaned deposit, claim and redeem in one transaction must not collect MEZO
    /// that existing holders earned before it arrived.
    function test_flashDepositCannotSnipeMezo() public {
        _depositFor(alice, 25_000e6);
        _swap(Mezo.MUSD, Mezo.MUSDC, 50_000e18); // price into the bid so it earns
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
        console2.log("MEZO to the attacker:", sniped);
        console2.log("MEZO to alice:       ", earned);
        assertEq(sniped, 0, "attacker took rewards earned before their deposit");
        assertGt(earned, 0);
    }

    /// While the TWAP lags a recovering price, depositing and redeeming at once must not pay.
    function test_depositRedeemRoundTripNeverProfits() public {
        _depositFor(alice, 25_000e6);
        _swap(Mezo.MUSD, Mezo.MUSDC, 50_000e18); // vault now holds MUSD bought cheap
        _settle(1 hours);

        // MUSD starts recovering inside this block: spot moves ahead of the TWAP, but stays
        // within the 30-tick tolerance so the deposit is accepted.
        int24 start = _spotTick();
        while (start - _spotTick() < 25) _swap(Mezo.MUSDC, Mezo.MUSD, 500e6);
        assertLe(start - _spotTick(), 30);

        address arb = makeAddr("arb");
        uint256 amount = 100_000e6;
        deal(Mezo.MUSDC, arb, amount);
        vm.startPrank(arb);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, 0, arb);
        (uint256 usdOut, uint256 musdOut) = vault.redeem(shares, 0, 0, arb);
        vm.stopPrank();

        // Value what came out at the live price, capped at $1 like the vault does.
        (uint160 sqrtSpot,,,,,) = pool.slot0();
        uint256 musdValue = (musdOut * (1 << 96) / sqrtSpot) * (1 << 96) / sqrtSpot;
        if (musdValue > musdOut / 1e12) musdValue = musdOut / 1e12;
        console2.log("USD in: ", amount);
        console2.log("USD out:", usdOut + musdValue);
        assertLe(usdOut + musdValue, amount, "round trip must not profit");
    }

    function test_transferKeepsEarnedMezoWithSender() public {
        _depositFor(alice, 25_000e6);
        _swap(Mezo.MUSD, Mezo.MUSDC, 50_000e18);
        _settle(1 days);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(bob, shares);

        vm.prank(bob);
        uint256 bobGot = vault.claimMezo(bob);
        vm.prank(alice);
        uint256 aliceGot = vault.claimMezo(alice);
        assertEq(bobGot, 0, "bob did not hold shares while the rewards accrued");
        assertGt(aliceGot, 0);
    }

    function test_depositCapIsEnforced() public {
        PlumbBidVault capped = _deployCapped(30_000e6);
        deal(Mezo.MUSDC, alice, 40_000e6);
        vm.startPrank(alice);
        usdc.approve(address(capped), 40_000e6);
        capped.deposit(25_000e6, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(PlumbBidVault.CapExceeded.selector, 30_000e6));
        capped.deposit(10_000e6, 0, alice);
        capped.deposit(4_000e6, 0, alice);
        vm.stopPrank();
    }

    function _deployCapped(uint256 cap) internal returns (PlumbBidVault) {
        PlumbBidVault.Params memory p = PlumbBidVault.Params({
            pool: pool,
            nfpm: nfpm,
            gauge: gauge,
            smusd: smusd,
            usd: Mezo.MUSDC,
            musd: Mezo.MUSD,
            treasury: treasury,
            incentiveSink: _bribe(),
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
            depositCap: cap
        });
        return new PlumbBidVault(p, "Plumb MUSD Bid", "plumbBID");
    }

    function test_nftsOnlyFromTheManager() public {
        vm.expectRevert(PegBook.UnexpectedNft.selector);
        vault.onERC721Received(address(this), address(this), 1, "");
    }

    // ------------------------------------------------------------------
    // Recovery: the price returns to par
    // ------------------------------------------------------------------

    function test_recoveryOffersInventoryBackAtParOrBetter() public {
        _depositFor(alice, 25_000e6);
        _swap(Mezo.MUSD, Mezo.MUSDC, 60_000e18);
        _settle(1 hours);
        vm.prank(keeper);
        vault.rebalance(); // parks bought MUSD

        // Demand comes back: buyers lift MUSD to just under $1.
        _pushDepegTo(10);
        _settle(1 hours);
        vm.prank(keeper);
        vault.rebalance();

        (uint256 askId,) = vault.ask();
        assertGt(askId, 0, "inventory should be offered");
        (,,,,,, int24 tu,,,,,) = nfpm.positions(askId);
        // On mainnet the ask sits at ticks <= par, i.e. MUSD price >= $1.
        assertLe(tu, vault.parTick(), "never offer below $1");
        assertLt(tu, _spotTick());
        (,, uint256 parked,,,,) = vault.holdings();
        assertEq(parked, 0, "MUSD left sMUSD to be sold");
    }

    /// Buys MUSD with USD until the spot depeg is at most `target` ticks.
    function _pushDepegTo(int24 target) internal {
        for (uint256 i; i < 60; i++) {
            int24 depeg = (_spotTick() - vault.parTick()) * vault.dir();
            if (depeg <= target) return;
            _swap(Mezo.MUSDC, Mezo.MUSD, 250_000e6);
        }
        revert("could not reach target");
    }
}
