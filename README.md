# Plumb

A peg module for MUSD, built entirely from Mezo's own parts.

Plumb turns stablecoins into standing bids for MUSD just under its price on Mezo's main MUSD/mUSDC pool, stakes them in that pool's gauge, parks the MUSD it buys in sMUSD, and sells it back only at $1 or more. A second contract plugs into sMUSD's strategy hook and turns a slice of its idle MUSD into a standing offer at par. Every rule is fixed in code and every number is checkable on chain, so the protocol, its treasury and market makers can all defend the peg through one public, capped, ownerless vault.

Live on Mezo testnet (see [Deployments](#deployments)) and tested against Mezo mainnet's real contracts on a fork.

Why it matters to Mezo: it plugs into Mezo's own CL pool, gauge and sMUSD strategy hook, with no owner and no admin. 50 tests run against Mezo mainnet state on a fork, plus 9 unit tests and 10 invariants; the invariants found a share-pricing bug, now fixed with its own test. sMUSD can adopt the strategy with one `setStrategy` call, which the fork test makes as sMUSD's real owner.

## For judges: two minutes

| What | Where |
|---|---|
| Try it: peg observatory and vault | [kinnuworks.github.io/plumb](https://kinnuworks.github.io/plumb/) |
| Pitch video (64 s) | [docs/plumb-pitch.mp4](docs/plumb-pitch.mp4) |
| Live vault (Mezo testnet, capped at 2,000 mUSDC, source verified) | [explorer](https://explorer.test.mezo.org/address/0xA27AbD357f28c41732EA6670278140284fbAcF9E) |
| Every transaction behind every claim | [docs/EVIDENCE.md](docs/EVIDENCE.md) |
| Returns and risks, best case removed | [docs/ECONOMICS.md](docs/ECONOMICS.md) |
| Deck | [docs/plumb-deck.pdf](docs/plumb-deck.pdf) |
| Threat model and review findings | [contracts/SECURITY.md](contracts/SECURITY.md) |

Check the headline claims yourself against Mezo mainnet state (the second replays Oct 22, when a 10k MUSD sale paid $11; with a $25k Plumb bid it pays $9,851):

```bash
cd contracts && export MEZO_RPC_URL=https://mezo-mainnet.boar.network
forge test --match-test 'test_depositMakesSellingMusdCheaper|test_oct22SaleWithAndWithoutPlumb' -vv
# USD for 100k MUSD before: 38555698596
# USD for 100k MUSD after:  63555698595
```

## Why

Numbers below were read from Mezo mainnet on 2026-10-26 and can be reproduced with the commands in [Reproduce the numbers](#reproduce-the-numbers).

- MUSD trades at $0.990 on Mezo and about $0.989 on Aero, Uniswap and Curve.
- The MUSD/mUSDC pool on Mezo offers about 5.3 million MUSD for sale between $0.99 and $1.00. The buy side holds $38,581.
- From August 28 to October 16, selling 100,000 MUSD into that pool usually paid about $99,000. From October 18 the bid side thinned. Replaying the pool every two days, a 10,000 MUSD sale would have paid $9,882 on Oct 18, $11 on Oct 22, $2,479 on Oct 24 and $9,893 on Oct 26 (`data/depth_history.csv`).
- The MUSD borrowing contracts currently hold 14,489 MUSD of trove debt against 16.59 BTC (ActivePool), so very little MUSD is owed by borrowers who would need to buy it back.
- About 96.7% of the 29.5M MUSD supply sits in protocol contracts: the Stability Pool (14.2M), sMUSD's default IdleStrategy (7.4M), the pool's sell side (5.3M) and the bridge (1.6M).

Borrowers need a dollar that holds $1, and holders need somewhere to sell it. Mezo's Gauges post says thin pools put pressure on the peg. Plumb adds that buy side using Mezo's own pool, gauge and savings vault, so the MEZO emissions Mezo already pays for liquidity go to liquidity that defends the price.

What this returns, with the best case taken out, is in [docs/ECONOMICS.md](docs/ECONOMICS.md).

## What it does

### PlumbBidVault

1. You deposit mUSDC and get vault shares.
2. The vault places the mUSDC as a concentrated bid that starts one tick below the market and runs about 2% deeper. Anyone selling MUSD meets it.
3. The position is staked in the pool's gauge. MEZO emissions stream to share holders, after a 10% fee, a 10% incentive posted back to the same gauge's voting reward, and a 1% tip to whoever rebalances.
4. MUSD the bid buys goes into sMUSD and earns savings yield while MUSD is under $1.
5. When MUSD trades within 0.2% of $1, the vault takes that MUSD out and offers it at $1 or more. Depositors earn the discount on the round trip.
6. Withdrawals pay your share of each token, in kind, at any time.

### PlumbAskStrategy (for sMUSD)

sMUSD's owner can switch its strategy with one call. Today its 7.38M MUSD sits in the default `IdleStrategy`, which holds it as plain MUSD. `PlumbAskStrategy` offers a capped slice (5% by default, 10% at most, counting both MUSD on offer and USD from earlier fills) only at $1.001 and up, and keeps the rest idle so withdrawals stay instant. If MUSD trades above $1, the order fills. When MUSD later dips, the strategy buys back more MUSD than it sold, and only then is the surplus paid to sMUSD holders. Every buyback, including on withdrawal or migration, is refused unless it returns at least as much MUSD as the fill sold, so savers never sell below par or buy back at a loss. Its job is to cap MUSD's overshoot above $1, not to earn much.

### Peg observatory

A public page that reads the pool, sMUSD, the Stability Pool and the borrowing book directly, and prices "sell N MUSD now" with a quoter that runs as an `eth_call` without being deployed. The same quoter recomputes the order book at any past block, which is how the October history above was produced.

### Keeper

A permissionless bot that watches the vault and calls `rebalance()` when the market moves into the bid, the bid drifts from the market, or inventory needs to switch between sMUSD and the ask. It simulates every transaction before sending.

## Mezo integration

| Contract | Address (mainnet) | How Plumb uses it |
|---|---|---|
| MUSD/mUSDC CL pool | `0xCC372B7E15535aB225fe17c1075831D38ef7aC1a` | Where bids and asks live. `observe` for the TWAP, `slot0` for the spot check |
| NonfungiblePositionManager | `0x509Bc221df2B83927c695FA0bb0f5B21053C874c` | Mints, resizes and burns positions |
| CLGauge for that pool | `0x6d446E27505c71EE39D632488cE849fEF6aFFc57` | Stakes positions, collects MEZO |
| Gauge voting reward | `0x1C183740D971c75ef8A7cEe2294Eb9ddC435637d` | Receives the MEZO incentive share, to pull veBTC votes toward the peg pool |
| PoolsVoter | `0x48233cCC97B87Ba93bCA212cbEe48e3210211f03` | Looks up the gauge and its voting reward |
| sMUSD (MUSDSavingsRate) | `0xb4D498029af77680cD1eF828b967f010d06C51CC` | Parks bought MUSD. Host of `PlumbAskStrategy` through `setStrategy` |
| CLSwapRouter | `0x37cDd11919ec3860eaD9efB8673d7476E5326225` | Strategy buybacks |
| MUSD, mUSDC, MEZO | `0xdD46…F186`, `0x0467…c197`, `0x7B7c…0001` | Assets |
| ActivePool, Stability Pool, IdleStrategy, NTT manager | see `app/src/lib/addresses.ts` | Read by the observatory |

## Repository

```
contracts/   Solidity (Foundry): PlumbBidVault, PlumbAskStrategy, PegBook, PlumbQuoter
app/         Next.js observatory and vault UI
keeper/      TypeScript keeper (viem)
data/        Depth history recomputed from chain
```

## Tests

All fork tests run against Mezo mainnet state pinned at block 12,772,660. Nothing in the pool, gauge, sMUSD or router is mocked. The one exception: Mezo's MEZO token is a chain precompile that Foundry cannot execute, so the fork places a standard ERC-20 at its address and funds the gauge.

| Suite | Tests | Highlights |
|---|---|---|
| `PlumbBidVault.fork.t.sol` | 23 | A $25k deposit lifts what a 100k MUSD sale pays from $38,556 to $63,556. A flash-loaned deposit, claim and redeem collects 0 MEZO. A deposit-then-redeem round trip while the price moves loses $0.36 on $100,000. Manipulated prices, caps, floor and cooldown are enforced. Two equal depositors get equal value whoever leaves first, an sMUSD outage pays sMUSD in kind instead of blocking exits, and a broken gauge cannot freeze transfers. |
| `Oct22Replay.fork.t.sol` | 1 | Forks the thinnest block in the history (Oct 22). A 10k MUSD sale paid $11.39; with a $25k Plumb bid in the book it pays $9,851. |
| `PlumbAskStrategy.fork.t.sol` | 18 | sMUSD's real owner switches all 7,382,555 MUSD into the strategy. A full cycle sells 27,158 MUSD at $1.001 or more and returns 164 MUSD to savers. A sandwiched buyback is refused without spending a cent, 90% of savers can leave at once with the order filled. A long premium cannot drain idle MUSD, no yield is paid on unrealised fills, and migration waits rather than strand USD. Savers are untouched by a pool outage, the rounding reserve is never paid as yield, buybacks refuse when spot and TWAP disagree, and governance has an opt-in emergency handoff. |
| `MirroredLayout.fork.t.sol` | 4 | Builds the testnet layout (USD as token1) with Mezo's real CL factory and runs the vault's whole life on it. |
| `PlumbQuoter.fork.t.sol` | 4 | Quotes match a real swap exactly and leave the pool untouched. |
| `PegMath.t.sol` | 9 | Fuzzed tick math for both token orders. |
| `PlumbBidVault.invariant.t.sol` | 6 invariants | Random deposits, redemptions, dumps, pumps, time jumps and rebalances. One invariant caught a real bug: after a dump drains the pool its price collapses, and new shares could have been sold cheaply. Deposits now pause below the floor. |
| `PlumbAskStrategy.invariant.t.sol` | 4 invariants | Savers come and go through the real sMUSD vault while the market moves: orders never below $1.001, order within its cap, principal backed, no failed withdrawals. |

```bash
cd contracts
export MEZO_RPC_URL=https://mezo-mainnet.boar.network
forge test
```

Security notes, the threat model and the Slither triage are in [contracts/SECURITY.md](contracts/SECURITY.md).

## Deployments

| Network | Contract | Address |
|---|---|---|
| Mezo testnet | PlumbBidVault | [`0xA27AbD357f28c41732EA6670278140284fbAcF9E`](https://explorer.test.mezo.org/address/0xA27AbD357f28c41732EA6670278140284fbAcF9E) |
| Mezo testnet | MUSD/mUSDC CL pool (created by Plumb with mainnet's fee tier and spacing) | [`0xf6212414351f29AB816371f6b4ceE51960916c2a`](https://explorer.test.mezo.org/address/0xf6212414351f29AB816371f6b4ceE51960916c2a) |

An earlier vault, deployed before the second review's fixes, is at [`0xf7db…637A`](https://explorer.test.mezo.org/address/0xf7db34df67373d06629dd154096d260A30e2637A); its transactions are kept in the evidence file.

The MUSD used on testnet was borrowed the normal way, by opening a trove with 0.04 testnet BTC ([tx](https://explorer.test.mezo.org/tx/0x89a57035709db0123879dd9be1da19719f17f8e6774d1b51cebfd614adb2ab65)), and part of it was swapped to mUSDC in Mezo's stable pool ([tx](https://explorer.test.mezo.org/tx/0x435c9f671fd5bd31cef4e3b487a31e7e8af32416bd8f5d25263bc5bf15321505)). Demo transactions are listed in [docs/EVIDENCE.md](docs/EVIDENCE.md).

Testnet has no MUSD/mUSDC concentrated pool, so the deploy script creates one at the mainnet price ($0.99) and seeds it with a MUSD sell wall shaped like mainnet's. Mezo's testnet gauge voter has not whitelisted mUSDC, so the testnet vault runs without a gauge. The gauge path is covered by the mainnet fork tests.

## Run it

```bash
# contracts
cd contracts && forge build && forge test

# testnet deploy (needs testnet BTC for gas, and testnet MUSD for the sell wall)
cp .env.example .env   # set PRIVATE_KEY
forge script script/DeployTestnet.s.sol --rpc-url https://rpc.test.mezo.org --broadcast

# app
cd app && pnpm install && pnpm dev

# keeper
cd keeper && pnpm install
RPC_URL=https://rpc.test.mezo.org CHAIN_ID=31611 VAULT=0x... PRIVATE_KEY=0x... pnpm start
```

## Reproduce the numbers

The quoter runs the real swap and reverts, so it can be called at any block without being deployed:

```bash
cd contracts
CODE=$(forge inspect PlumbQuoter deployedBytecode)
Q=0x000000000000000000000000000000000000bEEF
# USD paid for selling 100,000 MUSD at block 12,000,000 (Sep 21) and now
for B in 12000000 latest; do
  cast call $Q "quoteExactIn(address,bool,uint256)(uint256,int24)" \
    0xCC372B7E15535aB225fe17c1075831D38ef7aC1a false 100000000000000000000000 \
    --override-code $Q:$CODE --block $B --rpc-url https://mezo-mainnet.boar.network
done
```

## Roadmap

1. Mainnet launch of the vault with a deposit cap, after an external review.
2. The same vault on Aero's MUSD/USDC pool on Base, where Mezo's gauges already send MEZO.
3. A governance proposal, with the fork test as evidence, to move sMUSD's idle MUSD into `PlumbAskStrategy` under published caps.

## Credits

`TickMath` and `FullMath` come from Uniswap v3 core and `LiquidityAmounts` from Uniswap v3 periphery (GPL-2.0-or-later, 0.8 branches). The pool, gauge and NFT manager interfaces follow Mezo's verified Slipstream contracts. OpenZeppelin Contracts 5.1 (MIT).
