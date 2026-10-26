# Security notes

Plumb has not been audited. This file records the threat model, what the tests prove, and how each static-analysis finding was handled.

## Trust model

- No contract has an owner, an admin role, a pause switch or an upgrade path. Every parameter is set in the constructor and never changes.
- `rebalance()` on both contracts is open to anyone. It only re-places liquidity inside fixed bounds, and only when the pool's spot price agrees with its TWAP.
- `PlumbAskStrategy` moves funds only when the sMUSD vault calls it. Installing it takes one `setStrategy` call by the sMUSD owner, and that owner can switch away at any time and get every token back (`test_migrateBackReturnsEverything`).
- Nothing uses signatures, permits from users, meta-transactions or trusted forwarders.

## Threats and defences

| Threat | Defence | Proof |
|---|---|---|
| Push the price in one block so the vault places liquidity at a bad price | Spot must be within 30 ticks of the 30-minute TWAP or `rebalance` and `deposit` revert | `test_rebalanceRefusesManipulatedPrice`, `test_depositRefusesManipulatedPrice` |
| Inflate share price, then deposit or withdraw against it | Deposits are priced at the TWAP with MUSD capped at $1. Withdrawals are pro rata in kind and use no price at all | `test_redeemIsProRataInKind`, `test_fullExitLeavesNothingBehind` |
| First-depositor inflation (donate to the vault to round the next depositor's shares to zero) | Virtual shares and assets with a 12-decimal offset | `test_firstDepositorCannotInflateShares` |
| A dump drains every bid, the pool price collapses toward zero, and someone deposits a little USD for a large claim on the vault's MUSD | Deposits revert while MUSD is below the floor price. This was found by the invariant suite, not by review | `invariant_noDepositsBelowFloor`, `test_noBidsAndNoDepositsBelowFloor` |
| Strategy pays yield on profit it has not realised | Yield is paid only from MUSD in hand; nothing is paid while USD from a fill is still held. Found in second blind review | `test_noYieldWhileFillsAreUnrealised` |
| A buyback on the withdrawal or migration path buys MUSD back at a loss | Every buyback must return at least the MUSD the fill sold (priced at $1 + premium) and be within 0.5% of the TWAP, or it is refused. Migration reverts while USD is outstanding instead of passing it on. Found in second blind review | `test_migrateWaitsForFillsToBeBoughtBack`, `test_sandwichedBuybackIsRefusedAndWithdrawalsStillPay` |
| The first redeemer takes swap fees that belong to everyone | Fees on unstaked positions are swept into the shared balance before any deposit or redemption is priced. Found in second blind review | `test_feesAreSharedNotTakenByFirstRedeemer` |
| sMUSD pauses and every vault exit reverts | A refused sMUSD withdrawal pays the redeemer their sMUSD tokens in kind; parking and yield claims fail soft | `test_exitSurvivesSmusdOutage` |
| A broken gauge freezes share transfers or exits | Reward claims are wrapped so a failing gauge only delays MEZO | `test_transfersSurviveBrokenGauge` |
| New depositors share sMUSD yield that predates them | Pending sMUSD yield is claimed into the vault before any share is priced | covered by `_realiseIncome` |
| A sandwich inside the TWAP agreement band skims the strategy's buyback | Every buyback (rebalance, withdrawal, migration) checks spot against the TWAP and refuses unless it receives within 0.1% of the dearer of the two prices. Found in third blind review | `test_buybackRefusedWhileSpotDisagreesWithTwap` |
| A pool or NFT-manager outage freezes the whole sMUSD vault, because sMUSD calls claimYield on every deposit and withdrawal | `claimYield` reads no pool or position state; buyback prices are read through try/catch. Found in third blind review | `test_saversUnaffectedByPoolOutage` |
| The rounding reserve is paid out as yield, leaving principal unbacked | `ROUNDING_RESERVE` is excluded from surplus. Found in third blind review | `test_roundingReserveIsNeverPaidAsYield` |
| Governance cannot leave the strategy while USD from a fill is held | sMUSD's owner can opt in with `setUsdHandoff(true)`; a switch away then hands outstanding USD to the owner instead of reverting. Found in third blind review | `test_governanceCanHandOffUsdInAnEmergency` |
| Join right before rewards are split: deposit, claim and redeem in one transaction with borrowed funds | Deposits collect pending gauge rewards for existing holders before minting. Transfers do the same for the sender. Found in blind review | `test_flashDepositCannotSnipeMezo`, `test_transferKeepsEarnedMezoWithSender` |
| Deposit while the TWAP lags a recovering price, then redeem in kind at the live price | Deposits are priced at the higher of the TWAP and live valuations. Found in blind review | `test_depositRedeemRoundTripNeverProfits` |
| Sandwich the strategy's buyback, or make sMUSD withdrawals depend on it | At least 90% of principal is always idle. The order shrinks as savers leave. Buybacks refuse any price over 0.5% worse than the TWAP and never revert the caller | `test_sandwichedBuybackIsRefusedAndWithdrawalsStillPay`, `test_ninetyPercentLeaveAtOnceWithOrderFilled`, `test_orderShrinksWhenSaversLeave`, `invariant_withdrawalsDoNotFail` |
| Vault keeps buying MUSD all the way down | Bids stop below the floor ($0.96) and while MUSD is over 60% of assets | `test_noBidsAndNoDepositsBelowFloor` |
| Vault sells MUSD below $1 | Asks are placed only at or above the par tick, and par is snapped to the side of the tick grid where MUSD is worth at least $1 | `invariant_ordersRespectPar`, `test_recoveryOffersInventoryBackAtParOrBetter` |
| Strategy sells savers' MUSD below $1, or a run of fills drains idle MUSD | Orders start at $1 + premium (10 ticks, about $1.001). Exposure, meaning MUSD on offer plus USD still held from fills, is capped by configuration and never above 10% of principal | `test_sustainedPremiumKeepsExposureCapped`, `invariant_orderWithinCap` | `test_orderIsCappedAndNeverBelowOneDollar` |
| sMUSD withdrawals get stuck behind an open order | `deallocate` pays from idle MUSD first, then pulls the order, then tries a TWAP-checked buyback | `test_largeWithdrawalPullsTheOrder`, `test_depositAndWithdrawStillInstant` |
| MEZO rewards credited but not backed | `mezoLiabilities` tracks every credited unit and rounds in the vault's favour | `invariant_mezoOwedIsBacked`, `test_mezoStreamsToHolders` |
| Stray NFTs sent to the vault | `onERC721Received` accepts only positions from the NFT manager, minted by the vault or returned by the gauge | `test_nftsOnlyFromTheManager`, `invariant_noStrayPositions` |
| Gauge gets killed | Staking is wrapped in try/catch. A position the gauge refuses stays unstaked and earns swap fees instead | code path in `_stake` |

## Known limits

- If MUSD stays above the order's lowest fill price ($1.001) while almost every saver leaves sMUSD, the last slice of principal (at most the exposure cap) is held as USD and can only be paid out once MUSD trades back at or below that price. The strategy will not buy back at a loss to pay it sooner. Governance can see this coming (exposure is public and capped), and sMUSD's owner can opt in to `setUsdHandoff` to take the USD and switch strategies at once.
- The vault's own `gauge.withdraw` call is not wrapped. If the gauge ever refused to return a staked position, exits would wait on it. Mezo's CLGauge has no pause on withdraw.

- Concentrated positions return up to 1 wei less than they took when closed. The strategy is deployed with a small MUSD reserve outside principal (0.001 MUSD covers about 10^15 closes).
- The vault values MUSD at the pool's own TWAP. If the pool stays drained for longer than the TWAP window, MUSD inventory is valued near zero and deposits stay paused until the market recovers. Redemptions keep working throughout.
- `PlumbAskStrategy.claimYield` counts USD held from fills at $1 per MUSD of principal. It pays yield only from idle MUSD above principal, so savers are never paid from funds that still back principal.
- Mezo's MEZO token is a precompile that Foundry and anvil cannot execute. Fork tests replace it with a standard ERC-20 at the same address (`test/mocks/PrecompileERC20.sol`) and fund the gauge. Everything else in the fork is real mainnet bytecode and state.

## Slither 0.11.6

Command: `slither src/ --filter-paths "lib/|test/" --exclude-dependencies`

| Detector | Finding | Resolution |
|---|---|---|
| arbitrary-send-erc20 | `allocate` pulls from `vault` | False positive. `vault` is immutable and `allocate` is `onlyVault`, which is exactly the `IVaultStrategy` contract sMUSD expects |
| reentrancy-balance | `_ensureIdle` reads a balance before external calls | False positive. The balance is read again after each call. Every external entry point is `nonReentrant`, and the only callees are Mezo's NFT manager and router |
| reentrancy-no-eth, reentrancy-benign | State written after calls to the NFT manager and gauge | Fixed. Position ids and staking flags are now cleared before the external calls (checks, effects, interactions) |
| divide-before-multiply | MEZO accumulator and tick rounding | Intended. The accumulator rounds down per share so liabilities never exceed what was distributed. Tick rounding is the point of `floorToSpacing` |
| incorrect-equality | `== 0` checks on amounts and token ids | Intended. These are emptiness checks, not balance comparisons an attacker can steer |
| calls-loop, costly-loop | `quoteCurve` loops over sizes | `PlumbQuoter` is a read-only helper meant for `eth_call`. It holds no funds |
| assembly | `PlumbQuoter` decodes revert data | Intended, and covered by `test_quoteMatchesARealSale` |
| timestamp | Cooldowns and deadlines | Intended. Minutes-scale cooldowns tolerate validator timestamp drift |
| others | style (event fields, literal digits, uninitialised locals defaulting to zero, ignored return values from the NFT manager) | Reviewed, no change |
