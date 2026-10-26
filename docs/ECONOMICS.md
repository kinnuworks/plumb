# Plumb economics, without the best case

All inputs were read from Mezo mainnet at block 12,772,660 unless noted.

## Where depositor returns come from

1. **The discount.** The vault buys MUSD below $1 and only sells it at $1 or more. That gain is realised only if MUSD recovers to par.
2. **sMUSD yield** on the MUSD it holds while waiting.
3. **MEZO from the pool's gauge**, paid only while the bid is in range. In range means MUSD is actually trading inside the bid, which is exactly when the bid is doing its job.

Plumb charges 10% of MEZO as a fee and posts another 10% back to the same gauge's voting reward. The keeper gets 1%.

## MEZO: what a $25,000 bid earns, by competition

The gauge pays 0.5874 MEZO per second (50,751 MEZO a day, about $279 at $0.0055) to staked liquidity that is in range. The current epoch's rewards run until Oct 29 00:00 UTC, and the next epoch's rate depends on veBTC votes.

Today almost all liquidity sits at the current price, so it collects those rewards whenever the price is still. Plumb's bid starts one tick below the market. It earns only while sellers push the price into it, and then it shares with any other liquidity staked in the same band.

| Other staked USD in Plumb's band | MEZO a day to the $25k bid | USD a day | Annualised, while in range |
|---|---|---|---|
| $0 (today) | 50,751 | $279 | 408% |
| $25,000 | 25,376 | $140 | 204% |
| $100,000 | 10,150 | $56 | 82% |
| $500,000 | 2,417 | $13 | 19% |

The fork test's "about 40,600 MEZO a day" is the first row after Plumb's 20% cut. It applies only to days the price spends inside the bid. On a quiet day with no sellers, the bid earns no MEZO, and that's fine: a quiet day means nobody needed it.

## Downside: MUSD drifts to the floor

- The bid covers about $0.989 down to $0.969. Below $0.96 the vault stops bidding and stops taking deposits.
- Bidding also stops once MUSD is 60% of the vault.
- Worst case: the vault fills to its 60% cap at an average of about $0.979, and MUSD then sits at the $0.96 floor. The mark-to-market loss is about 1.2% of a deposit.
- Exits stay open throughout and are paid in kind. A depositor who leaves takes their MUSD with them and isn't forced to sell it at the low.

## The sMUSD strategy: small by design

PlumbAskStrategy earns only when MUSD trades above $1.001 and then falls back below $0.998. MUSD has spent the last two months near $0.99, so today the strategy mostly sits idle, exactly like the IdleStrategy it replaces.

- In the fork test's scripted cycle it made 164 MUSD on 7.38M, about 0.002%.
- The point isn't the yield. It's that 5% of sMUSD's idle MUSD becomes a standing sell order at par, which caps MUSD's upside overshoot and costs savers nothing they'd otherwise earn.
- Withdrawals are protected:
  - at least 90% of principal is always idle;
  - the order shrinks when savers leave;
  - buybacks refuse any price more than 0.5% worse than the TWAP.

## Who should seed the bid

Retail depositors are welcome, but the natural anchors are the parties who already want MUSD at $1:

| Anchor | Why it works for them |
|---|---|
| Supernormal Foundation or the PCV | The Stability Pool holds 14.2M MUSD (the MUSD docs describe it as seeded by a protocol bootstrap loan). A small slice of protocol stablecoins in a capped Plumb vault defends the peg with a public, rule-bound contract instead of discretionary market making. |
| Market makers | They get gauge rewards and a non-custodial, auditable venue. |
| Borrowers | Their MUSD debt is redeemed against when MUSD is under par. A deeper bid supports the price their loans depend on. |

`depositCap` lets a launch start small: the vault refuses deposits once its value reaches the cap.
