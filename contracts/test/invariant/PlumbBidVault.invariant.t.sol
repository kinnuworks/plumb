// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlumbBidVault} from "../../src/PlumbBidVault.sol";
import {IMUSDSavingsRate} from "../../src/interfaces/IMUSDSavingsRate.sol";
import {ICLSwapRouter} from "../../src/interfaces/ICLSwapRouter.sol";
import {MezoFork, Mezo} from "../fork/MezoFork.sol";

/// Drives the vault with random users and a random market on a mainnet fork.
contract BidVaultHandler is Test {
    PlumbBidVault internal vault;
    ICLSwapRouter internal router = ICLSwapRouter(Mezo.ROUTER);
    address[] internal actors;

    uint256 public deposits;
    uint256 public depositsBelowFloor;
    uint256 public redemptions;
    uint256 public rebalances;

    constructor(PlumbBidVault vault_) {
        vault = vault_;
        for (uint256 i; i < 4; i++) actors.push(makeAddr(string(abi.encodePacked("actor", vm.toString(i)))));
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address a = actors[actorSeed % actors.length];
        amount = bound(amount, 1e6, 200_000e6);
        deal(Mezo.MUSDC, a, amount);
        vm.startPrank(a);
        IERC20(Mezo.MUSDC).approve(address(vault), amount);
        bool belowFloor = vault.currentDepeg() >= vault.floorDepeg();
        try vault.depositAndDeploy(amount, 0, a) {
            deposits++;
            if (belowFloor) depositsBelowFloor++;
        } catch {}
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 fraction) external {
        address a = actors[actorSeed % actors.length];
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bound(fraction, 1, bal);
        vm.prank(a);
        vault.redeem(shares, 0, 0, a); // must never revert for a holder
        redemptions++;
    }

    function sellMusd(uint256 amount) external {
        _swap(Mezo.MUSD, Mezo.MUSDC, bound(amount, 1_000e18, 300_000e18));
    }

    function buyMusd(uint256 amount) external {
        _swap(Mezo.MUSDC, Mezo.MUSD, bound(amount, 1_000e6, 300_000e6));
    }

    function passTime(uint256 secs) external {
        secs = bound(secs, 1 minutes, 6 hours);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 3);
    }

    function rebalance() external {
        try vault.rebalance() {
            rebalances++;
        } catch {}
    }

    function claim(uint256 actorSeed) external {
        address a = actors[actorSeed % actors.length];
        vm.prank(a);
        vault.claimMezo(a);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amount) internal {
        address trader = makeAddr("market");
        deal(tokenIn, trader, amount);
        vm.startPrank(trader);
        IERC20(tokenIn).approve(address(router), amount);
        try router.exactInputSingle(
            ICLSwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                tickSpacing: 10,
                recipient: trader,
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        ) {} catch {}
        vm.stopPrank();
    }
}

contract PlumbBidVaultInvariantTest is MezoFork {
    PlumbBidVault internal vault;
    BidVaultHandler internal handler;

    function setUp() public {
        _fork();
        vault = new PlumbBidVault(
            PlumbBidVault.Params({
                pool: pool,
                nfpm: nfpm,
                gauge: gauge,
                smusd: IMUSDSavingsRate(Mezo.SMUSD),
                usd: Mezo.MUSDC,
                musd: Mezo.MUSD,
                treasury: makeAddr("treasury"),
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
                depositCap: 0
            }),
            "Plumb MUSD Bid",
            "plumbBID"
        );
        handler = new BidVaultHandler(vault);
        targetContract(address(handler));
    }

    /// MEZO owed to holders is always fully backed.
    /// forge-config: default.invariant.runs = 12
    /// forge-config: default.invariant.depth = 30
    function invariant_mezoOwedIsBacked() public view {
        assertGe(mezo.balanceOf(address(vault)), vault.mezoLiabilities());
    }

    /// Shares never exist without tokens behind them. (Their USD value can reach zero if MUSD's
    /// pool price collapses, but the vault still holds the MUSD.)
    /// forge-config: default.invariant.runs = 12
    /// forge-config: default.invariant.depth = 30
    function invariant_sharesAreBacked() public view {
        if (vault.totalSupply() == 0) return;
        (uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f, uint256 g) = vault.holdings();
        assertGt(a + b + c + d + e + f + g, 0);
    }

    /// Found by this suite: when a dump drains the pool, its price collapses and shares would
    /// be mispriced. No deposit may ever succeed in that state.
    /// forge-config: default.invariant.runs = 12
    /// forge-config: default.invariant.depth = 30
    function invariant_noDepositsBelowFloor() public view {
        assertEq(handler.depositsBelowFloor(), 0);
    }

    /// The vault never bids at or above $1 and never offers MUSD below $1.
    /// Mainnet layout: higher tick = cheaper MUSD.
    /// forge-config: default.invariant.runs = 12
    /// forge-config: default.invariant.depth = 30
    function invariant_ordersRespectPar() public view {
        (uint256 bidId,) = vault.bid();
        if (bidId != 0) {
            (,,,,, int24 tl,,,,,,) = nfpm.positions(bidId);
            assertGe(tl, vault.parTick() + vault.tickSpacing(), "bid at or above $1");
        }
        (uint256 askId,) = vault.ask();
        if (askId != 0) {
            (,,,,,, int24 tu,,,,,) = nfpm.positions(askId);
            assertLe(tu, vault.parTick(), "ask below $1");
        }
    }

    /// Only the vault's own live positions are ever held, never stray NFTs.
    /// forge-config: default.invariant.runs = 12
    /// forge-config: default.invariant.depth = 30
    function invariant_noStrayPositions() public view {
        (uint256 bidId, bool bidStaked) = vault.bid();
        (uint256 askId, bool askStaked) = vault.ask();
        uint256 held = IERC20(Mezo.NFPM).balanceOf(address(vault));
        uint256 expected = (bidId != 0 && !bidStaked ? 1 : 0) + (askId != 0 && !askStaked ? 1 : 0);
        assertEq(held, expected);
    }

    /// Every share is redeemable: no MUSD is lost to the void between sMUSD and the vault.
    /// forge-config: default.invariant.runs = 12
    /// forge-config: default.invariant.depth = 30
    function invariant_parkedMusdMatchesSmusdBalance() public view {
        (,, uint256 parked,,,,) = vault.holdings();
        assertEq(parked, IMUSDSavingsRate(Mezo.SMUSD).balanceOf(address(vault)));
    }
}
