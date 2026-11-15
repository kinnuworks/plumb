"use client";

import { useQuery } from "@tanstack/react-query";
import { readLiveDepth } from "@/lib/live";
import { fmtNum, fmtUsd } from "@/lib/peg";

/** First thing on the page: what selling MUSD on Mezo pays this block, read in the browser. */
export function LiveDepthPanel() {
  const q = useQuery({ queryKey: ["live-depth"], queryFn: readLiveDepth, refetchInterval: 30_000 });

  if (q.isError) {
    return (
      <div role="alert" className="rounded-lg border border-current/20 p-4 text-sm">
        Couldn&apos;t reach Mezo mainnet just now ({(q.error as Error).message.split("\n")[0]}). The numbers further down are
        from the last build.
      </div>
    );
  }
  if (!q.data) {
    return <div className="rounded-lg border border-current/15 p-4 text-sm opacity-70">Reading Mezo mainnet…</div>;
  }

  const d = q.data;
  return (
    <div className="rounded-lg border border-current/20 p-4 space-y-3" data-testid="live-depth">
      <div className="text-sm opacity-70">
        Live from Mezo mainnet, block{" "}
        <a className="underline" href={`https://explorer.mezo.org/block/${d.block}`}>
          {d.block.toString()}
        </a>
        . MUSD trades at ${d.musdPrice.toFixed(4)} in the main MUSD/mUSDC pool.
      </div>
      <table className="w-full text-sm tabular-nums">
        <thead className="text-left opacity-60">
          <tr>
            <th className="py-1">Sell now</th>
            <th>You get</th>
            <th>Average price</th>
          </tr>
        </thead>
        <tbody>
          {d.quotes.map((x) => (
            <tr key={x.size} className="border-t border-current/10" data-testid={`quote-${x.size}`}>
              <td className="py-1">{fmtNum(x.size)} MUSD</td>
              <td>{fmtUsd(x.usdOut)}</td>
              <td>${x.avgPrice.toFixed(4)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
