# Plumb

A capped vault on Mezo that pays stablecoin holders the main MUSD pool's MEZO rewards to keep a standing bid under MUSD.

Almost all of MUSD's buyers on Mezo sit in one tick of the main MUSD/mUSDC pool. Plumb puts deposits on that tick and below it, through Mezo's own pool, gauge and sMUSD, with no owner and no admin keys.

**Try it in 30 seconds:** open [kinnuworks.github.io/plumb](https://kinnuworks.github.io/plumb/). The first screen reads Mezo mainnet in your browser and shows what selling 10k to 500k MUSD pays at the current block. No wallet needed. The [vault page](https://kinnuworks.github.io/plumb/vault/) shows the live testnet vault's band, bid and value.

**Who it's for:** anyone on Mezo holding mUSDC who wants it to earn. The pool's gauge already pays about 87,350 MEZO a day for liquidity at the price; today a handful of positions collect it.

**What it earns, and costs:** in a mainnet fork test, $20,000 deposited earned 3,509 MEZO in one quiet day after fees. At today's MEZO price (about 0.0030 MUSD in the MEZO/MUSD pool) that is about $10.50 a day, roughly 19% a year if emissions and price held. It falls as more liquidity joins that tick. The vault keeps 10% of MEZO as a fee, posts 10% back to the gauge's voters, and tips 1% to whoever calls `rebalance()`, which costs about $0.17 in gas. The risk is MUSD bought below $1, held until it sells at $1 or more.

**Safety:** no owner and no admin keys, every parameter fixed at deploy, deposits capped at 5,000 mUSDC. Not audited. A fresh review found one high, one medium and one low issue in the Wave 2 code; all are fixed, with tests ([SECURITY.md](contracts/SECURITY.md)). 77 unit and mainnet-fork tests and 10 invariant properties pass.

New in Wave 2: [what changed since Wave 1](docs/WAVE2.md).

## For judges: two minutes

| What | Where |
|---|---|
| Live app (mainnet depth, testnet vault) | [kinnuworks.github.io/plumb](https://kinnuworks.github.io/plumb/) |
| What changed since Wave 1 | [docs/WAVE2.md](docs/WAVE2.md) |
| Live vault, Mezo testnet (capped at 5,000 mUSDC, source verified) | [explorer](https://explorer.test.mezo.org/address/0x9688ef37203022054b8337e8b5dA220Eed24e481) |
| Live vault, Mezo mainnet | pending deployment |
| Security review and fixes | [contracts/SECURITY.md](contracts/SECURITY.md) |
| Every transaction behind every claim | [docs/EVIDENCE.md](docs/EVIDENCE.md) |
| Returns and risks | [docs/ECONOMICS.md](docs/ECONOMICS.md) |

Check the Wave 2 claims yourself against Mezo mainnet state:

```bash
cd contracts && export MEZO_RPC_URL=https://mezo.drpc.org
forge test --match-test 'test_bandEarnsMezoWhileThePegHolds|test_backstopCatchesALargeSale' -vv
# MEZO in a quiet day, band + bid: 3508831598460675540000
# MEZO in a quiet day, bid only:   0
# USD for 400k MUSD before: 111686626707
# USD for 400k MUSD after:  161679450837
```

## Why

Read from Mezo mainnet on 2026-11-15 (blocks 13,239,796 to 13,239,968):

- MUSD trades at $0.994 in the main MUSD/mUSDC pool. A 100,000 MUSD sale pays $99,284.
- The pool's whole buy side is $111,709 of mUSDC. Selling 250,000 or 500,000 MUSD pays the same $111,687, because nothing else is bidding.
- 6 of the 10 positions staked in the pool's gauge sit in the one tick range at the price and hold 93% of the staked liquidity. When they step away, depth goes with them: replayed at a block on Oct 22, a 10,000 MUSD sale would have paid $11 (`data/depth_history.csv`).
- The gauge pays about 87,350 MEZO a day, but only to staked liquidity in range at the current tick.
- Only 4 troves are open, with 28,310 MUSD of debt, so redemptions can't absorb much selling either.

Borrowers need a dollar that holds $1, and holders need somewhere to sell it. Mezo's Gauges post says thin pools put pressure on the peg. Plumb adds that buy side using Mezo's own pool, gauge and savings vault, so the MEZO emissions Mezo already pays for liquidity go to liquidity that defends the price.

What this returns, with the best case taken out, is in [docs/ECONOMICS.md](docs/ECONOMICS.md).

## What it does

### PlumbBidVault

1. You deposit mUSDC and get vault shares.
2. Half of the free mUSDC goes into a band: one 10-tick slot around the live price, where the pool's other buyers sit. The vault swaps just enough mUSDC into MUSD to fill it, never paying more than the TWAP price plus one slot or more than $1.
3. The rest becomes a bid from the band's lower edge down to about $0.98. Anyone selling MUSD past the band meets it.
4. Both positions are staked in the pool's gauge. The band is in range while MUSD trades normally, so it earns MEZO every block; the bid earns when sellers push the price into it. MEZO streams to share holders after a 10% fee, a 10% incentive posted back to the same gauge's voting reward, and a 1% tip to whoever rebalances.
5. MUSD the bid buys goes into sMUSD and earns savings yield while MUSD is under $1. When MUSD trades within 0.2% of $1, the vault offers it back at $1 or more.
6. Withdrawals pay your share of each token, in kind, at any time. No bids or deposits below $0.97.

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
