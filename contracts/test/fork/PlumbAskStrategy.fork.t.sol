// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";

import {PlumbAskStrategy} from "../../src/PlumbAskStrategy.sol";
import {IMUSDSavingsRate} from "../../src/interfaces/IMUSDSavingsRate.sol";
import {MezoFork, Mezo} from "./MezoFork.sol";

/// Switches the live sMUSD vault to PlumbAskStrategy on a mainnet fork, the way Mezo's
/// multisig would, and checks that savers are never worse off.
contract PlumbAskStrategyForkTest is MezoFork {
    PlumbAskStrategy internal strategy;
    address internal saver = makeAddr("saver");
    uint256 internal idleBefore;

    function setUp() public {
        _fork();
        idleBefore = musd.balanceOf(Mezo.IDLE_STRATEGY);

        strategy = new PlumbAskStrategy(
            PlumbAskStrategy.Params({
                vault: Mezo.SMUSD,
                pool: pool,
                nfpm: nfpm,
                router: router,
                usd: Mezo.MUSDC,
                musd: Mezo.MUSD,
                twapWindow: 1800,
                maxTwapDeviation: 30,
                maxOrderBps: 500, // at most 5% of savers' MUSD on offer
                premium: 10, // orders start about $1.001
                width: 40,
                buybackDepeg: 20, // buy back once MUSD is 0.2% under $1
                minRebalanceInterval: 10 minutes
            })
        );

        deal(Mezo.MUSD, address(strategy), 1e15); // rounding reserve, outside principal

        vm.prank(smusd.owner());
        smusd.setStrategy(address(strategy));
    }

    function test_switchMovesEverySaversMusd() public view {
        assertEq(smusd.strategy(), address(strategy));
        assertEq(musd.balanceOf(Mezo.IDLE_STRATEGY), 0);
        assertEq(musd.balanceOf(address(strategy)), idleBefore + 1e15);
        assertEq(strategy.principal(), idleBefore);
        console2.log("MUSD moved from IdleStrategy:", idleBefore / 1e18);
    }

    function test_depositAndWithdrawStillInstant() public {
        deal(Mezo.MUSD, saver, 1_000e18);
        vm.startPrank(saver);
        musd.approve(Mezo.SMUSD, 1_000e18);
        smusd.deposit(1_000e18);
        assertEq(strategy.principal(), idleBefore + 1_000e18);

        smusd.withdraw(1_000e18);
        vm.stopPrank();
        assertEq(musd.balanceOf(saver), 1_000e18);
        assertEq(strategy.principal(), idleBefore);
    }

    function test_orderIsCappedAndNeverBelowOneDollar() public {
        _settle(15 minutes);
        strategy.rebalance();

        uint256 id = strategy.orderId();
        assertGt(id, 0);
        (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = nfpm.positions(id);
        assertGt(liq, 0);
        // Mainnet: lower tick = dearer MUSD. The whole order sits at or above $1.001.
        assertLe(tu, strategy.parTick() - 10);
        assertEq(tu - tl, 40);

        (uint256 idle, uint256 inOrder, uint256 usdHeld) = strategy.totalHoldings();
        assertEq(usdHeld, 0);
        assertApproxEqAbs(inOrder, (strategy.principal() * 500) / 10_000, 1e18);
        assertApproxEqAbs(idle + inOrder, strategy.principal(), 1e18);
    }

    function test_fullCycleEarnsForSavers() public {
        _settle(15 minutes);
        strategy.rebalance();
        uint256 principal = strategy.principal();

        // Demand for MUSD returns: buyers clear the 5.3M MUSD wall below $1 and lift MUSD
        // into the order at $1.001 and up.
        _buyMusdUntilDepeg(-12);
        _settle(1 hours);
        strategy.rebalance(); // collects the fill as USD; MUSD is above par, so no buyback yet
        (,, uint256 usdHeld) = strategy.totalHoldings();
        assertGt(usdHeld, 0, "order should have sold MUSD for USD");
        console2.log("USD received for MUSD sold at >= $1.001:", usdHeld / 1e6);

        // The price falls back below par; the strategy buys MUSD back cheaper.
        _swap(Mezo.MUSD, Mezo.MUSDC, 3_000_000e18);
        _settle(2 hours);
        vm.warp(block.timestamp + 10 minutes);
        strategy.rebalance();

        (uint256 idle, uint256 inOrder, uint256 usdLeft) = strategy.totalHoldings();
        assertEq(usdLeft, 0);
        assertGt(idle + inOrder, principal, "savers should end with more MUSD");
        console2.log("MUSD surplus for savers:", (idle + inOrder - principal) / 1e18);

        // The surplus reaches sMUSD holders as yield.
        uint256 vaultBefore = musd.balanceOf(Mezo.SMUSD);
        smusd.receiveYieldFromStrategy();
        assertGt(musd.balanceOf(Mezo.SMUSD), vaultBefore);
        assertEq(strategy.principal(), principal);
    }

    function test_largeWithdrawalPullsTheOrder() public {
        _settle(15 minutes);
        strategy.rebalance();
        address whale = makeAddr("whale");
        // Pretend one saver owns most of the vault and leaves.
        deal(Mezo.MUSD, whale, 1_000e18);
        vm.startPrank(whale);
        musd.approve(Mezo.SMUSD, 1_000e18);
        smusd.deposit(1_000e18);
        vm.stopPrank();

        uint256 idle = musd.balanceOf(address(strategy));
        // Ask the strategy for more than it holds idle: it must unwind the order to pay.
        vm.prank(Mezo.SMUSD);
        strategy.deallocate(idle + 10e18);
        assertEq(strategy.orderId(), 0);
    }

    function test_migrateBackReturnsEverything() public {
        _settle(15 minutes);
        strategy.rebalance();
        uint256 principal = strategy.principal();

        // Governance switches to a fresh idle-style strategy and gets every MUSD back.
        PlumbAskStrategy next = new PlumbAskStrategy(
            PlumbAskStrategy.Params({
                vault: Mezo.SMUSD,
                pool: pool,
                nfpm: nfpm,
                router: router,
                usd: Mezo.MUSDC,
                musd: Mezo.MUSD,
                twapWindow: 1800,
                maxTwapDeviation: 30,
                maxOrderBps: 0,
                premium: 10,
                width: 40,
                buybackDepeg: 20,
                minRebalanceInterval: 10 minutes
            })
        );
        deal(Mezo.MUSD, address(next), 1e15);
        vm.prank(smusd.owner());
        smusd.setStrategy(address(next));

        assertEq(strategy.orderId(), 0);
        assertEq(musd.balanceOf(address(strategy)), 0);
        // Everything moved, including the rounding reserve that absorbed the order's 1 wei.
        assertGe(next.principal(), principal);
    }

    /// After the order fills, a sandwich that pumps MUSD before a withdrawal cannot make the
    /// strategy overpay, and withdrawals up to idle MUSD still go through.
    function test_sandwichedBuybackIsRefusedAndWithdrawalsStillPay() public {
        _settle(15 minutes);
        strategy.rebalance();
        _buyMusdUntilDepeg(-12); // demand fills the order: the strategy now holds USD
        _settle(1 hours);
        strategy.rebalance();
        (uint256 idle,, uint256 usdHeld) = strategy.totalHoldings();
        assertGt(usdHeld, 0);

        // The attacker front-runs: pushes MUSD far above $1 in this block.
        _buyMusdUntilDepeg(-200);

        // A withdrawal paid from idle MUSD never touches the market.
        vm.prank(Mezo.SMUSD);
        strategy.deallocate(idle / 2);

        // Asking for more than is idle forces a buyback at the pumped price. The strategy
        // refuses that swap instead of overpaying, so the oversized request fails cleanly.
        uint256 usdBefore = usdc.balanceOf(address(strategy));
        vm.prank(Mezo.SMUSD);
        vm.expectPartialRevert(PlumbAskStrategy.Shortfall.selector);
        strategy.deallocate(idle);
        assertEq(usdc.balanceOf(address(strategy)), usdBefore, "no USD was spent at the bad price");
    }

    function test_orderShrinksWhenSaversLeave() public {
        _settle(15 minutes);
        strategy.rebalance();
        uint256 size = strategy.orderSize();
        assertGt(size, 0);

        // Most savers leave: principal falls until the order would exceed its cap.
        uint256 leave = strategy.principal() - (size * 10_000) / 500 + 1e18;
        vm.prank(Mezo.SMUSD);
        strategy.deallocate(leave);
        assertEq(strategy.orderId(), 0, "order pulled back under the cap");
        assertEq(strategy.orderSize(), 0);
    }

    function test_ninetyPercentLeaveAtOnceWithOrderFilled() public {
        _settle(15 minutes);
        strategy.rebalance();
        _buyMusdUntilDepeg(-12);
        _settle(1 hours);
        strategy.rebalance(); // order filled and closed: strategy holds USD
        uint256 p = strategy.principal();

        vm.prank(Mezo.SMUSD);
        strategy.deallocate((p * 90) / 100);
        assertEq(strategy.principal(), p - (p * 90) / 100);
    }

    function test_cannotConfigureOversizedOrders() public {
        PlumbAskStrategy.Params memory bad = PlumbAskStrategy.Params({
            vault: Mezo.SMUSD,
            pool: pool,
            nfpm: nfpm,
            router: router,
            usd: Mezo.MUSDC,
            musd: Mezo.MUSD,
            twapWindow: 1800,
            maxTwapDeviation: 30,
            maxOrderBps: 1_001,
            premium: 10,
            width: 40,
            buybackDepeg: 20,
            minRebalanceInterval: 10 minutes
        });
        vm.expectRevert(PlumbAskStrategy.BadParams.selector);
        new PlumbAskStrategy(bad);
    }

    // ------------------------------------------------------------------
    // Second blind review: accounting under a sustained premium
    // ------------------------------------------------------------------

    /// MUSD placed in the live order plus USD already collected from earlier fills (at par).
    /// USD still inside the live order is part of orderSize, so it is not counted twice.
    function _exposure() internal view returns (uint256) {
        return strategy.orderSize() + usdc.balanceOf(address(strategy)) * 1e12;
    }

    /// MUSD stays above $1 for several rebalances. Each new order must account for USD still
    /// held from earlier fills, so idle MUSD is never drained fill after fill.
    function test_sustainedPremiumKeepsExposureCapped() public {
        _settle(15 minutes);
        strategy.rebalance();
        uint256 cap = (strategy.principal() * 500) / 10_000;
        for (uint256 i; i < 4; i++) {
            _buyMusdUntilDepeg(-60); // push through whatever order is live
            _settle(1 hours);
            strategy.rebalance();
            // Fills pay $1.001 to $1.005 per MUSD, so USD held can exceed the MUSD it replaced
            // by up to the order's 0.4% band. That surplus is profit, not new exposure.
            assertLe(_exposure(), (cap * 1_005) / 1_000, "exposure above cap");
            assertEq(strategy.orderSize() == 0 || usdc.balanceOf(address(strategy)) * 1e12 < cap, true);
            assertGe(musd.balanceOf(address(strategy)) + 1e18, strategy.principal() - cap, "idle drained");
        }
    }

    function test_noYieldWhileFillsAreUnrealised() public {
        _settle(15 minutes);
        strategy.rebalance();
        _buyMusdUntilDepeg(-12);
        _settle(1 hours);
        strategy.rebalance();
        (,, uint256 usdHeld) = strategy.totalHoldings();
        assertGt(usdHeld, 0);

        vm.prank(Mezo.SMUSD);
        assertEq(strategy.claimYield(), 0, "paid yield on an unrealised fill");
    }

    function test_migrateWaitsForFillsToBeBoughtBack() public {
        _settle(15 minutes);
        strategy.rebalance();
        _buyMusdUntilDepeg(-60); // order fills; MUSD stays above its sell price
        _settle(1 hours);
        strategy.rebalance();
        (,, uint256 usdHeld) = strategy.totalHoldings();
        assertGt(usdHeld, 0);

        PlumbAskStrategy next = new PlumbAskStrategy(
            PlumbAskStrategy.Params({
                vault: Mezo.SMUSD,
                pool: pool,
                nfpm: nfpm,
                router: router,
                usd: Mezo.MUSDC,
                musd: Mezo.MUSD,
                twapWindow: 1800,
                maxTwapDeviation: 30,
                maxOrderBps: 0,
                premium: 10,
                width: 40,
                buybackDepeg: 20,
                minRebalanceInterval: 10 minutes
            })
        );
        address owner = smusd.owner();
        vm.prank(owner);
        vm.expectPartialRevert(PlumbAskStrategy.UsdOutstanding.selector);
        smusd.setStrategy(address(next));

        // Once MUSD trades back below the sell price, the switch goes through with no USD left.
        _swap(Mezo.MUSD, Mezo.MUSDC, 3_000_000e18);
        _settle(1 hours);
        uint256 principal = strategy.principal();
        vm.prank(owner);
        smusd.setStrategy(address(next));
        assertEq(usdc.balanceOf(address(strategy)), 0);
        assertGe(next.principal(), principal, "savers lost MUSD on the round trip");
    }

    // ------------------------------------------------------------------
    // Third blind review: sMUSD safety and governance exit
    // ------------------------------------------------------------------

    /// sMUSD calls claimYield on every deposit and withdrawal. A pool or NFT-manager outage
    /// must never block savers.
    function test_saversUnaffectedByPoolOutage() public {
        _settle(15 minutes);
        strategy.rebalance();
        vm.mockCallRevert(Mezo.POOL, abi.encodeWithSignature("observe(uint32[])"), "down");
        vm.mockCallRevert(Mezo.POOL, abi.encodeWithSignature("slot0()"), "down");
        vm.mockCallRevert(Mezo.NFPM, abi.encodeWithSignature("positions(uint256)"), "down");

        deal(Mezo.MUSD, saver, 500e18);
        vm.startPrank(saver);
        musd.approve(Mezo.SMUSD, 500e18);
        smusd.deposit(500e18);
        smusd.withdraw(500e18);
        vm.stopPrank();
        assertEq(musd.balanceOf(saver), 500e18);
    }

    function test_roundingReserveIsNeverPaidAsYield() public {
        uint256 before = musd.balanceOf(address(strategy));
        vm.prank(Mezo.SMUSD);
        uint256 paid = strategy.claimYield();
        assertEq(paid, 0, "reserve paid out as yield");
        assertEq(musd.balanceOf(address(strategy)), before);
        assertGe(musd.balanceOf(address(strategy)), strategy.principal() + strategy.ROUNDING_RESERVE());
    }

    function test_buybackRefusedWhileSpotDisagreesWithTwap() public {
        _settle(15 minutes);
        strategy.rebalance();
        _buyMusdUntilDepeg(-12);
        _settle(1 hours);
        strategy.rebalance(); // holds USD from the fill
        uint256 usdBefore = usdc.balanceOf(address(strategy));
        assertGt(usdBefore, 0);

        // Someone dumps hard in this block: spot leaves the TWAP far behind.
        _swap(Mezo.MUSD, Mezo.MUSDC, 3_000_000e18);
        // More than idle MUSD plus the live order can cover, so only a buyback could pay it.
        uint256 need = musd.balanceOf(address(strategy)) + strategy.orderSize() + 1e18;
        vm.prank(Mezo.SMUSD);
        vm.expectPartialRevert(PlumbAskStrategy.Shortfall.selector);
        strategy.deallocate(need);
        assertEq(usdc.balanceOf(address(strategy)), usdBefore);
    }

    function test_governanceCanHandOffUsdInAnEmergency() public {
        _settle(15 minutes);
        strategy.rebalance();
        _buyMusdUntilDepeg(-60);
        _settle(1 hours);
        strategy.rebalance();
        uint256 usdHeld = usdc.balanceOf(address(strategy));
        assertGt(usdHeld, 0);

        address owner = smusd.owner();
        vm.expectRevert(PlumbAskStrategy.OnlyVaultOwner.selector);
        strategy.setUsdHandoff(true);
        vm.prank(owner);
        strategy.setUsdHandoff(true);

        PlumbAskStrategy next = new PlumbAskStrategy(
            PlumbAskStrategy.Params({
                vault: Mezo.SMUSD,
                pool: pool,
                nfpm: nfpm,
                router: router,
                usd: Mezo.MUSDC,
                musd: Mezo.MUSD,
                twapWindow: 1800,
                maxTwapDeviation: 30,
                maxOrderBps: 0,
                premium: 10,
                width: 40,
                buybackDepeg: 20,
                minRebalanceInterval: 10 minutes
            })
        );
        uint256 ownerUsd = usdc.balanceOf(owner);
        vm.prank(owner);
        smusd.setStrategy(address(next));
        assertEq(usdc.balanceOf(owner) - ownerUsd, usdHeld, "USD handed to the owner");
        assertEq(usdc.balanceOf(address(strategy)), 0);
    }

    function test_onlyVaultMovesFunds() public {
        vm.expectRevert(PlumbAskStrategy.OnlyVault.selector);
        strategy.deallocate(1);
        vm.expectRevert(PlumbAskStrategy.OnlyVault.selector);
        strategy.migrate(address(this));
        vm.expectRevert(PlumbAskStrategy.OnlyVault.selector);
        strategy.claimYield();
    }

    function _buyMusdUntilDepeg(int24 target) internal {
        for (uint256 i; i < 80; i++) {
            int24 depeg = (_spotTick() - strategy.parTick()) * strategy.dir();
            if (depeg <= target) return;
            _swap(Mezo.MUSDC, Mezo.MUSD, 250_000e6);
        }
        revert("could not reach target");
    }
}
