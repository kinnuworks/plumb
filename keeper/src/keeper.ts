/**
 * Plumb keeper. Watches a PlumbBidVault (and optionally a PlumbAskStrategy) and calls
 * rebalance() when the book has drifted from the market. Anyone can run it: rebalance is
 * permissionless, the vault pays the caller a small share of harvested MEZO, and every
 * transaction is simulated before it is sent.
 *
 * Env:
 *   RPC_URL          JSON-RPC endpoint
 *   CHAIN_ID         31611 (testnet) or 31612 (mainnet)
 *   VAULT            PlumbBidVault address
 *   STRATEGY         PlumbAskStrategy address (optional)
 *   PRIVATE_KEY      key that pays gas (keep only gas money on it)
 *   POLL_SECONDS     default 60
 *   DRIFT_TICKS      re-centre when the bid edge is this far from where it should be (default 20)
 */
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import vaultAbi from "./PlumbBidVault.json" with { type: "json" };
import strategyAbi from "./PlumbAskStrategy.json" with { type: "json" };

const env = (k: string, d?: string) => {
  const v = process.env[k] ?? d;
  if (v === undefined) throw new Error(`missing env ${k}`);
  return v;
};

const chain = defineChain({
  id: Number(env("CHAIN_ID", "31611")),
  name: "Mezo",
  nativeCurrency: { name: "Bitcoin", symbol: "BTC", decimals: 18 },
  rpcUrls: { default: { http: [env("RPC_URL", "https://rpc.test.mezo.org")] } },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
});
const transport = http(chain.rpcUrls.default.http[0]);
const pub = createPublicClient({ chain, transport });
const account = privateKeyToAccount(env("PRIVATE_KEY") as Hex);
const wallet = createWalletClient({ chain, transport, account });

const VAULT = env("VAULT") as Address;
const STRATEGY = process.env.STRATEGY as Address | undefined;
const POLL = Number(env("POLL_SECONDS", "60")) * 1000;
const DRIFT = Number(env("DRIFT_TICKS", "20"));
const once = process.argv.includes("--once");

const poolAbi = [
  {
    type: "function",
    name: "slot0",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { type: "uint160" },
      { type: "int24" },
      { type: "uint16" },
      { type: "uint16" },
      { type: "uint16" },
      { type: "bool" },
    ],
  },
] as const;
const nfpmAbi = [
  {
    type: "function",
    name: "positions",
    stateMutability: "view",
    inputs: [{ type: "uint256" }],
    outputs: [
      { type: "uint96" },
      { type: "address" },
      { type: "address" },
      { type: "address" },
      { type: "int24" },
      { type: "int24" },
      { type: "int24" },
      { type: "uint128" },
      { type: "uint256" },
      { type: "uint256" },
      { type: "uint128" },
      { type: "uint128" },
    ],
  },
] as const;

const log = (...a: unknown[]) => console.log(new Date().toISOString(), ...a);

type VaultState = {
  pool: Address;
  nfpm: Address;
  parTick: number;
  dir: number;
  spacing: number;
  nearPar: number;
  floor: number;
  lastRebalance: bigint;
  interval: bigint;
  depeg: number;
  holdings: readonly bigint[];
  bidId: bigint;
};

async function readVault(): Promise<VaultState> {
  const c = { address: VAULT, abi: vaultAbi } as const;
  const r = await pub.multicall({
    allowFailure: false,
    contracts: [
      { ...c, functionName: "pool" },
      { ...c, functionName: "nfpm" },
      { ...c, functionName: "parTick" },
      { ...c, functionName: "dir" },
      { ...c, functionName: "tickSpacing" },
      { ...c, functionName: "nearParDepeg" },
      { ...c, functionName: "floorDepeg" },
      { ...c, functionName: "lastRebalance" },
      { ...c, functionName: "minRebalanceInterval" },
      { ...c, functionName: "currentDepeg" },
      { ...c, functionName: "holdings" },
      { ...c, functionName: "bid" },
    ],
  });
  return {
    pool: r[0] as Address,
    nfpm: r[1] as Address,
    parTick: Number(r[2]),
    dir: Number(r[3]),
    spacing: Number(r[4]),
    nearPar: Number(r[5]),
    floor: Number(r[6]),
    lastRebalance: r[7] as bigint,
    interval: BigInt(r[8] as number),
    depeg: Number(r[9]),
    holdings: r[10] as readonly bigint[],
    bidId: (r[11] as readonly [bigint, boolean])[0],
  };
}

/** Explains why the vault should be rebalanced, or returns null if it is fine as it is. */
async function vaultNeedsRebalance(s: VaultState): Promise<string | null> {
  const [idleUsd, idleMusd, parked, , , , askMusd] = s.holdings;
  if (idleUsd > 1_000_000n && s.depeg < s.floor) return "USD waiting to be placed";
  if (idleMusd > 10n ** 18n) return "MUSD inventory waiting";
  if (s.depeg <= s.nearPar && parked > 0n) return "MUSD near $1: offer parked inventory";
  if (s.depeg > s.nearPar && askMusd > 0n) return "MUSD fell away from $1: park the ask";

  if (s.bidId !== 0n) {
    const [, tick] = await pub.readContract({ address: s.pool, abi: poolAbi, functionName: "slot0" });
    const pos = await pub.readContract({ address: s.nfpm, abi: nfpmAbi, functionName: "positions", args: [s.bidId] });
    const edgeTick = s.dir > 0 ? pos[5] : pos[6]; // the bid edge nearest the market
    const edgeDepeg = (edgeTick - s.parTick) * s.dir;
    const spotDepeg = (tick - s.parTick) * s.dir;
    if (spotDepeg >= edgeDepeg) return "market moved into the bid";
    if (edgeDepeg - spotDepeg > DRIFT) return `bid drifted ${edgeDepeg - spotDepeg} ticks from the market`;
  }
  return null;
}

async function send(address: Address, abi: typeof vaultAbi | typeof strategyAbi, why: string) {
  try {
    const { request } = await pub.simulateContract({ address, abi, functionName: "rebalance", account });
    const hash = await wallet.writeContract(request);
    log(`rebalance ${address} (${why}) -> ${hash}`);
    const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 180_000 });
    log(`  status ${receipt.status}, gas ${receipt.gasUsed}`);
  } catch (e) {
    // Simulation refusals are normal: cooldown, price unstable, nothing to do.
    log(`skip ${address}: ${(e as Error).message.split("\n")[0]}`);
  }
}

async function tick() {
  // Use chain time, not wall time: blocks can run ahead or behind the local clock.
  const now = (await pub.getBlock()).timestamp;
  const s = await readVault();
  const ready = now >= s.lastRebalance + s.interval;
  const why = await vaultNeedsRebalance(s);
  log(`vault depeg=${s.depeg} ticks, ready=${ready}, reason=${why ?? "none"}`);
  if (ready && why) await send(VAULT, vaultAbi, why);

  if (STRATEGY) {
    const last = (await pub.readContract({ address: STRATEGY, abi: strategyAbi, functionName: "lastRebalance" })) as bigint;
    const interval = BigInt(
      (await pub.readContract({ address: STRATEGY, abi: strategyAbi, functionName: "minRebalanceInterval" })) as number,
    );
    if (now >= last + interval) await send(STRATEGY, strategyAbi, "scheduled");
  }
}

async function main() {
  log(`keeper ${account.address} on chain ${chain.id}, vault ${VAULT}`);
  for (;;) {
    try {
      await tick();
    } catch (e) {
      log("error", (e as Error).message);
    }
    if (once) return;
    await new Promise((r) => setTimeout(r, POLL));
  }
}

main();
