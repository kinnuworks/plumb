import { getPegSnapshot } from "@/lib/snapshot";
import { fmtCompact, fmtNum, fmtUsd } from "@/lib/peg";
import { DepthHistoryChart } from "@/components/DepthHistoryChart";
import history from "@/data/depthHistory.json";

export const revalidate = 60;

function Stat({ label, value, note }: { label: string; value: string; note?: string }) {
  return (
    <div className="rounded-lg border border-current/15 p-4">
      <div className="text-xs uppercase tracking-wide opacity-60">{label}</div>
      <div className="text-2xl font-semibold mt-1 tabular-nums">{value}</div>
      {note && <div className="text-xs opacity-60 mt-1">{note}</div>}
    </div>
  );
}

export default async function Observatory() {
  const s = await getPegSnapshot();
  const worst = (history as { time: number; usdFor10k: number }[]).reduce((a, b) => (b.usdFor10k < a.usdFor10k ? b : a));
  const worstDate = new Date(worst.time * 1000).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
  const protocolHeld = s.supply.stabilityPool + s.supply.savingsIdle + s.supply.clPool + s.supply.bridged;

  return (
    <main className="mx-auto max-w-5xl px-4 py-10 space-y-12">
      <header className="space-y-3">
        <h1 className="text-3xl font-semibold">MUSD peg observatory</h1>
        <p className="opacity-80 max-w-3xl">
          Live state of MUSD&apos;s market on Mezo, read from chain at block{" "}
          <a className="underline" href={`https://explorer.mezo.org/block/${s.block}`}>{s.block}</a>. Every number on this
          page can be recomputed with a single eth_call.
        </p>
      </header>

      <section className="grid grid-cols-2 md:grid-cols-4 gap-3">
        <Stat label="MUSD on Mezo" value={`$${s.musdPrice.toFixed(4)}`} note={`${((1 - s.musdPrice) * 10_000).toFixed(0)} bps under $1`} />
        <Stat label="Buyers in the pool" value={fmtUsd(s.pool.usd)} note={`vs ${fmtCompact(s.pool.musd)} MUSD for sale`} />
        <Stat label="Borrowing book" value={`${fmtNum(s.borrowBook.musdDebt)} MUSD`} note={`against ${fmtNum(s.borrowBook.btcCollateral, 2)} BTC`} />
        <Stat label="Supply held by protocol" value={`${((protocolHeld / s.supply.total) * 100).toFixed(1)}%`} note={`of ${fmtCompact(s.supply.total)} MUSD`} />
      </section>

      <section className="space-y-4">
        <h2 className="text-xl font-semibold">What selling MUSD on Mezo pays right now</h2>
        <div className="overflow-x-auto">
          <table className="w-full text-sm tabular-nums">
            <thead className="text-left opacity-60">
              <tr><th className="py-2">You sell</th><th>You receive</th><th>Average price</th></tr>
            </thead>
            <tbody>
              {s.sellQuotes.map((q) => (
                <tr key={q.size} className="border-t border-current/10">
                  <td className="py-2">{fmtNum(q.size)} MUSD</td>
                  <td>{fmtUsd(q.usdOut)}</td>
                  <td>{q.avgPrice >= 0.5 ? `$${q.avgPrice.toFixed(4)}` : `$${q.avgPrice.toFixed(4)} (the book runs out)`}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="space-y-4">
        <h2 className="text-xl font-semibold">The buy side disappeared in October</h2>
        <p className="opacity-80 max-w-3xl">
          From late August to mid October a 100,000 MUSD sale paid about $99,000. Since Oct 18 the bids have been pulled.
          Replayed at a block on {worstDate}, selling 10,000 MUSD would have paid {fmtUsd(worst.usdFor10k)}.
        </p>
        <DepthHistoryChart />
      </section>

      <section className="space-y-4">
        <h2 className="text-xl font-semibold">Where the {fmtCompact(s.supply.total)} MUSD sits</h2>
        <table className="w-full text-sm tabular-nums">
          <tbody>
            {[
              ["Stability Pool (protocol bootstrap loan)", s.supply.stabilityPool],
              ["sMUSD savings, in IdleStrategy earning nothing", s.supply.savingsIdle],
              ["Offered for sale in the MUSD/mUSDC pool", s.supply.clPool],
              ["Bridged to Ethereum and Base", s.supply.bridged],
              ["Everyone else", s.supply.other],
            ].map(([label, v]) => (
              <tr key={label as string} className="border-t border-current/10">
                <td className="py-2">{label}</td>
                <td className="text-right">{fmtNum(v as number)} MUSD</td>
                <td className="text-right w-20 opacity-60">{(((v as number) / s.supply.total) * 100).toFixed(1)}%</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      {s.venues.length > 0 && (
        <section className="space-y-4">
          <h2 className="text-xl font-semibold">MUSD on other chains</h2>
          <table className="w-full text-sm tabular-nums">
            <thead className="text-left opacity-60"><tr><th className="py-2">Venue</th><th>Price</th><th className="text-right">Liquidity</th></tr></thead>
            <tbody>
              {s.venues.map((v) => (
                <tr key={`${v.chain}-${v.dex}-${v.pair}-${v.liquidityUsd}`} className="border-t border-current/10">
                  <td className="py-2">{v.dex} on {v.chain} ({v.pair})</td>
                  <td>${v.price.toFixed(4)}</td>
                  <td className="text-right">{fmtUsd(v.liquidityUsd)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="text-xs opacity-60">Off-Mezo prices from DexScreener.</p>
        </section>
      )}
    </main>
  );
}
