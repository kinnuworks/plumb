// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlumbAskStrategy} from "../../src/PlumbAskStrategy.sol";
import {IMUSDSavingsRate} from "../../src/interfaces/IMUSDSavingsRate.sol";
import {ICLSwapRouter} from "../../src/interfaces/ICLSwapRouter.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/IMezoCL.sol";
import {MezoFork, Mezo} from "../fork/MezoFork.sol";

/// Savers come and go through the real sMUSD vault while the market moves.
contract AskStrategyHandler is Test {
    PlumbAskStrategy internal strategy;
    IMUSDSavingsRate internal smusd = IMUSDSavingsRate(Mezo.SMUSD);
    ICLSwapRouter internal router = ICLSwapRouter(Mezo.ROUTER);
    address[] internal savers;

    uint256 public failedWithdrawals;

    constructor(PlumbAskStrategy strategy_) {
        strategy = strategy_;
        for (uint256 i; i < 3; i++) savers.push(makeAddr(string(abi.encodePacked("saver", vm.toString(i)))));
    }

    function save(uint256 who, uint256 amount) external {
        address s = savers[who % savers.length];
        amount = bound(amount, 1e18, 500_000e18);
        deal(Mezo.MUSD, s, amount);
        vm.startPrank(s);
        IERC20(Mezo.MUSD).approve(Mezo.SMUSD, amount);
        smusd.deposit(amount);
        vm.stopPrank();
    }

    /// Savers withdraw up to everything they hold. Small withdrawals must never fail.
    function withdraw(uint256 who, uint256 amount) external {
        address s = savers[who % savers.length];
        uint256 bal = smusd.balanceOf(s);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(s);
        try smusd.withdraw(amount) {}
        catch {
            failedWithdrawals++;
        }
    }

    function pump(uint256 amount) external {
        _swap(Mezo.MUSDC, Mezo.MUSD, bound(amount, 1_000e6, 2_000_000e6));
    }

    function dump(uint256 amount) external {
        _swap(Mezo.MUSD, Mezo.MUSDC, bound(amount, 1_000e18, 2_000_000e18));
    }

    function passTime(uint256 secs) external {
        secs = bound(secs, 1 minutes, 6 hours);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 3);
    }

    function rebalance() external {
        try strategy.rebalance() {} catch {}
    }

    function harvest() external {
        smusd.receiveYieldFromStrategy();
    }

    function _swap(address tokenIn, address tokenOut, uint256 amount) internal {
        address t = makeAddr("market");
        deal(tokenIn, t, amount);
        vm.startPrank(t);
        IERC20(tokenIn).approve(address(router), amount);
        try router.exactInputSingle(
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
        ) {} catch {}
        vm.stopPrank();
    }
}

contract PlumbAskStrategyInvariantTest is MezoFork {
    PlumbAskStrategy internal strategy;
    AskStrategyHandler internal handler;

    function setUp() public {
        _fork();
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
                maxOrderBps: 500,
                premium: 10,
                width: 40,
                buybackDepeg: 20,
                minRebalanceInterval: 10 minutes
            })
        );
        deal(Mezo.MUSD, address(strategy), 1e15); // rounding reserve
        vm.prank(smusd.owner());
        smusd.setStrategy(address(strategy));

        handler = new AskStrategyHandler(strategy);
        targetContract(address(handler));
    }

    /// The order never offers MUSD below $1.001. Mainnet layout: lower tick = dearer MUSD.
    /// forge-config: default.invariant.runs = 10
    /// forge-config: default.invariant.depth = 25
    function invariant_neverSellsBelowParPlusPremium() public view {
        uint256 id = strategy.orderId();
        if (id == 0) return;
        (,,,,,, int24 tu,,,,,) = INonfungiblePositionManager(Mezo.NFPM).positions(id);
        assertLe(tu, strategy.parTick() - 10);
    }

    /// The order stays within its cap of principal.
    /// forge-config: default.invariant.runs = 10
    /// forge-config: default.invariant.depth = 25
    function invariant_orderWithinCap() public view {
        if (strategy.orderId() == 0) return;
        assertLe(strategy.orderSize(), (strategy.principal() * 500) / 10_000 + 1);
    }

    /// Savers' principal stays backed: idle MUSD, MUSD in the order, and USD from fills
    /// (sold at >= $1.001) together cover it, allowing only a forced buyback's bounded loss.
    /// forge-config: default.invariant.runs = 10
    /// forge-config: default.invariant.depth = 25
    function invariant_principalIsBacked() public view {
        (uint256 idle, uint256 inOrder, uint256 usdHeld) = strategy.totalHoldings();
        uint256 backing = idle + inOrder + usdHeld * 1e12;
        assertGe(backing * 1_000, strategy.principal() * 999);
    }

    /// Savers withdrawing within what is idle never fail.
    /// forge-config: default.invariant.runs = 10
    /// forge-config: default.invariant.depth = 25
    function invariant_withdrawalsDoNotFail() public view {
        assertEq(handler.failedWithdrawals(), 0);
    }
}
