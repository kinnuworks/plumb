// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

/// @title PegMath
/// @notice Tick arithmetic for a stable/MUSD concentrated-liquidity pool, in "depeg ticks".
/// @dev A depeg tick of +d means MUSD trades d ticks (about d basis points) below $1.
///      Working in this space lets the same vault code run whichever way the pool
///      orders its tokens: USD is token0 on Mezo mainnet and token1 on Mezo testnet.
library PegMath {
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    /// @notice The pool tick where one MUSD is worth exactly one USD token.
    /// @param usdIsToken0 True if the USD stablecoin is the pool's token0.
    /// @param decimalsGap MUSD decimals minus USD decimals. Must be even and non-negative.
    function parTick(bool usdIsToken0, uint8 decimalsGap) internal pure returns (int24) {
        require(decimalsGap % 2 == 0, "PegMath: odd decimals gap");
        uint256 rootScale = 10 ** (decimalsGap / 2);
        // Pool price is token1 per token0 in raw units. At par:
        //   USD is token0 -> price = 10^gap (MUSD raw per USD raw)
        //   USD is token1 -> price = 10^-gap
        uint160 sqrtPriceX96 = usdIsToken0 ? uint160(Q96 * rootScale) : uint160(Q96 / rootScale);
        return TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

    /// @notice +1 if a higher pool tick means cheaper MUSD, -1 otherwise.
    function direction(bool usdIsToken0) internal pure returns (int24) {
        return usdIsToken0 ? int24(1) : int24(-1);
    }

    function toDepeg(int24 tick, int24 par, int24 dir) internal pure returns (int24) {
        return (tick - par) * dir;
    }

    function toTick(int24 depeg, int24 par, int24 dir) internal pure returns (int24) {
        return par + depeg * dir;
    }

    /// @notice Converts a depeg-space range to an ordered pool tick range.
    function toTickRange(int24 depegLo, int24 depegHi, int24 par, int24 dir)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        int24 a = toTick(depegLo, par, dir);
        int24 b = toTick(depegHi, par, dir);
        (tickLower, tickUpper) = a < b ? (a, b) : (b, a);
    }

    /// @notice Rounds toward negative infinity onto the spacing grid.
    function floorToSpacing(int24 x, int24 spacing) internal pure returns (int24) {
        int24 q = x / spacing;
        if (x < 0 && x % spacing != 0) q -= 1;
        return q * spacing;
    }

    /// @notice Rounds toward positive infinity onto the spacing grid.
    function ceilToSpacing(int24 x, int24 spacing) internal pure returns (int24) {
        int24 f = floorToSpacing(x, spacing);
        return f == x ? f : f + spacing;
    }

    /// @notice USD value (in USD raw units) of `musdAmount` at pool price `sqrtPriceX96`.
    function musdToUsd(uint256 musdAmount, uint160 sqrtPriceX96, bool usdIsToken0)
        internal
        pure
        returns (uint256)
    {
        if (musdAmount == 0) return 0;
        if (usdIsToken0) {
            // price = MUSD per USD, so USD = MUSD / price = MUSD * Q96^2 / sqrtP^2
            return FullMath.mulDiv(FullMath.mulDiv(musdAmount, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
        }
        // price = USD per MUSD, so USD = MUSD * sqrtP^2 / Q96^2
        return FullMath.mulDiv(FullMath.mulDiv(musdAmount, sqrtPriceX96, Q96), sqrtPriceX96, Q96);
    }

    /// @notice MUSD (raw) that `usdAmount` buys at pool price `sqrtPriceX96`.
    function usdToMusd(uint256 usdAmount, uint160 sqrtPriceX96, bool usdIsToken0)
        internal
        pure
        returns (uint256)
    {
        if (usdAmount == 0) return 0;
        if (usdIsToken0) {
            // price = MUSD per USD
            return FullMath.mulDiv(FullMath.mulDiv(usdAmount, sqrtPriceX96, Q96), sqrtPriceX96, Q96);
        }
        // price = USD per MUSD
        return FullMath.mulDiv(FullMath.mulDiv(usdAmount, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
    }
}
