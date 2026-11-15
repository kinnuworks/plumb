"""Builds docs/deck/plumb-deck.html; scripts/deck-pdf.sh prints it to PDF with headless Chrome."""
from pathlib import Path

here = Path(__file__).parent
chart = (here / "chart.svg.part").read_text()

slides = [
    ("Plumb", "A standing bid under MUSD. Wave 2 resubmission; Track 1 (DeFi) and Track 2.",
     "<p class='big'>A capped vault on Mezo that pays stablecoin holders the main MUSD pool's MEZO rewards to keep buyers under MUSD: one band on the live price, and a bid below it down to about $0.98.</p>"),
    ("The book today", "Mezo's main MUSD/mUSDC pool, read from chain on Nov 15",
     """<div class='stats'>
       <div><b>$0.994</b><span>MUSD price in the pool</span></div>
       <div><b>$111,709</b><span>of bids in the whole pool</span></div>
       <div><b>93%</b><span>of staked liquidity in one tick range, held by 6 of 10 positions</span></div>
     </div>
     <p>Selling 100,000 MUSD pays $99,284. Selling 500,000 pays $111,687: the buyers run out, and the rest sells for almost nothing.</p>"""),
    ("When those positions leave", "USD paid for selling 100,000 MUSD on Mezo, replayed at each block",
     chart + "<p class='note'>Mostly near $99,000 from Aug 28 to Oct 16. Replayed at a block on Oct 22, a 10,000 MUSD sale would have paid $11. Depth came back when the concentrated positions returned.</p>"),
    ("What changed since Wave 1", "",
     """<ul>
       <li>A band on the live price, staked in the gauge: it earns MEZO while MUSD trades normally. In a fork test a quiet day earned 3,976 MEZO on $20,000; Wave 1's bid-only layout earned 0.</li>
       <li>A fresh security review found one high, one medium and one low issue in the new code. All fixed, with tests.</li>
       <li>The app's first screen reads Mezo mainnet live, with no wallet. A browser test walks connect, approve, deposit and withdraw with a real wallet on testnet.</li>
       <li>Capped mainnet vault on the real pool and gauge: being deployed for this wave.</li>
     </ul>"""),
    ("The vault", "PlumbBidVault",
     """<ol>
       <li>Deposit mUSDC, get shares. Capped at 5,000 mUSDC.</li>
       <li>Half goes into a band on the live price; the vault swaps just enough into MUSD, never paying more than the TWAP plus one tick slot or more than $1.</li>
       <li>The rest is a bid from the band down to about $0.98. Both are staked in the pool's gauge.</li>
       <li>MUSD the bid buys earns in sMUSD and is offered back only at $1 or more.</li>
       <li>Exits are pro rata and in kind, any time. No owner, no admin.</li>
     </ol>"""),
    ("Proof", "Mezo mainnet's real contracts on a fork, and live on testnet",
     """<div class='stats'>
       <div><b>0 → 3,976 MEZO</b><span>a quiet day on $20,000: bid only vs band and bid (fork)</span></div>
       <div><b>$111,687 → $161,679</b><span>a 400k MUSD sale, before and after a $50,000 deposit (fork)</span></div>
       <div><b>3 txs</b><span>approve, deposit, withdraw by a browser wallet on the testnet vault, source verified</span></div>
     </div>"""),
    ("Who pays, who earns", "",
     """<ul>
       <li>The pool's gauge pays about 87,350 MEZO a day to liquidity at the price. Today a handful of positions collect it.</li>
       <li>A depositor's share: $20,000 earned 3,976 MEZO in a quiet day after fees, about $11.90 at today's MEZO price (0.0030 MUSD). It falls as more liquidity joins.</li>
       <li>The vault keeps 10% of MEZO, posts 10% back to the gauge's voters, tips 1% to whoever rebalances (under $0.20 of gas).</li>
       <li>The risk: MUSD bought below $1, held until it sells at $1 or more.</li>
     </ul>"""),
    ("Safety", "",
     """<ul>
       <li>No owner, no admin, no upgrades. Every parameter fixed at deploy; deposits capped.</li>
       <li>Spot must agree with the TWAP before any liquidity moves or any deposit is priced.</li>
       <li>No bids or deposits below $0.97; bidding stops at 60% inventory.</li>
       <li>77 unit and mainnet-fork tests, 10 invariants, slither, and a fresh review whose findings each got a failing test first. Unaudited.</li>
     </ul>"""),
    ("Built on Mezo", "",
     """<table>
       <tr><td>MUSD/mUSDC CL pool, NFT manager</td><td>band, bid, ask; the band's capped swap</td></tr>
       <tr><td>CLGauge, PoolsVoter, gauge voting reward</td><td>MEZO to depositors, incentives back to the peg pool</td></tr>
       <tr><td>sMUSD</td><td>parks MUSD bought below $1</td></tr>
       <tr><td>TroveManager, ActivePool, Stability Pool</td><td>the live peg page</td></tr>
     </table>"""),
    ("Team, status, next", "",
     """<ul>
       <li>Solo builder. Status: vault live and verified on testnet; capped mainnet vault for this wave.</li>
       <li>Next: grow the cap with outside depositors; the same vault on Aero's MUSD/USDC pool on Base, where Mezo's gauges already pay; a governance proposal to put sMUSD's idle MUSD behind the peg with the optional ask strategy.</li>
     </ul>"""),
]

css = """
@page { size: 1280px 720px; margin: 0; }
* { box-sizing: border-box; }
body { margin: 0; font-family: -apple-system, 'Helvetica Neue', Arial, sans-serif; color: #0f172a; background: #fff; }
section { width: 1280px; height: 720px; padding: 72px 88px; page-break-after: always; display: flex; flex-direction: column; gap: 22px; position: relative; }
h1 { font-size: 54px; margin: 0; letter-spacing: -0.02em; }
h2 { font-size: 24px; margin: 0; font-weight: 400; color: #475569; }
p, li, td { font-size: 26px; line-height: 1.45; }
.big { font-size: 34px; line-height: 1.4; max-width: 980px; margin-top: 40px; }
.note { font-size: 20px; color: #475569; }
ul, ol { margin: 0; padding-left: 30px; display: flex; flex-direction: column; gap: 10px; }
.stats { display: flex; gap: 28px; margin-top: 20px; }
.stats div { flex: 1; border: 1px solid #e2e8f0; border-radius: 14px; padding: 26px; }
.stats b { display: block; font-size: 40px; margin-bottom: 10px; font-variant-numeric: tabular-nums; }
.stats span { font-size: 20px; color: #475569; line-height: 1.35; display: block; }
table { border-collapse: collapse; width: 100%; }
td { border-top: 1px solid #e2e8f0; padding: 12px 0; font-size: 22px; }
td:first-child { width: 52%; font-weight: 600; }
code { font-size: 0.9em; }
.num { position: absolute; bottom: 36px; right: 88px; font-size: 16px; color: #94a3b8; }
"""

html = ["<!doctype html><html><head><meta charset='utf-8'><title>Plumb</title><style>", css, "</style></head><body>"]
for i, (title, sub, body) in enumerate(slides, 1):
    html.append(f"<section><h1>{title}</h1>{f'<h2>{sub}</h2>' if sub else ''}{body}<div class='num'>{i} / {len(slides)}</div></section>")
html.append("</body></html>")
(here / "plumb-deck.html").write_text("".join(html))
print("wrote", here / "plumb-deck.html")
