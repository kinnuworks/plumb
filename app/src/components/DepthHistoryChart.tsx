import history from "@/data/depthHistory.json";
import { fmtUsd } from "@/lib/peg";

type Point = { block: number; time: number; usdFor10k: number; usdFor100k: number; tick: number };

/** What a 100k MUSD sale on Mezo's main pool paid, every two days, recomputed at each block. */
export function DepthHistoryChart() {
  const points = history as Point[];
  const w = 720;
  const h = 220;
  const pad = { l: 56, r: 12, t: 12, b: 28 };
  const max = 100_000;
  const x = (i: number) => pad.l + (i / (points.length - 1)) * (w - pad.l - pad.r);
  const y = (v: number) => pad.t + (1 - v / max) * (h - pad.t - pad.b);
  const path = points.map((p, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(p.usdFor100k).toFixed(1)}`).join(" ");
  const date = (t: number) =>
    new Date(t * 1000).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });

  return (
    <figure className="w-full">
      <svg viewBox={`0 0 ${w} ${h}`} className="w-full h-auto" role="img" aria-label="USD received for selling 100,000 MUSD over time">
        {[0, 25_000, 50_000, 75_000, 100_000].map((v) => (
          <g key={v}>
            <line x1={pad.l} x2={w - pad.r} y1={y(v)} y2={y(v)} className="stroke-current opacity-10" />
            <text x={pad.l - 8} y={y(v) + 4} textAnchor="end" className="fill-current opacity-60 text-[10px]">
              {v / 1000}k
            </text>
          </g>
        ))}
        <path d={path} fill="none" strokeWidth={2} className="stroke-current" />
        {points.map((p, i) => (
          <circle key={p.block} cx={x(i)} cy={y(p.usdFor100k)} r={2.5} className="fill-current">
            <title>{`${date(p.time)} (block ${p.block}): ${fmtUsd(p.usdFor100k)}`}</title>
          </circle>
        ))}
        {[0, Math.floor(points.length / 2), points.length - 1].map((i) => (
          <text key={i} x={x(i)} y={h - 8} textAnchor="middle" className="fill-current opacity-60 text-[10px]">
            {date(points[i].time)}
          </text>
        ))}
      </svg>
      <figcaption className="text-sm opacity-70 mt-2">
        USD paid for selling 100,000 MUSD into the MUSD/mUSDC pool on Mezo, recomputed at each block with an
        eth_call. Hover a point for the block number.
      </figcaption>
    </figure>
  );
}
