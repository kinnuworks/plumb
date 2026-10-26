# Plumb: submission pack

## AKINDO form answers

**Project name:** Plumb

**Category:** Peg liquidity and yield

**TL;DR:** Plumb is a peg module for MUSD built from Mezo's own pool, gauge and sMUSD vault: stablecoins become standing bids just under MUSD's price, what they buy earns in sMUSD, and it is sold back only at $1 or more.

**How it works:**
MUSD trades at $0.99 and Mezo's main MUSD/mUSDC pool has about 5.3 million MUSD for sale against $38,581 of buyers. Until mid October a 100,000 MUSD sale on that pool typically paid about $99,000. Replayed at a block on October 22, selling 10,000 MUSD would have paid $11, because the bids had been withdrawn. Every figure is recomputable at any block with our quoter.

Plumb puts buyers back. Depositors supply mUSDC, which the vault places as a concentrated bid from one tick under the market to about 2% deeper, staked in the pool's gauge for MEZO. MUSD the bid buys earns in sMUSD while MUSD is under $1, and is offered back only at $1 or more once the price recovers. On a fork of today's mainnet, a $25,000 deposit lifts what a 100,000 MUSD sale pays from $38,556 to $63,556.

The same mechanics power a strategy for sMUSD. Its 7.38M MUSD currently sits in an IdleStrategy earning nothing. PlumbAskStrategy keeps 95% idle and offers the rest only at $1.001 and up, so savers never sell below par. On the fork, sMUSD's real owner switches to it with one call. A full cycle sold 27,158 MUSD above $1.001 and returned 164 MUSD of profit to savers.

MUSD is the asset being supported, the inventory and the savings yield. MEZO is the reward stream, and a share of it goes back to the gauge as an incentive so veBTC voters send more emissions to the pool that defends the peg.

**Target group:** Stablecoin holders on Mezo and Base who want yield for providing the liquidity MUSD lacks; Mezo's savings vault and treasury; and anyone watching MUSD's peg (the observatory is public and needs no wallet). Desktop and mobile web.

**Tech stack:** Solidity 0.8.28 and Foundry (fork tests against Mezo mainnet, fuzz and invariant suites, Slither), Uniswap v3 math libraries, Next.js 15, viem and wagmi, a TypeScript keeper.

**Track:** DeFi (the vault and sMUSD strategy) and access (the peg observatory).

**Chain deployed on:** Mezo testnet. PlumbBidVault `0xf7db34df67373d06629dd154096d260A30e2637A`, MUSD/mUSDC CL pool `0xf6212414351f29AB816371f6b4ceE51960916c2a` (created with mainnet's fee tier and spacing). Mainnet integration proven against Mezo's real contracts on a fork pinned at block 12,772,660.

**Project status:** Entirely new, built during Wave 1.

**Project readiness:** Testnet deployment.

**Future milestones:**
1. By Nov 15 (Wave 2): mainnet vault with a deposit cap, live depth meter on the observatory, and the vault on Aero's MUSD/USDC pool on Base.
2. December 2026: external review, then raise the cap.
3. Q1 2027: governance proposal to move sMUSD's idle MUSD into PlumbAskStrategy under published caps.

**Team:** Solo builder. [name, role, X or LinkedIn]

## Deck (10 slides)

1. **Plumb.** A peg module for MUSD, built from Mezo's own pool, gauge and savings vault.
2. **The book today.** About 5.3M MUSD offered between $0.99 and $1.00. $38,581 bid. Price $0.990. Chart of the pool's liquidity by tick.
3. **What happened in October.** Line chart: USD paid for a 100,000 MUSD sale, Aug 28 to Oct 26. Flat at $99k, then the drop. Callout: replayed at a block on Oct 22, a 10,000 MUSD sale would have paid $11.
4. **Why it matters.** The borrowing book is one trove, 14,489 MUSD against 16.59 BTC (June: $13.1M of loans). 96.7% of MUSD supply sits in protocol contracts. Borrowers need a dollar that holds $1.
5. **The vault.** Deposit mUSDC, a bid under the market, staked in the gauge, MEZO to depositors. Diagram of bid, park in sMUSD, ask at $1.
6. **Proof on a mainnet fork.** $25k deposit: a 100k MUSD sale pays $63,556 instead of $38,556. One day in range: about 40,600 MEZO.
7. **sMUSD strategy.** 7.38M MUSD idle today. One `setStrategy` call. 95% stays idle, orders only at $1.001+. Full cycle: 27,158 MUSD sold above par, 164 MUSD profit to savers, everything returned on switch back.
8. **Safety.** No owner, immutable parameters, TWAP checks against manipulation, in-kind exits, floor and inventory caps, no signatures. Invariant suite found and closed a real share-pricing bug.
9. **Mezo integration.** Pool, NFT manager, gauge, gauge voting reward, PoolsVoter, sMUSD and its strategy hook, CL router, MUSD, MEZO.
10. **Next.** Mainnet with a cap, Aero on Base, sMUSD governance proposal.

## Pitch video script (2:00)

**0:00 to 0:15. The hook.** (Screen: observatory, sell table)
"Mezo already pays MEZO emissions for MUSD liquidity. Plumb points that liquidity at the one thing it's missing: buyers. Today Mezo's main pool has 5.3 million MUSD for sale and thirty-eight thousand dollars of bids, so a hundred-thousand-MUSD sale gets thirty-eight thousand dollars."

**0:15 to 0:35. October.** (Screen: depth history chart)
"It wasn't always like this. For most of the last two months, that same sale paid about ninety-nine thousand. Then the bids were withdrawn. Replay the pool at a block on October 22 and selling ten thousand MUSD would have paid eleven dollars. Every point on this chart comes from replaying the pool at that block."

**0:35 to 1:05. Plumb.** (Screen: vault page, deposit on testnet)
"Plumb is a buyer. You deposit stablecoins. The vault bids for MUSD just under the market, staked in the pool's gauge, so depositors earn MEZO. MUSD it buys earns in sMUSD, and it's only sold back at a dollar or more. No owner, no admin keys, and withdrawals are paid in kind any time."

**1:05 to 1:25. Proof.** (Screen: terminal, fork test output)
"On a fork of today's mainnet, a twenty-five thousand dollar deposit takes that hundred-thousand-MUSD sale from thirty-eight thousand to sixty-three thousand. A day in range earns about forty thousand MEZO."

**1:25 to 1:45. sMUSD.** (Screen: strategy test output)
"Mezo's savings vault holds 7.4 million MUSD that earns nothing. Our strategy plugs into the same hook. It keeps 95 percent idle and only ever sells above a dollar. On the fork, the real owner switches to it in one call, and a full cycle pays savers a profit."

**1:45 to 2:00. Close.** (Screen: roadmap slide)
"Next: mainnet with a cap, the same vault on Aero, and a proposal to put sMUSD's idle MUSD to work. Plumb. The buyers MUSD is missing."

## Recording checklist

- Observatory at http://localhost:3100 with live data
- Testnet vault: one deposit, one rebalance, one withdrawal, each with its explorer link
- `forge test --match-test test_depositMakesSellingMusdCheaper -vv` and `--match-test test_fullCycleEarnsForSavers -vv` in a terminal
