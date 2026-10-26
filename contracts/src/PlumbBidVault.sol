// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {ICLPool, INonfungiblePositionManager, ICLGauge, IVotingReward} from "./interfaces/IMezoCL.sol";
import {IMUSDSavingsRate} from "./interfaces/IMUSDSavingsRate.sol";
import {PegMath} from "./libraries/PegMath.sol";
import {PegBook} from "./PegBook.sol";

/// @title PlumbBidVault
/// @notice Pooled buy-side liquidity for MUSD on Mezo's MUSD/USD concentrated-liquidity pool.
///
/// Depositors supply a USD stablecoin. The vault places it as a bid just below MUSD's price,
/// so anyone selling MUSD meets a deeper book. MUSD the vault buys is parked in the sMUSD
/// savings vault for yield while MUSD trades below $1, and offered back only at $1 or above
/// once the price recovers. Positions are staked in the pool's gauge, and the MEZO they earn
/// is streamed to share holders.
///
/// Safety model:
/// - No owner and no admin functions. Every parameter is immutable.
/// - Rebalancing is permissionless and only acts when the spot price agrees with the pool's
///   TWAP, so one block of price manipulation cannot move the vault's liquidity.
/// - Redemptions are paid pro rata in kind (USD and MUSD), so exits need no price at all and
///   cannot be gamed by moving the price first.
/// - Bids stop below a floor price and while MUSD inventory exceeds a cap. Deposits stop
///   below the floor too, so a drained pool can never be used to buy shares cheaply.
/// - No signatures, no meta-transactions, no privileged callers.
contract PlumbBidVault is PegBook, ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Params {
        ICLPool pool;
        INonfungiblePositionManager nfpm;
        ICLGauge gauge; // address(0) when the pool has no gauge
        IMUSDSavingsRate smusd; // address(0) keeps bought MUSD idle
        address usd;
        address musd;
        address treasury;
        address incentiveSink; // gauge bribe contract; address(0) disables the flywheel
        uint32 twapWindow; // seconds
        int24 maxTwapDeviation; // ticks allowed between spot and TWAP
        int24 bidWidth; // depeg ticks covered by the bid
        int24 askWidth; // depeg ticks covered by the ask
        int24 floorDepeg; // no bids deeper than this (300 is about $0.97)
        int24 nearParDepeg; // within this many ticks of $1, inventory is offered back
        uint16 maxInventoryBps; // stop bidding when MUSD is this share of assets
        uint16 feeBps; // share of MEZO to the treasury
        uint16 incentiveBps; // share of MEZO posted as gauge incentives
        uint16 keeperBps; // share of MEZO to whoever rebalances
        uint32 minRebalanceInterval; // seconds
        uint256 depositCap; // most USD value the vault accepts; 0 for no cap
    }

    struct Position {
        uint256 tokenId;
        bool staked;
    }

    uint256 private constant BPS = 10_000;
    uint256 private constant ACC_PRECISION = 1e18;
    uint8 private constant SHARE_DECIMALS_OFFSET = 12;

    ICLGauge public immutable gauge;
    IMUSDSavingsRate public immutable smusd;
    IERC20 public immutable mezo;
    address public immutable treasury;
    address public immutable incentiveSink;
    int24 public immutable bidWidth;
    int24 public immutable askWidth;
    int24 public immutable floorDepeg;
    int24 public immutable nearParDepeg;
    uint16 public immutable maxInventoryBps;
    uint16 public immutable feeBps;
    uint16 public immutable incentiveBps;
    uint16 public immutable keeperBps;
    uint32 public immutable minRebalanceInterval;
    uint256 public immutable depositCap;
    uint8 private immutable shareDecimals;

    Position public bid;
    Position public ask;
    uint256 public lastRebalance;

    /// MEZO streamed to share holders through a per-share accumulator.
    uint256 public accMezoPerShare;
    /// MEZO credited to holders and not yet paid out.
    uint256 public mezoLiabilities;
    mapping(address => uint256) public mezoDebt;
    mapping(address => uint256) public mezoOwed;

    event Deposit(address indexed caller, address indexed receiver, uint256 usdIn, uint256 shares);
    event Redeem(address indexed owner, address indexed receiver, uint256 shares, uint256 usdOut, uint256 musdOut);
    event Rebalanced(
        address indexed keeper,
        int24 twapTick,
        int24 depeg,
        uint256 bidTokenId,
        uint256 askTokenId,
        uint256 usdInBid,
        uint256 musdInAsk,
        uint256 musdParked
    );
    event BidsPaused(int24 depeg, uint256 inventoryBps);
    event Harvested(uint256 total, uint256 toHolders, uint256 toTreasury, uint256 toIncentives, uint256 toKeeper);
    event MezoClaimed(address indexed account, address indexed receiver, uint256 amount);

    error ZeroAmount();
    error DepositsPaused(int24 depeg);
    error CapExceeded(uint256 cap);
    error RebalanceTooSoon(uint256 nextAllowed);
    error Slippage();
    error BadParams();

    constructor(Params memory p, string memory name_, string memory symbol_)
        PegBook(p.pool, p.nfpm, p.usd, p.musd, p.twapWindow, p.maxTwapDeviation)
        ERC20(name_, symbol_)
    {
        if (
            p.treasury == address(0) || p.bidWidth <= 0 || p.askWidth <= 0 || p.floorDepeg <= 0
                || p.nearParDepeg < 0 || p.maxInventoryBps > BPS
                || uint256(p.feeBps) + p.incentiveBps + p.keeperBps > 3_000
        ) revert BadParams();
        if (address(p.gauge) != address(0) && p.gauge.pool() != address(p.pool)) revert BadParams();

        gauge = p.gauge;
        smusd = p.smusd;
        mezo = address(p.gauge) == address(0) ? IERC20(address(0)) : IERC20(p.gauge.rewardToken());
        treasury = p.treasury;
        incentiveSink = p.incentiveSink;
        bidWidth = p.bidWidth;
        askWidth = p.askWidth;
        floorDepeg = p.floorDepeg;
        nearParDepeg = p.nearParDepeg;
        maxInventoryBps = p.maxInventoryBps;
        feeBps = p.feeBps;
        incentiveBps = p.incentiveBps;
        keeperBps = p.keeperBps;
        minRebalanceInterval = p.minRebalanceInterval;
        depositCap = p.depositCap;
        shareDecimals = IERC20Metadata(p.usd).decimals() + SHARE_DECIMALS_OFFSET;
    }

    // ------------------------------------------------------------------
    // Depositors
    // ------------------------------------------------------------------

    /// @notice Deposit USD for shares. The USD joins the book on the next rebalance.
    function deposit(uint256 usdAmount, uint256 minShares, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        shares = _deposit(usdAmount, minShares, receiver);
    }

    /// @notice Deposit and rebalance in one transaction so the USD is live in the book at once.
    ///         The rebalance is skipped, not reverted, while the cooldown is running.
    function depositAndDeploy(uint256 usdAmount, uint256 minShares, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        shares = _deposit(usdAmount, minShares, receiver);
        if (block.timestamp >= lastRebalance + minRebalanceInterval) _rebalance(msg.sender);
    }

    /// @notice Burn shares for a pro-rata slice of every asset, paid in kind, plus owed MEZO.
    function redeem(uint256 shares, uint256 minUsd, uint256 minMusd, address receiver)
        external
        nonReentrant
        returns (uint256 usdOut, uint256 musdOut)
    {
        if (shares == 0) revert ZeroAmount();
        _harvest(address(0));
        (usdOut, musdOut) = _withdrawShare(shares, totalSupply());
        _burn(msg.sender, shares);
        if (usdOut < minUsd || musdOut < minMusd) revert Slippage();

        if (usdOut > 0) usd.safeTransfer(receiver, usdOut);
        if (musdOut > 0) musd.safeTransfer(receiver, musdOut);
        _payMezo(msg.sender, receiver);
        emit Redeem(msg.sender, receiver, shares, usdOut, musdOut);
    }

    /// @notice Claim streamed MEZO.
    function claimMezo(address receiver) external nonReentrant returns (uint256) {
        _harvest(address(0));
        _accrue(msg.sender);
        return _payMezo(msg.sender, receiver);
    }

    // ------------------------------------------------------------------
    // Keeper
    // ------------------------------------------------------------------

    /// @notice Re-centre the book on the current price. Anyone may call; the caller earns a
    ///         small share of harvested MEZO.
    function rebalance() external nonReentrant {
        uint256 next = lastRebalance + minRebalanceInterval;
        if (block.timestamp < next) revert RebalanceTooSoon(next);
        _rebalance(msg.sender);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Vault value in USD raw units at the pool TWAP, with MUSD capped at $1.
    function totalAssets() public view returns (uint256) {
        (uint160 sqrtTwap,) = _twap();
        return _totalAssetsAt(sqrtTwap);
    }

    /// @notice Everything the vault holds, split by where it sits.
    function holdings()
        external
        view
        returns (
            uint256 idleUsd,
            uint256 idleMusd,
            uint256 parkedMusd,
            uint256 bidUsd,
            uint256 bidMusd,
            uint256 askUsd,
            uint256 askMusd
        )
    {
        (uint160 sqrtTwap,) = _twap();
        idleUsd = usd.balanceOf(address(this));
        idleMusd = musd.balanceOf(address(this));
        parkedMusd = _parkedBalance();
        (bidUsd, bidMusd) = _positionAmounts(bid.tokenId, sqrtTwap);
        (askUsd, askMusd) = _positionAmounts(ask.tokenId, sqrtTwap);
    }

    /// @notice MUSD's TWAP price in depeg ticks (positive = below $1, 1 tick is about 1 bp).
    function currentDepeg() external view returns (int24) {
        (, int24 twapTick) = _twap();
        return _depeg(twapTick);
    }

    function previewDeposit(uint256 usdAmount) external view returns (uint256) {
        return _convertToShares(usdAmount, totalAssets());
    }

    /// @notice MEZO claimable by `account`, not counting rewards still in the gauge.
    function pendingMezo(address account) external view returns (uint256) {
        return mezoOwed[account] + (balanceOf(account) * (accMezoPerShare - mezoDebt[account])) / ACC_PRECISION;
    }

    function decimals() public view override returns (uint8) {
        return shareDecimals;
    }

    // ------------------------------------------------------------------
    // Internal: deposits and redemptions
    // ------------------------------------------------------------------

    function _deposit(uint256 usdAmount, uint256 minShares, address receiver) internal returns (uint256 shares) {
        if (usdAmount == 0) revert ZeroAmount();
        (uint160 sqrtTwap, int24 twapTick, int24 spotTick) = _checkedPrice();
        // Below the floor the pool may have run out of bids, so its price says little about
        // what the vault's MUSD is worth. Pricing new shares there could hand a depositor a
        // cheap claim on existing holders' MUSD, so deposits wait until the market recovers.
        int24 depeg = _depeg(twapTick);
        if (depeg >= floorDepeg) revert DepositsPaused(depeg);

        // Credit MEZO already earned to the current holders before the new shares exist,
        // otherwise a deposit-claim-redeem in one transaction could take their rewards.
        _harvest(address(0));

        // Price new shares at whichever of the TWAP and the live price values the vault more.
        // Exits are paid in kind at the live mix of tokens, so a depositor can never buy in
        // cheaper than they could walk out, even while the TWAP lags a moving market.
        uint256 assets = Math.max(
            _totalAssetsAt(sqrtTwap), _totalAssetsAt(TickMath.getSqrtRatioAtTick(spotTick))
        );
        if (depositCap != 0 && assets + usdAmount > depositCap) revert CapExceeded(depositCap);
        shares = _convertToShares(usdAmount, assets);
        if (shares == 0 || shares < minShares) revert Slippage();

        usd.safeTransferFrom(msg.sender, address(this), usdAmount);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, usdAmount, shares);
    }

    /// @dev Virtual shares and assets (the OpenZeppelin ERC-4626 defence) make a first-depositor
    ///      inflation attack unprofitable.
    function _convertToShares(uint256 usdAmount, uint256 assets) internal view returns (uint256) {
        return Math.mulDiv(usdAmount, totalSupply() + 10 ** SHARE_DECIMALS_OFFSET, assets + 1);
    }

    /// @dev Frees shares/supply of every holding. Idle balances are read before positions are
    ///      unwound so each slice is counted once.
    function _withdrawShare(uint256 shares, uint256 supply) internal returns (uint256 usdOut, uint256 musdOut) {
        usdOut = Math.mulDiv(usd.balanceOf(address(this)), shares, supply);
        musdOut = Math.mulDiv(musd.balanceOf(address(this)), shares, supply);

        uint256 parkedShare = Math.mulDiv(_parkedBalance(), shares, supply);
        if (parkedShare > 0) {
            smusd.withdraw(parkedShare);
            musdOut += parkedShare;
        }

        (uint256 u, uint256 m) = _removeFraction(bid, shares, supply);
        usdOut += u;
        musdOut += m;
        (u, m) = _removeFraction(ask, shares, supply);
        usdOut += u;
        musdOut += m;
    }

    function _removeFraction(Position storage pos, uint256 shares, uint256 supply)
        internal
        returns (uint256 usdOut, uint256 musdOut)
    {
        uint256 tokenId = pos.tokenId;
        if (tokenId == 0) return (0, 0);
        bool wasStaked = pos.staked;
        _unstake(pos);

        uint128 slice = uint128(Math.mulDiv(_liquidityOf(tokenId), shares, supply));
        bool burned;
        (usdOut, musdOut, burned) = _withdrawLiquidity(tokenId, slice, true);
        if (burned) delete pos.tokenId;
        else if (wasStaked) pos.staked = _stake(tokenId);
    }

    // ------------------------------------------------------------------
    // Internal: rebalance
    // ------------------------------------------------------------------

    function _rebalance(address keeper) internal {
        (, int24 twapTick, int24 spotTick) = _checkedPrice();
        lastRebalance = block.timestamp;

        _harvest(keeper);
        _close(bid);
        _close(ask);
        if (_parkedBalance() > 0) smusd.claimYield();

        int24 depeg = _depeg(twapTick);
        int24 spotDepeg = _depeg(spotTick);

        // Inventory: below par, park MUSD in sMUSD. Near or above par, offer it back at >= $1.
        uint256 musdInAsk;
        uint256 parked;
        if (depeg > nearParDepeg) {
            parked = _park();
        } else {
            _unpark();
            int24 dearest = depeg < spotDepeg ? depeg : spotDepeg;
            int24 hi = _askEnd(dearest, 0);
            (ask.tokenId, musdInAsk) = _placeAsk(hi - askWidth, hi, musd.balanceOf(address(this)));
            if (ask.tokenId != 0) ask.staked = _stake(ask.tokenId);
        }

        // Bids, unless MUSD is below the floor or the vault already holds too much MUSD.
        uint256 usdInBid;
        uint256 invBps = _inventoryBps(twapTick);
        if (depeg >= floorDepeg || invBps > maxInventoryBps) {
            emit BidsPaused(depeg, invBps);
        } else {
            int24 cheapest = depeg > spotDepeg ? depeg : spotDepeg;
            int24 lo = _bidStart(cheapest);
            int24 hi = lo + bidWidth;
            int24 floorEdge = PegMath.floorToSpacing(floorDepeg, tickSpacing);
            if (hi > floorEdge) hi = floorEdge;
            (bid.tokenId, usdInBid) = _placeBid(lo, hi, usd.balanceOf(address(this)));
            if (bid.tokenId != 0) bid.staked = _stake(bid.tokenId);
        }

        emit Rebalanced(keeper, twapTick, depeg, bid.tokenId, ask.tokenId, usdInBid, musdInAsk, parked);
    }

    function _close(Position storage pos) internal {
        uint256 tokenId = pos.tokenId;
        if (tokenId == 0) return;
        _unstake(pos);
        delete pos.tokenId;
        _withdrawLiquidity(tokenId, _liquidityOf(tokenId), true);
    }

    function _stake(uint256 tokenId) internal returns (bool) {
        if (address(gauge) == address(0)) return false;
        nfpm.approve(address(gauge), tokenId);
        try gauge.deposit(tokenId) {
            return true;
        } catch {
            // Gauge killed: keep the position unstaked so it still earns swap fees.
            nfpm.approve(address(0), tokenId);
            return false;
        }
    }

    function _unstake(Position storage pos) internal {
        if (pos.staked) {
            pos.staked = false;
            gauge.withdraw(pos.tokenId);
        }
    }

    function _park() internal returns (uint256 amount) {
        if (address(smusd) == address(0)) return 0;
        amount = musd.balanceOf(address(this));
        if (amount == 0) return 0;
        musd.forceApprove(address(smusd), amount);
        smusd.deposit(amount);
    }

    function _unpark() internal {
        uint256 parked = _parkedBalance();
        if (parked > 0) smusd.withdraw(parked);
    }

    function _parkedBalance() internal view returns (uint256) {
        return address(smusd) == address(0) ? 0 : smusd.balanceOf(address(this));
    }

    // ------------------------------------------------------------------
    // Internal: valuation
    // ------------------------------------------------------------------

    function _totalAssetsAt(uint160 sqrtTwap) internal view returns (uint256) {
        (uint256 bu, uint256 bm) = _positionAmounts(bid.tokenId, sqrtTwap);
        (uint256 au, uint256 am) = _positionAmounts(ask.tokenId, sqrtTwap);
        uint256 usdTotal = usd.balanceOf(address(this)) + bu + au;
        uint256 musdTotal = musd.balanceOf(address(this)) + _parkedBalance() + bm + am;
        return usdTotal + _musdValue(musdTotal, sqrtTwap);
    }

    /// @dev Share of assets held as MUSD. Called after positions are closed, so idle and
    ///      parked balances are the whole inventory.
    function _inventoryBps(int24 twapTick) internal view returns (uint256) {
        uint160 sqrtTwap = TickMath.getSqrtRatioAtTick(twapTick);
        uint256 assets = _totalAssetsAt(sqrtTwap);
        if (assets == 0) return 0;
        uint256 held = musd.balanceOf(address(this)) + _parkedBalance();
        return Math.mulDiv(_musdValue(held, sqrtTwap), BPS, assets);
    }

    // ------------------------------------------------------------------
    // Internal: MEZO
    // ------------------------------------------------------------------

    /// @dev Pulls gauge rewards and splits every unaccounted MEZO, including rewards the gauge
    ///      pays out automatically when a position is unstaked.
    function _harvest(address keeper) internal {
        if (address(gauge) == address(0)) return;
        if (bid.staked) gauge.getReward(bid.tokenId);
        if (ask.staked) gauge.getReward(ask.tokenId);
        uint256 gross = mezo.balanceOf(address(this)) - mezoLiabilities;
        if (gross == 0) return;

        uint256 toTreasury = (gross * feeBps) / BPS;
        uint256 toKeeper = keeper == address(0) ? 0 : (gross * keeperBps) / BPS;
        uint256 toIncentives = incentiveSink == address(0) ? 0 : (gross * incentiveBps) / BPS;

        if (toIncentives > 0) {
            mezo.forceApprove(incentiveSink, toIncentives);
            try IVotingReward(incentiveSink).notifyRewardAmount(address(mezo), toIncentives) {}
            catch {
                toIncentives = 0;
            }
            mezo.forceApprove(incentiveSink, 0);
        }
        if (toTreasury > 0) mezo.safeTransfer(treasury, toTreasury);
        if (toKeeper > 0) mezo.safeTransfer(keeper, toKeeper);

        uint256 toHolders = gross - toTreasury - toKeeper - toIncentives;
        uint256 supply = totalSupply();
        if (supply > 0) {
            uint256 perShare = (toHolders * ACC_PRECISION) / supply;
            accMezoPerShare += perShare;
            mezoLiabilities += (perShare * supply) / ACC_PRECISION;
        } else if (toHolders > 0) {
            mezo.safeTransfer(treasury, toHolders);
        }
        emit Harvested(gross, toHolders, toTreasury, toIncentives, toKeeper);
    }

    function _accrue(address account) internal {
        if (account == address(0)) return;
        uint256 acc = accMezoPerShare;
        mezoOwed[account] += (balanceOf(account) * (acc - mezoDebt[account])) / ACC_PRECISION;
        mezoDebt[account] = acc;
    }

    function _payMezo(address account, address receiver) internal returns (uint256 amount) {
        amount = mezoOwed[account];
        if (amount == 0) return 0;
        mezoOwed[account] = 0;
        mezoLiabilities -= amount;
        mezo.safeTransfer(receiver, amount);
        emit MezoClaimed(account, receiver, amount);
    }

    /// @dev Keeps MEZO accounting exact across mints, burns and transfers. A plain transfer
    ///      first collects rewards earned so far, so they stay with the sender.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) _harvest(address(0));
        _accrue(from);
        _accrue(to);
        super._update(from, to, value);
    }

    /// @dev The gauge hands positions back on unstake.
    function _allowedNftOperator(address operator) internal view override returns (bool) {
        return operator == address(this) || operator == address(gauge);
    }
}
