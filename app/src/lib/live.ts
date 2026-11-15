import { createPublicClient, decodeFunctionResult, encodeFunctionData, fallback, formatUnits, http, parseAbi } from "viem";
import { mezo } from "./chains";
import { MAINNET, QUOTER_OVERRIDE_ADDRESS } from "./addresses";
import { QUOTER_BYTECODE } from "@/abi/quoterBytecode";
import quoterAbi from "@/abi/PlumbQuoter.json";
import { musdPriceAtTick } from "./peg";

/** Browser-side mainnet client. drpc allows cross-origin calls and state overrides. */
export const liveClient = createPublicClient({
  chain: mezo,
  transport: fallback([http("https://mezo.drpc.org"), http(mezo.rpcUrls.default.http[0])]),
});

export const LIVE_SIZES = [10_000, 100_000, 250_000, 500_000] as const;

export type LiveDepth = {
  block: bigint;
  musdPrice: number;
  quotes: { size: number; usdOut: number; avgPrice: number }[];
};

const poolAbi = parseAbi(["function slot0() view returns (uint160, int24, uint16, uint16, uint16, bool)"]);

/** What selling each size of MUSD into Mezo's main pool pays at the latest block. Nothing is sent. */
export async function readLiveDepth(): Promise<LiveDepth> {
  const block = await liveClient.getBlockNumber();
  const [, tick] = await liveClient.readContract({ address: MAINNET.pool, abi: poolAbi, functionName: "slot0", blockNumber: block });
  const res = await liveClient.call({
    to: QUOTER_OVERRIDE_ADDRESS,
    blockNumber: block,
    data: encodeFunctionData({
      abi: quoterAbi,
      functionName: "quoteCurve",
      args: [MAINNET.pool, false, LIVE_SIZES.map((s) => BigInt(s) * 10n ** 18n)],
    }),
    stateOverride: [{ address: QUOTER_OVERRIDE_ADDRESS, code: QUOTER_BYTECODE }],
  });
  if (!res.data) throw new Error("quoter returned no data");
  const outs = decodeFunctionResult({ abi: quoterAbi, functionName: "quoteCurve", data: res.data }) as bigint[];
  return {
    block,
    musdPrice: musdPriceAtTick(Number(tick)),
    quotes: LIVE_SIZES.map((size, i) => {
      const usdOut = Number(formatUnits(outs[i], 6));
      return { size, usdOut, avgPrice: usdOut / size };
    }),
  };
}
