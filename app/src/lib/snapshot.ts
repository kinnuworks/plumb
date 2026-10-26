import "server-only";
import { createPublicClient, encodeFunctionData, decodeFunctionResult, erc20Abi, http, parseAbi, formatUnits } from "viem";
import { mezo } from "./chains";
import { MAINNET, QUOTER_OVERRIDE_ADDRESS } from "./addresses";
import { QUOTER_BYTECODE } from "@/abi/quoterBytecode";
import quoterAbi from "@/abi/PlumbQuoter.json";
import { musdPriceAtTick } from "./peg";

const client = createPublicClient({ chain: mezo, transport: http(mezo.rpcUrls.default.http[0]) });

const poolAbi = parseAbi([
  "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, bool)",
]);
const activePoolAbi = parseAbi([
  "function getCollateralBalance() view returns (uint256)",
  "function getPrincipal() view returns (uint256)",
]);

export const SELL_SIZES = [1_000, 10_000, 100_000, 1_000_000] as const;

export type Venue = { chain: string; dex: string; pair: string; price: number; liquidityUsd: number };

export type PegSnapshot = {
  block: string;
  timestamp: number;
  spotTick: number;
  musdPrice: number;
  pool: { usd: number; musd: number };
  sellQuotes: { size: number; usdOut: number; avgPrice: number }[];
  supply: {
    total: number;
    stabilityPool: number;
    savingsIdle: number;
    clPool: number;
    bridged: number;
    other: number;
  };
  borrowBook: { btcCollateral: number; musdDebt: number };
  venues: Venue[];
};

/** Prices selling each size of MUSD into the Mezo pool at `blockNumber` (default latest). */
export async function quoteSells(sizes: readonly number[], blockNumber?: bigint) {
  const data = encodeFunctionData({
    abi: quoterAbi,
    functionName: "quoteCurve",
    args: [MAINNET.pool, false, sizes.map((s) => BigInt(s) * 10n ** 18n)],
  });
  const res = await client.call({
    to: QUOTER_OVERRIDE_ADDRESS,
    data,
    blockNumber,
    stateOverride: [{ address: QUOTER_OVERRIDE_ADDRESS, code: QUOTER_BYTECODE }],
  });
  const outs = decodeFunctionResult({ abi: quoterAbi, functionName: "quoteCurve", data: res.data! }) as bigint[];
  return sizes.map((size, i) => {
    const usdOut = Number(formatUnits(outs[i], 6));
    return { size, usdOut, avgPrice: usdOut / size };
  });
}

async function fetchVenues(): Promise<Venue[]> {
  try {
    const r = await fetch(`https://api.dexscreener.com/latest/dex/tokens/${MAINNET.musd}`, {
      next: { revalidate: 300 },
    });
    const j = (await r.json()) as {
      pairs?: {
        chainId: string;
        dexId: string;
        baseToken: { symbol: string };
        quoteToken: { symbol: string };
        priceUsd?: string;
        liquidity?: { usd?: number };
      }[];
    };
    return (j.pairs ?? [])
      .filter((p) => p.baseToken.symbol === "MUSD" && /USD/.test(p.quoteToken.symbol) && (p.liquidity?.usd ?? 0) > 1_000)
      .map((p) => ({
        chain: p.chainId,
        dex: p.dexId,
        pair: `${p.baseToken.symbol}/${p.quoteToken.symbol}`,
        price: Number(p.priceUsd ?? 0),
        liquidityUsd: p.liquidity?.usd ?? 0,
      }))
      .sort((a, b) => b.liquidityUsd - a.liquidityUsd);
  } catch {
    return [];
  }
}

export async function getPegSnapshot(): Promise<PegSnapshot> {
  const block = await client.getBlock();
  const at = { blockNumber: block.number };
  const bal = (token: `0x${string}`, holder: `0x${string}`) =>
    ({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [holder] }) as const;

  const [slot0, poolUsd, poolMusd, total, sp, idle, ntt, coll, principal] = await client.multicall({
    ...at,
    allowFailure: false,
    contracts: [
      { address: MAINNET.pool, abi: poolAbi, functionName: "slot0" },
      bal(MAINNET.musdc, MAINNET.pool),
      bal(MAINNET.musd, MAINNET.pool),
      { address: MAINNET.musd, abi: erc20Abi, functionName: "totalSupply" },
      bal(MAINNET.musd, MAINNET.stabilityPool),
      bal(MAINNET.musd, MAINNET.idleStrategy),
      bal(MAINNET.musd, MAINNET.nttManager),
      { address: MAINNET.activePool, abi: activePoolAbi, functionName: "getCollateralBalance" },
      { address: MAINNET.activePool, abi: activePoolAbi, functionName: "getPrincipal" },
    ],
  });

  const [sellQuotes, venues] = await Promise.all([quoteSells(SELL_SIZES, block.number), fetchVenues()]);

  const m = (x: bigint) => Number(formatUnits(x, 18));
  const tick = Number(slot0[1]);
  const supply = {
    total: m(total),
    stabilityPool: m(sp),
    savingsIdle: m(idle),
    clPool: m(poolMusd),
    bridged: m(ntt),
    other: 0,
  };
  supply.other = supply.total - supply.stabilityPool - supply.savingsIdle - supply.clPool - supply.bridged;

  return {
    block: block.number.toString(),
    timestamp: Number(block.timestamp),
    spotTick: tick,
    musdPrice: musdPriceAtTick(tick),
    pool: { usd: Number(formatUnits(poolUsd, 6)), musd: m(poolMusd) },
    sellQuotes,
    supply,
    borrowBook: { btcCollateral: m(coll), musdDebt: m(principal) },
    venues,
  };
}
