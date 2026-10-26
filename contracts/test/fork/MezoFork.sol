// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICLPool, INonfungiblePositionManager, ICLGauge, IPoolsVoter} from "../../src/interfaces/IMezoCL.sol";
import {ICLSwapRouter} from "../../src/interfaces/ICLSwapRouter.sol";
import {IMUSDSavingsRate} from "../../src/interfaces/IMUSDSavingsRate.sol";
import {PrecompileERC20} from "../mocks/PrecompileERC20.sol";

/// Mezo mainnet (chain 31612) addresses, all read from chain or verified explorer sources.
library Mezo {
    address internal constant MUSD = 0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186;
    address internal constant MUSDC = 0x04671C72Aab5AC02A03c1098314b1BB6B560c197;
    address internal constant MEZO = 0x7B7c000000000000000000000000000000000001;
    address internal constant POOL = 0xCC372B7E15535aB225fe17c1075831D38ef7aC1a; // MUSD/mUSDC CL, spacing 10
    address internal constant NFPM = 0x509Bc221df2B83927c695FA0bb0f5B21053C874c;
    address internal constant GAUGE = 0x6d446E27505c71EE39D632488cE849fEF6aFFc57;
    address internal constant POOLS_VOTER = 0x48233cCC97B87Ba93bCA212cbEe48e3210211f03;
    address internal constant ROUTER = 0x37cDd11919ec3860eaD9efB8673d7476E5326225;
    address internal constant SMUSD = 0xb4D498029af77680cD1eF828b967f010d06C51CC;
    address internal constant IDLE_STRATEGY = 0x0C0944713c185ea3e64F5609ECee3fB3C054a295;
}

/// Shared fork fixture. Pins a block so every run sees the same pool state.
abstract contract MezoFork is Test {
    uint256 internal constant FORK_BLOCK = 12_772_660;

    ICLPool internal pool = ICLPool(Mezo.POOL);
    INonfungiblePositionManager internal nfpm = INonfungiblePositionManager(Mezo.NFPM);
    ICLGauge internal gauge = ICLGauge(Mezo.GAUGE);
    ICLSwapRouter internal router = ICLSwapRouter(Mezo.ROUTER);
    IMUSDSavingsRate internal smusd = IMUSDSavingsRate(Mezo.SMUSD);
    IERC20 internal usdc = IERC20(Mezo.MUSDC);
    IERC20 internal musd = IERC20(Mezo.MUSD);
    IERC20 internal mezo = IERC20(Mezo.MEZO);

    function _fork() internal {
        vm.createSelectFork(vm.envString("MEZO_RPC_URL"), FORK_BLOCK);

        // MEZO is a Mezo precompile that Foundry cannot run. Replace it with a plain ERC-20 at
        // the same address and give the gauge enough to pay the rewards it has scheduled.
        vm.etch(Mezo.MEZO, address(new PrecompileERC20()).code);
        deal(Mezo.MEZO, Mezo.GAUGE, 50_000_000e18);
        vm.label(Mezo.POOL, "MUSD/mUSDC pool");
        vm.label(Mezo.GAUGE, "gauge");
        vm.label(Mezo.SMUSD, "sMUSD");
        vm.label(Mezo.MUSD, "MUSD");
        vm.label(Mezo.MUSDC, "mUSDC");
    }

    function _bribe() internal view returns (address) {
        return IPoolsVoter(Mezo.POOLS_VOTER).gaugeToBribe(Mezo.GAUGE);
    }

    /// Sells `amount` of `tokenIn` into the pool from a fresh trader; returns the amount out.
    function _swap(address tokenIn, address tokenOut, uint256 amount) internal returns (uint256 out) {
        address trader = makeAddr("trader");
        deal(tokenIn, trader, amount);
        vm.startPrank(trader);
        IERC20(tokenIn).approve(address(router), amount);
        out = router.exactInputSingle(
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
        );
        vm.stopPrank();
    }

    /// What selling `musdAmount` would return right now, without changing state.
    function _quoteSellMusd(uint256 musdAmount) internal returns (uint256 usdOut) {
        uint256 snap = vm.snapshotState();
        usdOut = _swap(Mezo.MUSD, Mezo.MUSDC, musdAmount);
        vm.revertToState(snap);
    }

    function _spotTick() internal view returns (int24 tick) {
        (, tick,,,,) = pool.slot0();
    }

    /// Lets the pool's TWAP catch up with the spot price.
    function _settle(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 3);
    }
}
