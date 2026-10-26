# Evidence

Every claim in the README links to a transaction, a test, or a command that recomputes it.

## Mezo testnet (chain 31611), Oct 26, 2026

All testnet transactions come from one wallet: the pool, the seller and the depositor are the builder. Testnet has no other MUSD/mUSDC concentrated pool or traders. The mainnet fork tests run against the real pool and its real liquidity.

### Getting tokens and building the market

| Step | What happened | Transaction |
|---|---|---|
| Get MUSD the normal way | Opened a trove: 1,800 MUSD against 0.04 testnet BTC | [0x89a5…ab65](https://explorer.test.mezo.org/tx/0x89a57035709db0123879dd9be1da19719f17f8e6774d1b51cebfd614adb2ab65) |
| Get mUSDC | Swapped 900 MUSD for 757 mUSDC in Mezo's MUSD/mUSDC stable pool (Mezo's testnet RPC sometimes fails to return this receipt; the explorer shows it) | [0x435c…1505](https://explorer.test.mezo.org/tx/0x435c9f671fd5bd31cef4e3b487a31e7e8af32416bd8f5d25263bc5bf15321505) |
| Build the market | Created the MUSD/mUSDC CL pool (fee tier and spacing as on mainnet), opened at $0.99, seeded a 700 MUSD sell wall up to $1.00 | pool [0xf621…6c2a](https://explorer.test.mezo.org/address/0xf6212414351f29AB816371f6b4ceE51960916c2a) |

### Current vault: [0xA27A…cF9E](https://explorer.test.mezo.org/address/0xA27AbD357f28c41732EA6670278140284fbAcF9E)

Deployed with all review fixes and a 2,000 mUSDC deposit cap. Source verified on Sourcify (exact match).

| Step | What happened | Transaction |
|---|---|---|
| Deposit | 500 mUSDC deposited and placed as a bid in one transaction (position #229) | [0x4764…1936](https://explorer.test.mezo.org/tx/0x476411d0c2075f330eaf51077711b6d3fc80ade58c18087053c41d0cffab1936) |
| Cap | A further 1,600 mUSDC deposit is refused with `CapExceeded(2000000000)` (checked with eth_call, no transaction) | |
| A seller arrives | The builder's wallet sold 150 MUSD into the pool; the vault's bid bought it | [0x2f09…1714](https://explorer.test.mezo.org/tx/0x2f0921eb24afa07154fd9b5da334c180fee1fed9d95776cdbd0f6e5761c51714) |
| Keeper | The keeper bot saw "market moved into the bid" and re-centred the book on its first attempt: 353 mUSDC re-placed as a new bid, 150 MUSD held | [0x5d18…b54c](https://explorer.test.mezo.org/tx/0x5d18a430973bc32c832bbf16a8290a443f828a1c001486f13ab6e4d799c7b54c) |
| Withdraw | Half the shares redeemed in kind: 75 MUSD and 176.6 mUSDC back, the bid still live with the rest | [0x64ec…dda8](https://explorer.test.mezo.org/tx/0x64ece5b89ca5ccb67a60ab41d7862f9e44f460c9b6d6d35cd80a7aca9227dda8) |

The bid's effect, from the quoter at the block before the deposit and the block of it:

| Block | Selling 400 MUSD into the pool paid |
|---|---|
| 16,377,592 (before) | $0. The pool had no bids |
| 16,377,593 (after) | $389.39 |

```bash
cd contracts
CODE=$(forge inspect PlumbQuoter deployedBytecode); Q=0x000000000000000000000000000000000000bEEF
for B in 16377592 16377593; do
  cast call $Q "quoteExactIn(address,bool,uint256)(uint256,int24)" \
    0xf6212414351f29AB816371f6b4ceE51960916c2a true 400000000000000000000 \
    --override-code $Q:$CODE --block $B --rpc-url https://rpc.test.mezo.org
done
```

### First vault, before the second review: [0xf7db…637A](https://explorer.test.mezo.org/address/0xf7db34df67373d06629dd154096d260A30e2637A)

Same flow, kept for the record: deposit [0x8d5f…462d](https://explorer.test.mezo.org/tx/0x8d5fa937ff19a084194ae8501ea4ab0ba1bdf467661ae2184aa78866721d462d) (a 400 MUSD sale went from $0 to $392.50), sale [0x7c27…07ec](https://explorer.test.mezo.org/tx/0x7c27ea135016ce44b413fc967ea5ed8112a2bd812e579c1e1307ce56541207ec), keeper rebalance [0x3a79…ae2a](https://explorer.test.mezo.org/tx/0x3a79366b3a5503965752cf89200378775a612d51a816f06c8ee869ec077eae2a) (an earlier attempt reverted because the price moved while it was in flight), partial withdraw [0x8f7b…390f](https://explorer.test.mezo.org/tx/0x8f7b574f0dc4f0395424b88a7187a522fdfeba6ea56aa3a08a1ca16af2fe390f), full withdraw [0x0da3…f838](https://explorer.test.mezo.org/tx/0x0da38d8431c281848edfaddec00a2ca344e7fae22e8e6b7505141dc6c234f838).

## Mezo mainnet, on a fork pinned at block 12,772,660

Run `MEZO_RPC_URL=https://mezo-mainnet.boar.network forge test -vv` in `contracts/`.

| Claim | Test |
|---|---|
| A $25k deposit lifts a 100k MUSD sale from $38,556 to $63,556 | `test_depositMakesSellingMusdCheaper` |
| About 40,600 MEZO to depositors for a day in range (see ECONOMICS.md for why that is the best case) | `test_mezoStreamsToHolders` |
| A flash-loan deposit, claim and redeem gets 0 MEZO | `test_flashDepositCannotSnipeMezo` |
| A deposit-redeem round trip while the price moves loses $0.36 on $100,000 | `test_depositRedeemRoundTripNeverProfits` |
| sMUSD's owner moves all 7,382,555 MUSD into PlumbAskStrategy | `test_switchMovesEverySaversMusd` |
| A full cycle sells 27,158 MUSD at $1.001+ and returns 164 MUSD to savers | `test_fullCycleEarnsForSavers` |
| A sandwiched buyback is refused without spending anything | `test_sandwichedBuybackIsRefusedAndWithdrawalsStillPay` |
| A long premium cannot drain idle MUSD; no yield is paid on unrealised fills | `test_sustainedPremiumKeepsExposureCapped`, `test_noYieldWhileFillsAreUnrealised` |
| Migration waits rather than strand USD, and savers lose nothing on the round trip | `test_migrateWaitsForFillsToBeBoughtBack` |
| Two equal depositors get equal value, fees included, whoever leaves first | `test_feesAreSharedNotTakenByFirstRedeemer` |
| An sMUSD outage pays sMUSD in kind instead of blocking exits | `test_exitSurvivesSmusdOutage` |

## Mainnet history

`data/depth_history.csv` recomputes the 10k and 100k MUSD sell quotes every two days from Aug 28 to Oct 26 with the same quoter. The command in the README reproduces any row.
