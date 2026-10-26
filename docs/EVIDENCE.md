# Evidence

Every claim in the README links to a transaction, a test, or a command that recomputes it.

## Mezo testnet (chain 31611), Oct 26, 2026

| Step | What happened | Transaction |
|---|---|---|
| 1. Get MUSD the normal way | Opened a trove: 1,800 MUSD against 0.04 testnet BTC | [0x89a5…ab65](https://explorer.test.mezo.org/tx/0x89a57035709db0123879dd9be1da19719f17f8e6774d1b51cebfd614adb2ab65) |
| 2. Get mUSDC | Swapped 900 MUSD for 757 mUSDC in Mezo's MUSD/mUSDC stable pool | [0x435c…1505](https://explorer.test.mezo.org/tx/0x435c9f671fd5bd31cef4e3b487a31e7e8af32416bd8f5d25263bc5bf15321505) |
| 3. Build the market | Created the MUSD/mUSDC CL pool (fee tier and spacing as on mainnet), opened at $0.99, seeded a 700 MUSD sell wall up to $1.00 | pool [0xf621…6c2a](https://explorer.test.mezo.org/address/0xf6212414351f29AB816371f6b4ceE51960916c2a) |
| 4. Deploy | PlumbBidVault, source verified on Sourcify (exact match) | [0xf7db…637A](https://explorer.test.mezo.org/address/0xf7db34df67373d06629dd154096d260A30e2637A) |
| 5. Deposit | 500 mUSDC deposited and placed as a bid in one transaction (position #227) | [0x8d5f…462d](https://explorer.test.mezo.org/tx/0x8d5fa937ff19a084194ae8501ea4ab0ba1bdf467661ae2184aa78866721d462d) |
| 6. A seller arrives | 200 MUSD sold into the pool; the vault's bid bought it | [0x7c27…07ec](https://explorer.test.mezo.org/tx/0x7c27ea135016ce44b413fc967ea5ed8112a2bd812e579c1e1307ce56541207ec) |
| 7. Keeper | The keeper bot saw "market moved into the bid" and re-centred the book: 303 mUSDC re-placed as bid #228, 200 MUSD held | [0x3a79…ae2a](https://explorer.test.mezo.org/tx/0x3a79366b3a5503965752cf89200378775a612d51a816f06c8ee869ec077eae2a) |
| 8. Withdraw | Half the shares redeemed in kind: about 100 MUSD and 151 mUSDC back, bid still live with the rest | [0x8f7b…390f](https://explorer.test.mezo.org/tx/0x8f7b574f0dc4f0395424b88a7187a522fdfeba6ea56aa3a08a1ca16af2fe390f) |

The keeper's first attempt at step 7 (0x5c49…7baf) reverted on chain because the price moved while it was in flight. The second attempt succeeded. Nothing was lost but gas.

### The bid's effect on testnet

The quoter, run at the block before and the block of step 5:

| Block | Selling 400 MUSD into the pool paid |
|---|---|
| 16,377,180 (before the deposit) | $0. The pool had no bids |
| 16,377,181 (after the deposit) | $392.50 |

```bash
cd contracts
CODE=$(forge inspect PlumbQuoter deployedBytecode); Q=0x000000000000000000000000000000000000bEEF
for B in 16377180 16377181; do
  cast call $Q "quoteExactIn(address,bool,uint256)(uint256,int24)" \
    0xf6212414351f29AB816371f6b4ceE51960916c2a true 400000000000000000000 \
    --override-code $Q:$CODE --block $B --rpc-url https://rpc.test.mezo.org
done
```

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

## Mainnet history

`data/depth_history.csv` recomputes the 10k and 100k MUSD sell quotes every two days from Aug 28 to Oct 26 with the same quoter. The command in the README reproduces any row.
