# What changed since Wave 1

Wave 1's review asked for three things: a capped vault on the real mainnet pool and gauge, gauge staking and MEZO streaming shown on chain rather than only in fork tests, and depositors other than the builder. This file lists what was built in Wave 2, with the command or transaction behind each line.

## The market moved, so the vault changed

In Wave 1 the pool's buy side held $38,581 and a bid one tick under the price was where sellers landed. By November the picture was different: most of the pool's buyers sat in one tick at the price, and a bid below that tick saw no trades and earned no MEZO while the peg held. Gauge rewards only go to staked liquidity in range at the current tick.

## The band

The vault now splits free mUSDC two ways:

1. **A band on the live price.** One 10-tick slot around the current tick, staked in the gauge. The vault swaps just enough mUSDC into MUSD through the pool to fill it. The swap is capped at the TWAP price less the manipulation tolerance, never above $1, and never past the band's own edge. If the swap can't fill the band (a thin or empty slot), the band is skipped for that rebalance instead of reverting the deposit.
2. **The backstop bid.** USD only, from the band's cheap edge down to about $0.98. No bids or deposits below $0.97.

MUSD bought below $1 never goes into the band. It waits in sMUSD and is offered back only at $1 or more, as in Wave 1.

Fork test on Mezo mainnet state (`PlumbBand.fork.t.sol`, block 13,238,000), one quiet day with no trades and $20,000 deposited:

| Layout | MEZO earned |
|---|---|
| Wave 1 (bid only) | 0 |
| Wave 2 (band + bid) | 3,508.8 |

```bash
cd contracts && export MEZO_RPC_URL=https://mezo.drpc.org
forge test --match-test 'test_bandEarnsMezoWhileThePegHolds|test_backstopCatchesALargeSale' -vv
```

## Tests

- The Wave 1 fork tests are re-pinned to block 13,238,000. Their sales were sized for October's thin book, so they now sell until a target price instead of a fixed amount. That change is test-only, in its own commit, and no assertion was loosened.
- New suite `PlumbBand.fork.t.sol` (14 tests), plus band tests in the mirrored token order Mezo testnet uses. The first run of the mirrored test found a bug: on a thin pool the band's swap moved the price out of the band and the deposit reverted. Fixed in `2814b59`.
- The invariant suite now runs the shipped layout, band on.
- 75 unit and fork tests, 10 invariants, `slither` with no findings on the vault beyond reviewed informational ones.

## Deployments

| Network | Vault | Notes |
|---|---|---|
| Mezo testnet | `0xb9A01f76c438De8B931360C134F2c4B08913b990` | band on; first deposit tx `0x268e4c9bd2b0893a4c92e3cf2f29b4492dbebdb570ec11a156bc1e2b42e36bfe` |
| Mezo mainnet | pending | capped at 5,000 mUSDC on pool `0xCC372B7E…aC1a` and gauge `0x6d446E27…Fc57` |

## App

The first screen now reads Mezo mainnet live in your browser, with no wallet: what selling 10k, 100k, 250k or 500k MUSD into the main pool pays at the current block. A Playwright test walks that page and the vault page against the live chains and records a video.

## Keeper

Re-centres the band when the price leaves it, since a band out of range earns nothing.
