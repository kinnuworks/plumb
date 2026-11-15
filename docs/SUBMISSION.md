# Plumb: Wave 2 submission pack

## AKINDO form answers

**Project name:** Plumb

**Category:** MUSD peg liquidity vault

**TL;DR:** A capped vault on Mezo that pays stablecoin holders the main MUSD pool's MEZO rewards to keep buyers under MUSD: a band on the live price, and a bid below it down to about $0.98.

**What changed since Wave 1:**
- The vault now earns while the peg holds. Wave 1's bid sat one tick under the market, and the gauge pays only liquidity in range, so it earned nothing on a normal day. Wave 2 adds a band on the live price, staked in the gauge. In a mainnet fork test, $20,000 earned 3,976 MEZO in a quiet day with the band and 0 without it.
- A fresh security review of the new code found one high, one medium and one low issue. All three are fixed, the first two with tests written to fail first ([SECURITY.md](../contracts/SECURITY.md)).
- The live app's first screen reads Mezo mainnet in the browser, with no wallet: what selling 10k to 500k MUSD pays at the current block. A browser test walks connect, approve, deposit and withdraw with a real wallet on testnet.
- The Wave 1 fork tests are re-pinned to today's mainnet (block 13,238,000). 77 unit and fork tests and 10 invariants pass.
- A capped mainnet vault on the real MUSD/mUSDC pool and gauge: pending deployment.

**How it works:**
Nearly every buyer of MUSD on Mezo is a handful of positions parked at one price. In the main MUSD/mUSDC pool, 6 of the 10 positions staked in its gauge sit in one tick range and hold 93% of the staked liquidity. The whole pool's buy side is about $111,709: selling 100,000 MUSD pays $99,284, and selling 500,000 pays $111,687, because the buyers run out. When those positions stepped away in October, a 10,000 MUSD sale replayed at a block on Oct 22 would have paid $11.

Plumb adds buyers from outside. Depositors put in mUSDC. Half goes into a band on the live price: the vault swaps just enough mUSDC into MUSD to fill it, never paying more than the TWAP price plus one tick slot or more than $1, and stakes it in the pool's gauge. The rest is a bid from the band's lower edge down to about $0.98. MUSD bought below $1 earns in sMUSD and is offered back only at $1 or more. MEZO streams to depositors after a 10% fee, a 10% incentive posted back to the same gauge's voters, and a 1% tip to whoever calls `rebalance()`. Exits are pro rata and in kind, any time. No owner, no admin keys, deposits capped at 5,000 mUSDC.

On a fork of mainnet, a $50,000 deposit lifts what a 400,000 MUSD sale pays from $111,687 to $161,679.

**Target group:** Holders of mUSDC on Mezo who want it to earn the MEZO the pool's gauge already pays (about 87,350 MEZO a day to liquidity at the price), and Mezo itself, whose MUSD buy side today rests on a few positions. Anyone can read the live depth page without a wallet.

**Tech stack:** Solidity 0.8.28 and Foundry (mainnet-fork tests against Mezo's real pool, gauge and sMUSD; fuzz and invariant suites; Slither), Uniswap v3 math libraries, Next.js 15, viem and wagmi, Playwright, a TypeScript keeper.

**Track:** Track 1 (DeFi), and Track 2 (Access and Distribution).
- Track 1: outside capital funds MUSD's buy side and earns Mezo's gauge rewards for it, with bought MUSD parked in sMUSD.
- Track 2: anyone with mUSDC can provide MUSD liquidity from a page that shows, live and without a wallet, what MUSD holders can sell for.

**Chain deployed on:** Mezo testnet (vault `0x9688ef37203022054b8337e8b5dA220Eed24e481`, source verified) Mezo mainnet: capped vault on the real pool and gauge, pending deployment (the README will carry the address).

**Project status:** Wave 2 resubmission of a Wave 1 project, with the changes listed above.

**Project readiness:** Testnet vault live and verified, with deposit, keeper rebalance and withdrawal transactions. Mainnet vault (capped at 5,000 mUSDC): pending deployment. App: https://kinnuworks.github.io/plumb/

**Future milestones:**
1. Raise the cap as outside depositors join, after an external review.
2. The same vault on Aero's MUSD/USDC pool on Base, where Mezo's gauges already pay.
3. A governance proposal to put sMUSD's idle MUSD behind the peg with the optional ask strategy.

**Team:** Kinnu (solo builder: contracts, app, keeper). X: [@heykinnu](https://x.com/heykinnu). GitHub: [kinnuworks](https://github.com/kinnuworks).

## Deck

`docs/plumb-deck.pdf` (built from `docs/deck/build.py`): Plumb; the book today; when those positions leave; what changed since Wave 1; the vault; proof; who pays, who earns; safety; built on Mezo; team, status, next.

## Video

Script and shot list are kept with the project plan; the cut is under two minutes. Rough cut of the real wallet flow on testnet: `docs/roughcut/wallet-flow.webm`.
