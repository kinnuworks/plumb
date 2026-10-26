// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICLPool, INonfungiblePositionManager} from "./interfaces/IMezoCL.sol";
import {ICLSwapRouter} from "./interfaces/ICLSwapRouter.sol";
import {IVaultStrategy} from "./interfaces/IMUSDSavingsRate.sol";
import {PegBook} from "./PegBook.sol";
import {PegMath} from "./libraries/PegMath.sol";

/// @title PlumbAskStrategy
/// @notice A strategy for Mezo's sMUSD savings vault that turns idle MUSD into a standing
///         offer to sell MUSD at $1 or above.
///
/// sMUSD holds its deposits in an IdleStrategy that earns nothing. This strategy keeps most
/// of that MUSD idle so withdrawals stay instant, and places a capped slice as a MUSD-only
/// order on the MUSD/USD pool between $1 + premium and $1 + premium + width. The order can
/// only fill when buyers pay at least that price, so savers never sell below par. When the
/// order fills, the USD it receives is bought back into MUSD once MUSD is cheaper again,
/// and the MUSD surplus over principal is paid to sMUSD holders as yield.
///
/// Only the sMUSD vault can move funds. Anyone can call rebalance(), which only re-places
/// the order inside these fixed bounds.
///
/// Rounding: closing a concentrated position returns up to 1 wei less than went in. The
/// deployer seeds the strategy with a small MUSD reserve (outside principal) that covers
/// these losses for longer than the strategy could ever run.
contract PlumbAskStrategy is PegBook, IVaultStrategy, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Params {
        address vault; // the sMUSD vault
        ICLPool pool;
        INonfungiblePositionManager nfpm;
        ICLSwapRouter router;
        address usd;
        address musd;
        uint32 twapWindow;
        int24 maxTwapDeviation;
        uint16 maxOrderBps; // largest share of principal that may sit in the order
        int24 premium; // ticks above $1 where the order starts (10 is about $1.001)
        int24 width; // ticks covered by the order
        int24 buybackDepeg; // buy MUSD back with USD only when it trades this far below $1
        uint32 minRebalanceInterval;
    }

    uint256 private constant BPS = 10_000;
    /// The order may never hold more than 10% of principal, so at least 90% of savers' MUSD
    /// is always idle and pays withdrawals without touching the market.
    uint16 public constant MAX_ORDER_BPS = 1_000;
    /// A buyback must return at least this share of what the TWAP says the USD is worth.
    uint256 private constant BUYBACK_TOLERANCE_BPS = 50;

    address public immutable vault;
    ICLSwapRouter public immutable router;
    uint16 public immutable maxOrderBps;
    int24 public immutable premium;
    int24 public immutable width;
    int24 public immutable buybackDepeg;
    uint32 public immutable minRebalanceInterval;

    /// @notice MUSD owed back to the vault.
    uint256 public principal;
    /// @notice The live ask order, 0 if none.
    uint256 public orderId;
    /// @notice MUSD placed in the live order when it was opened.
    uint256 public orderSize;
    uint256 public lastRebalance;

    event Allocate(uint256 amount);
    event Deallocate(uint256 amount);
    event Migrated(address newStrategy, uint256 amount);
    event YieldPaid(uint256 amount);
    event OrderPlaced(uint256 tokenId, int24 depegLo, int24 depegHi, uint256 musdAmount);
    event BoughtBack(uint256 usdIn, uint256 musdOut);
    event BuyBackRefused(uint256 usdIn, uint256 minMusdOut);

    error OnlyVault();
    error RebalanceTooSoon(uint256 nextAllowed);
    error Shortfall(uint256 needed, uint256 available);
    error BadParams();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(Params memory p)
        PegBook(p.pool, p.nfpm, p.usd, p.musd, p.twapWindow, p.maxTwapDeviation)
    {
        if (
            p.vault == address(0) || address(p.router) == address(0) || p.maxOrderBps > MAX_ORDER_BPS
                || p.premium < 0 || p.width <= 0 || p.buybackDepeg < 0
        ) revert BadParams();
        vault = p.vault;
        router = p.router;
        maxOrderBps = p.maxOrderBps;
        premium = p.premium;
        width = p.width;
        buybackDepeg = p.buybackDepeg;
        minRebalanceInterval = p.minRebalanceInterval;
    }

    // ------------------------------------------------------------------
    // IVaultStrategy (vault only)
    // ------------------------------------------------------------------

    function allocate(uint256 amount) external override onlyVault nonReentrant {
        principal += amount;
        musd.safeTransferFrom(vault, address(this), amount);
        emit Allocate(amount);
    }

    /// @dev Pays from idle MUSD first. Only if that is short does it pull the order and, as a
    ///      last resort, buy MUSD with the order's USD. Withdrawals never wait on the market.
    function deallocate(uint256 amount) external override onlyVault nonReentrant {
        _ensureIdle(amount);
        principal -= amount;
        musd.safeTransfer(vault, amount);
        // Withdrawals shrink principal. Keep the order within its cap of what is left, so
        // the next withdrawal can still be paid from idle MUSD.
        if (orderId != 0 && orderSize > Math.mulDiv(principal, maxOrderBps, BPS)) {
            _closeOrder();
            _tryBuyBack();
        }
        emit Deallocate(amount);
    }

    /// @dev Pays out realised MUSD above principal. The vault expects the tokens to arrive in
    ///      this call, so only idle MUSD is used.
    function claimYield() external override onlyVault nonReentrant returns (uint256 amount) {
        amount = _idleSurplus();
        if (amount > 0) {
            musd.safeTransfer(vault, amount);
            emit YieldPaid(amount);
        }
    }

    /// @dev Unwinds everything into MUSD and hands it to the next strategy.
    function migrate(address newStrategy) external override onlyVault nonReentrant returns (uint256 amount) {
        _closeOrder();
        _tryBuyBack();
        amount = musd.balanceOf(address(this));
        uint256 strayUsd = usd.balanceOf(address(this));
        // Any USD that could not be swapped (no liquidity) goes to the vault owner's next
        // strategy too, so nothing is stranded here.
        if (strayUsd > 0) usd.safeTransfer(newStrategy, strayUsd);
        principal = 0;
        if (amount > 0) musd.safeTransfer(newStrategy, amount);
        emit Migrated(newStrategy, amount);
    }

    /// @dev setStrategy() transfers the previous strategy's balance before calling this.
    function onMigrated(uint256 amount) external override onlyVault {
        principal += amount;
    }

    // ------------------------------------------------------------------
    // Keeper
    // ------------------------------------------------------------------

    /// @notice Re-place the ask inside the fixed bounds. Anyone may call.
    function rebalance() external nonReentrant {
        uint256 next = lastRebalance + minRebalanceInterval;
        if (block.timestamp < next) revert RebalanceTooSoon(next);
        lastRebalance = block.timestamp;

        (, int24 twapTick, int24 spotTick) = _checkedPrice();
        int24 depeg = _depeg(twapTick);
        int24 spotDepeg = _depeg(spotTick);

        _closeOrder();

        // Fills turned MUSD into USD at >= $1. Buy it back only once MUSD is clearly cheaper,
        // which is where the strategy earns.
        if (depeg >= buybackDepeg && spotDepeg >= buybackDepeg) _tryBuyBack();

        uint256 size = Math.min(
            Math.mulDiv(principal, maxOrderBps, BPS), musd.balanceOf(address(this))
        );
        int24 dearest = depeg < spotDepeg ? depeg : spotDepeg;
        int24 hi = _askEnd(dearest, premium);
        int24 lo = hi - width;
        (uint256 tokenId, uint256 used) = _placeAsk(lo, hi, size);
        orderId = tokenId;
        orderSize = used;
        if (tokenId != 0) emit OrderPlaced(tokenId, lo, hi, used);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice MUSD-equivalent of everything held, with USD counted 1:1 (it was sold at >= $1).
    function totalHoldings() public view returns (uint256 musdIdle, uint256 musdInOrder, uint256 usdHeld) {
        (uint160 sqrtTwap,) = _twap();
        musdIdle = musd.balanceOf(address(this));
        uint256 orderUsd;
        (orderUsd, musdInOrder) = _positionAmounts(orderId, sqrtTwap);
        usdHeld = usd.balanceOf(address(this)) + orderUsd;
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    /// @dev Idle MUSD covers at least 90% of principal at all times (MAX_ORDER_BPS), so normal
    ///      withdrawals never reach the market. Only a withdrawal bigger than everything idle
    ///      pulls the order and, if the order has filled, buys MUSD back at a TWAP-checked price.
    function _ensureIdle(uint256 amount) internal {
        uint256 idle = musd.balanceOf(address(this));
        if (idle >= amount) return;
        _closeOrder();
        idle = musd.balanceOf(address(this));
        if (idle < amount) {
            _tryBuyBack();
            idle = musd.balanceOf(address(this));
        }
        if (idle < amount) revert Shortfall(amount, idle);
    }

    function _closeOrder() internal {
        uint256 tokenId = orderId;
        if (tokenId == 0) return;
        orderId = 0;
        orderSize = 0;
        _withdrawLiquidity(tokenId, _liquidityOf(tokenId), true);
    }

    /// @dev Swaps all held USD back into MUSD, refusing any price more than 0.5% worse than
    ///      the TWAP (so a sandwich cannot take more than that) or worse than $1.01. A refused
    ///      or failed swap leaves the USD in place instead of reverting the caller.
    function _tryBuyBack() internal returns (bool ok) {
        uint256 usdIn = usd.balanceOf(address(this));
        if (usdIn == 0) return true;
        (uint160 sqrtTwap,) = _twap();
        uint256 atTwap = PegMath.usdToMusd(usdIn, sqrtTwap, usdIsToken0);
        uint256 atParLess1 = Math.mulDiv(usdIn * musdPerUsdAtPar, 99, 100);
        uint256 minOut = Math.max(Math.mulDiv(atTwap, BPS - BUYBACK_TOLERANCE_BPS, BPS), atParLess1);

        usd.forceApprove(address(router), usdIn);
        try router.exactInputSingle(
            ICLSwapRouter.ExactInputSingleParams({
                tokenIn: address(usd),
                tokenOut: address(musd),
                tickSpacing: tickSpacing,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: usdIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 out) {
            emit BoughtBack(usdIn, out);
            ok = true;
        } catch {
            emit BuyBackRefused(usdIn, minOut);
        }
        usd.forceApprove(address(router), 0);
    }

    function _idleSurplus() internal view returns (uint256) {
        uint256 idle = musd.balanceOf(address(this));
        // Count MUSD still in the order and USD held as owed principal first.
        (uint160 sqrtTwap,) = _twap();
        (uint256 orderUsd, uint256 orderMusd) = _positionAmounts(orderId, sqrtTwap);
        uint256 usdAsMusd = (usd.balanceOf(address(this)) + orderUsd) * musdPerUsdAtPar;
        uint256 backing = idle + orderMusd + usdAsMusd;
        if (backing <= principal) return 0;
        uint256 surplus = backing - principal;
        return surplus < idle ? surplus : idle;
    }
}
