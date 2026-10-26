// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import {ICLPool, INonfungiblePositionManager} from "./interfaces/IMezoCL.sol";
import {PegMath} from "./libraries/PegMath.sol";

/// @title PegBook
/// @notice Shared mechanics for keeping single-sided orders on a MUSD/USD concentrated pool:
///         TWAP reads with a spot sanity check, minting bids and asks in depeg space, and
///         unwinding positions. Plumb's vault and its sMUSD strategy both build on it.
abstract contract PegBook is IERC721Receiver {
    using SafeERC20 for IERC20;

    ICLPool public immutable pool;
    INonfungiblePositionManager public immutable nfpm;
    IERC20 public immutable usd;
    IERC20 public immutable musd;

    bool public immutable usdIsToken0;
    int24 public immutable tickSpacing;
    /// @notice Grid tick closest to 1 MUSD = 1 USD on the side where MUSD is worth at least $1.
    int24 public immutable parTick;
    /// @notice +1 when a higher pool tick means cheaper MUSD, -1 otherwise.
    int24 public immutable dir;
    uint32 public immutable twapWindow;
    int24 public immutable maxTwapDeviation;
    uint256 internal immutable musdPerUsdAtPar;

    error PriceUnstable(int24 spotTick, int24 twapTick);
    error NotSingleSided();
    error UnexpectedNft();
    error BadPool();

    constructor(
        ICLPool pool_,
        INonfungiblePositionManager nfpm_,
        address usd_,
        address musd_,
        uint32 twapWindow_,
        int24 maxTwapDeviation_
    ) {
        if (address(pool_) == address(0) || address(nfpm_) == address(0) || twapWindow_ == 0) revert BadPool();
        address t0 = pool_.token0();
        address t1 = pool_.token1();
        if (!((t0 == usd_ && t1 == musd_) || (t0 == musd_ && t1 == usd_))) revert BadPool();

        uint8 dUsd = IERC20Metadata(usd_).decimals();
        uint8 dMusd = IERC20Metadata(musd_).decimals();
        if (dMusd < dUsd) revert BadPool();

        pool = pool_;
        nfpm = nfpm_;
        usd = IERC20(usd_);
        musd = IERC20(musd_);
        usdIsToken0 = t0 == usd_;
        int24 spacing = pool_.tickSpacing();
        int24 direction = PegMath.direction(usdIsToken0);
        int24 exactPar = PegMath.parTick(usdIsToken0, dMusd - dUsd);
        tickSpacing = spacing;
        dir = direction;
        // Snap $1 onto the pool's tick grid on the side where MUSD is worth at least $1, so an
        // ask placed "at par" can never fill below $1.
        parTick = direction > 0
            ? PegMath.floorToSpacing(exactPar, spacing)
            : PegMath.ceilToSpacing(exactPar, spacing);
        twapWindow = twapWindow_;
        maxTwapDeviation = maxTwapDeviation_;
        musdPerUsdAtPar = 10 ** (dMusd - dUsd);
    }

    // ------------------------------------------------------------------
    // Pricing
    // ------------------------------------------------------------------

    function _twap() internal view returns (uint160 sqrtPriceX96, int24 twapTick) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = twapWindow;
        (int56[] memory cumulatives,) = pool.observe(ago);
        int56 delta = cumulatives[1] - cumulatives[0];
        int56 window = int56(uint56(twapWindow));
        // forge-lint: disable-next-line(unsafe-typecast)
        twapTick = int24(delta / window); // |delta / window| is a tick, so it fits in int24
        if (delta < 0 && delta % window != 0) twapTick--;
        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(twapTick);
    }

    /// @dev Reverts unless the live price agrees with the TWAP, which blocks same-block
    ///      price manipulation from steering where liquidity is placed.
    function _checkedPrice() internal view returns (uint160 sqrtTwap, int24 twapTick, int24 spotTick) {
        (sqrtTwap, twapTick) = _twap();
        (, spotTick,,,,) = pool.slot0();
        int24 gap = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
        if (gap > maxTwapDeviation) revert PriceUnstable(spotTick, twapTick);
    }

    function _depeg(int24 tick) internal view returns (int24) {
        return PegMath.toDepeg(tick, parTick, dir);
    }

    /// @dev MUSD valued at `sqrtPriceX96` but never above $1, so a squeeze cannot inflate value.
    function _musdValue(uint256 musdAmount, uint160 sqrtPriceX96) internal view returns (uint256) {
        uint256 atMarket = PegMath.musdToUsd(musdAmount, sqrtPriceX96, usdIsToken0);
        uint256 atPar = musdAmount / musdPerUsdAtPar;
        return atMarket < atPar ? atMarket : atPar;
    }

    // ------------------------------------------------------------------
    // Orders
    // ------------------------------------------------------------------

    /// @dev Places a USD-only bid over depeg ticks [lo, hi]. Returns 0 if the range is empty.
    function _placeBid(int24 lo, int24 hi, uint256 usdAmount) internal returns (uint256 tokenId, uint256 usdUsed) {
        if (usdAmount == 0 || hi <= lo) return (0, 0);
        uint256 musdUsed;
        (tokenId, usdUsed, musdUsed) = _mint(lo, hi, usdAmount, 0);
        if (musdUsed != 0) revert NotSingleSided();
    }

    /// @dev Places a MUSD-only ask over depeg ticks [lo, hi]. Returns 0 if the range is empty.
    function _placeAsk(int24 lo, int24 hi, uint256 musdAmount) internal returns (uint256 tokenId, uint256 musdUsed) {
        if (musdAmount == 0 || hi <= lo) return (0, 0);
        uint256 usdUsed;
        (tokenId, usdUsed, musdUsed) = _mint(lo, hi, 0, musdAmount);
        if (usdUsed != 0) revert NotSingleSided();
    }

    /// @dev Lowest bid edge strictly cheaper than `depeg`, and at least one grid step below $1
    ///      (par is snapped to the dear side, so a bid at depeg 0 could pay a hair over $1).
    function _bidStart(int24 depeg) internal view returns (int24 lo) {
        lo = PegMath.ceilToSpacing(depeg, tickSpacing);
        if (lo == depeg) lo += tickSpacing;
        if (lo < tickSpacing) lo = tickSpacing;
    }

    /// @dev Highest ask edge strictly dearer than `depeg`, and at or above $1 plus `premium`.
    function _askEnd(int24 depeg, int24 premium) internal view returns (int24 hi) {
        hi = PegMath.floorToSpacing(depeg, tickSpacing);
        if (hi == depeg) hi -= tickSpacing;
        int24 cap = -PegMath.ceilToSpacing(premium, tickSpacing);
        if (hi > cap) hi = cap;
    }

    function _mint(int24 depegLo, int24 depegHi, uint256 usdAmount, uint256 musdAmount)
        private
        returns (uint256 tokenId, uint256 usdUsed, uint256 musdUsed)
    {
        (int24 tickLower, int24 tickUpper) = PegMath.toTickRange(depegLo, depegHi, parTick, dir);
        (uint256 a0, uint256 a1) = usdIsToken0 ? (usdAmount, musdAmount) : (musdAmount, usdAmount);

        if (usdAmount > 0) usd.forceApprove(address(nfpm), usdAmount);
        if (musdAmount > 0) musd.forceApprove(address(nfpm), musdAmount);

        uint256 used0;
        uint256 used1;
        (tokenId,, used0, used1) = nfpm.mint(
            INonfungiblePositionManager.MintParams({
                token0: usdIsToken0 ? address(usd) : address(musd),
                token1: usdIsToken0 ? address(musd) : address(usd),
                tickSpacing: tickSpacing,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp,
                sqrtPriceX96: 0
            })
        );
        (usdUsed, musdUsed) = usdIsToken0 ? (used0, used1) : (used1, used0);

        if (usdAmount > 0) usd.forceApprove(address(nfpm), 0);
        if (musdAmount > 0) musd.forceApprove(address(nfpm), 0);
    }

    /// @dev Removes `liquidity` from `tokenId` and collects everything owed. Burns the NFT if empty.
    function _withdrawLiquidity(uint256 tokenId, uint128 liquidity, bool burnIfEmpty)
        internal
        returns (uint256 usdOut, uint256 musdOut, bool burned)
    {
        if (liquidity > 0) {
            nfpm.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }
        (uint256 c0, uint256 c1) = nfpm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        (usdOut, musdOut) = usdIsToken0 ? (c0, c1) : (c1, c0);

        if (burnIfEmpty && _liquidityOf(tokenId) == 0) {
            nfpm.burn(tokenId);
            burned = true;
        }
    }

    function _liquidityOf(uint256 tokenId) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = nfpm.positions(tokenId);
    }

    /// @dev Token amounts a position would release at `sqrtPriceX96`, including uncollected tokens.
    function _positionAmounts(uint256 tokenId, uint160 sqrtPriceX96)
        internal
        view
        returns (uint256 usdAmt, uint256 musdAmt)
    {
        if (tokenId == 0) return (0, 0);
        (,,,,, int24 tl, int24 tu, uint128 liquidity,,, uint128 owed0, uint128 owed1) = nfpm.positions(tokenId);
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(tl), TickMath.getSqrtRatioAtTick(tu), liquidity
        );
        a0 += owed0;
        a1 += owed1;
        (usdAmt, musdAmt) = usdIsToken0 ? (a0, a1) : (a1, a0);
    }

    // ------------------------------------------------------------------
    // ERC-721 receiver
    // ------------------------------------------------------------------

    /// @dev Positions may only come from the NFT manager, minted by us or returned by a gauge.
    function _allowedNftOperator(address operator) internal view virtual returns (bool) {
        return operator == address(this);
    }

    function onERC721Received(address operator, address, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(nfpm) || !_allowedNftOperator(operator)) revert UnexpectedNft();
        return IERC721Receiver.onERC721Received.selector;
    }
}
