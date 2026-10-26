"""Builds docs/deck/plumb-deck.html; scripts/deck-pdf.sh prints it to PDF with headless Chrome."""
from pathlib import Path

here = Path(__file__).parent
chart = (here / "chart.svg.part").read_text()

slides = [
    ("Plumb", "A peg module for MUSD, built from Mezo's own pool, gauge and savings vault.",
     "<p class='big'>Stablecoins become standing bids for MUSD just under its price. What they buy earns in sMUSD and is sold back only at $1 or more.</p>"),
    ("The book today", "Mezo's main MUSD/mUSDC pool, read from chain on Oct 26",
     """<div class='stats'>
       <div><b>5.3M</b><span>MUSD offered between $0.99 and $1.00</span></div>
       <div><b>$38,581</b><span>of bids</span></div>
       <div><b>$0.990</b><span>MUSD price</span></div>
     </div>
     <p>Selling 100,000 MUSD into that pool pays $38,556. The rest of the sale finds no buyers.</p>"""),
    ("October", "USD paid for selling 100,000 MUSD on Mezo, replayed at each block",
     chart + "<p class='note'>Mostly near $99,000 from Aug 28 to Oct 16, with two brief dips. Replayed at a block on Oct 22, a 10,000 MUSD sale would have paid $11.</p>"),
    ("Why it matters", "",
     """<ul>
       <li>The borrowing book holds 14,489 MUSD of debt against 16.59 BTC (Mezo's H1 report: $13.1M of loans in June).</li>
       <li>96.7% of MUSD supply sits in protocol contracts: Stability Pool, sMUSD, the pool's sell side, the bridge.</li>
       <li>Mezo already pays MEZO emissions for MUSD liquidity. Plumb points that liquidity at the side that is missing.</li>
     </ul>"""),
    ("The vault", "PlumbBidVault",
     """<ol>
       <li>Deposit mUSDC, get shares.</li>
       <li>The vault bids from one tick under the market to 2% deeper, staked in the pool's gauge.</li>
       <li>MUSD it buys earns in sMUSD while MUSD is under $1.</li>
       <li>Near $1 it is offered back, never below $1.</li>
       <li>MEZO streams to depositors. 10% is posted back to the same gauge to pull veBTC votes.</li>
       <li>Exits are pro rata and in kind, any time.</li>
     </ol>"""),
    ("Proof", "Mezo mainnet's real contracts on a fork, and live on testnet",
     """<div class='stats'>
       <div><b>$38,556 → $63,556</b><span>a 100k MUSD sale, before and after a $25k deposit (fork)</span></div>
       <div><b>$0 → $389</b><span>a 400 MUSD sale, block before and after our testnet deposit</span></div>
       <div><b>$11 → $9,851</b><span>a 10k MUSD sale at Oct 22's thinnest block, without and with a $25k Plumb bid</span></div>
     </div>"""),
    ("sMUSD strategy", "PlumbAskStrategy",
     """<ul>
       <li>sMUSD holds 7.38M MUSD in its default IdleStrategy.</li>
       <li>One <code>setStrategy</code> call: 95% stays idle, 5% becomes a standing offer at $1.001 and up.</li>
       <li>On the fork, the real owner switches all 7,382,555 MUSD over. A full cycle returns 164 MUSD to savers, and switching back returns every token.</li>
       <li>90% of savers can leave at once with the order filled. Sandwiched buybacks are refused.</li>
     </ul>"""),
    ("Safety", "",
     """<ul>
       <li>No owner, no admin, no upgrades, no signatures or meta-transactions.</li>
       <li>Spot must agree with the TWAP before any liquidity moves or any deposit is priced.</li>
       <li>Floor at $0.96 and a 60% inventory cap stop the vault buying all the way down.</li>
       <li>50 fork tests against Mezo mainnet state, 9 unit tests and 10 invariants. The invariants found a share-pricing bug and three blind reviews found more; each fix has its own test.</li>
     </ul>"""),
    ("Built on Mezo", "",
     """<table>
       <tr><td>MUSD/mUSDC CL pool, NFT manager</td><td>bids and asks</td></tr>
       <tr><td>CLGauge, PoolsVoter, gauge voting reward</td><td>MEZO to depositors, incentives back to the peg pool</td></tr>
       <tr><td>sMUSD and its strategy hook</td><td>parked inventory; the ask strategy</td></tr>
       <tr><td>CL router</td><td>strategy buybacks</td></tr>
       <tr><td>ActivePool, Stability Pool, NTT manager</td><td>the public peg observatory</td></tr>
     </table>"""),
    ("Next", "",
     """<ol>
       <li>Mainnet vault with a deposit cap, seeded by whoever wants MUSD at $1: the foundation, market makers, borrowers.</li>
       <li>The same vault on Aero's MUSD/USDC pool on Base, where Mezo's gauges already pay.</li>
       <li>A governance proposal, with the fork test as evidence, to put sMUSD's idle MUSD to work under published caps.</li>
     </ol>"""),
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
