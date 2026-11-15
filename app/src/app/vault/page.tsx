"use client";

import { useEffect, useState } from "react";
import { erc20Abi, formatUnits, parseUnits, zeroAddress } from "viem";
import {
  useAccount,
  useConnect,
  useDisconnect,
  useReadContract,
  useReadContracts,
  useSwitchChain,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";
import vaultAbi from "@/abi/PlumbBidVault.json";
import { PLUMB_MAINNET, PLUMB_TESTNET } from "@/lib/addresses";
import { mezo, mezoTestnet } from "@/lib/chains";
import { fmtNum } from "@/lib/peg";

const USD_DECIMALS = 6;
const NETWORKS = {
  mainnet: { label: "Mezo mainnet", chain: mezo, vault: PLUMB_MAINNET.vault, usd: PLUMB_MAINNET.usd },
  testnet: { label: "Mezo testnet", chain: mezoTestnet, vault: PLUMB_TESTNET.vault, usd: PLUMB_TESTNET.usd },
} as const;
type Net = keyof typeof NETWORKS;
const MAINNET_LIVE = PLUMB_MAINNET.vault !== zeroAddress;

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between py-1.5 border-t border-current/10 text-sm tabular-nums">
      <span className="opacity-70">{label}</span>
      <span>{value}</span>
    </div>
  );
}

export default function VaultPage() {
  const [net, setNet] = useState<Net>(MAINNET_LIVE ? "mainnet" : "testnet");
  return (
    <>
      <div className="mx-auto max-w-3xl px-4 pt-6 flex gap-3 text-sm" role="tablist" aria-label="Network">
        {(Object.keys(NETWORKS) as Net[]).map((n) => (
          <button
            key={n}
            role="tab"
            aria-selected={net === n}
            className={net === n ? "font-semibold underline" : "opacity-70"}
            onClick={() => setNet(n)}
          >
            {NETWORKS[n].label}
            {n === "mainnet" && !MAINNET_LIVE ? " (not deployed yet)" : ""}
          </button>
        ))}
      </div>
      <VaultView key={net} net={net} />
    </>
  );
}

function VaultView({ net }: { net: Net }) {
  const cfg = NETWORKS[net];
  const VAULT = cfg.vault;
  const USD = cfg.usd;
  const chain = cfg.chain;
  const vault = { address: VAULT, abi: vaultAbi, chainId: chain.id } as const;
  const { address, chainId, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const [amount, setAmount] = useState("100");
  const { writeContractAsync, data: txHash, isPending } = useWriteContract();
  const receipt = useWaitForTransactionReceipt({ hash: txHash });
  const [error, setError] = useState<string | null>(null);

  const deployed = VAULT !== zeroAddress;
  const me = address ?? zeroAddress;

  const reads = useReadContracts({
    allowFailure: true,
    query: { enabled: deployed, refetchInterval: 15_000 },
    contracts: [
      { ...vault, functionName: "totalAssets" },
      { ...vault, functionName: "holdings" },
      { ...vault, functionName: "currentDepeg" },
      { ...vault, functionName: "totalSupply" },
      { ...vault, functionName: "balanceOf", args: [me] },
      { ...vault, functionName: "lastRebalance" },
      { ...vault, functionName: "minRebalanceInterval" },
      { ...vault, functionName: "floorDepeg" },
      { ...vault, functionName: "bandHoldings" },
      { ...vault, functionName: "pendingMezo", args: [me] },
    ],
  });
  const [totalAssets, holdings, depeg, supply, myShares, lastRebalance, interval, floor, band, myMezo] = (
    reads.data ?? []
  ).map((r) => r?.result) as [
    bigint?,
    (readonly bigint[])?,
    number?,
    bigint?,
    bigint?,
    bigint?,
    number?,
    number?,
    (readonly bigint[])?,
    bigint?,
  ];

  const usdBalance = useReadContract({
    address: USD,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [me],
    chainId: chain.id,
    query: { enabled: isConnected },
  });
  const allowance = useReadContract({
    address: USD,
    abi: erc20Abi,
    functionName: "allowance",
    args: [me, VAULT],
    chainId: chain.id,
    query: { enabled: isConnected && deployed },
  });

  const usd = (x?: bigint) => (x === undefined ? "–" : `$${fmtNum(Number(formatUnits(x, USD_DECIMALS)), 2)}`);
  const musd = (x?: bigint) => (x === undefined ? "–" : `${fmtNum(Number(formatUnits(x, 18)), 2)} MUSD`);
  const myValue =
    totalAssets !== undefined && supply && myShares !== undefined && supply > 0n ? (totalAssets * myShares) / supply : 0n;
  const wrongChain = isConnected && chainId !== chain.id;
  const amountWei = (() => {
    try {
      return parseUnits(amount || "0", USD_DECIMALS);
    } catch {
      return 0n;
    }
  })();
  const needsApproval = (allowance.data ?? 0n) < amountWei;
  const nextRebalance = lastRebalance !== undefined && interval !== undefined ? Number(lastRebalance) + interval : 0;
  const belowFloor = depeg !== undefined && floor !== undefined && depeg >= floor;

  // Re-read balances, allowance and vault state once the transaction is mined, not just sent:
  // otherwise Approve can stay on screen after the approval lands.
  const mined = receipt.isSuccess;
  const minedHash = receipt.data?.transactionHash;
  useEffect(() => {
    if (!mined) return;
    reads.refetch();
    usdBalance.refetch();
    allowance.refetch();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mined, minedHash]);

  async function run(fn: () => Promise<unknown>) {
    setError(null);
    try {
      await fn();
      await Promise.all([reads.refetch(), usdBalance.refetch(), allowance.refetch()]);
    } catch (e) {
      setError(e instanceof Error ? e.message.split("\n")[0] : String(e));
    }
  }

  return (
    <main className="mx-auto max-w-3xl px-4 py-10 space-y-8">
      <header className="space-y-2">
        <h1 className="text-3xl font-semibold">Plumb vault</h1>
        <p className="opacity-80">
          You deposit mUSDC. Half of it buys and sells MUSD right at today&apos;s price, which is where the pool pays its
          MEZO rewards. The other half waits as an order to buy MUSD if the price drops, down to about $0.98. MUSD the vault
          buys below $1 earns savings interest until it can be sold at $1 or more. Withdraw any time: you get your share of
          whatever the vault holds, mUSDC and MUSD.
        </p>
      </header>

      {!deployed && (
        <p className="rounded-lg border border-current/20 p-4 text-sm">
          This network&apos;s vault is not deployed yet.
        </p>
      )}

      <section className="rounded-lg border border-current/15 p-5 space-y-1">
        <h2 className="font-semibold mb-2">Vault</h2>
        <Row label="Total value" value={usd(totalAssets)} />
        <Row label="MUSD price (TWAP)" value={depeg === undefined ? "–" : `$${(1 - depeg / 10_000).toFixed(4)}`} />
        <Row label="At today's price (earns MEZO)" value={band ? `${usd(band[0])} + ${musd(band[1])}` : "–"} />
        <Row label="Waiting to buy MUSD below the price" value={usd(holdings?.[3])} />
        <Row label="New deposits, placed at the next rebalance" value={usd(holdings?.[0])} />
        <Row label="MUSD bought below $1, earning in sMUSD" value={musd(holdings ? holdings[1] + holdings[2] + holdings[4] : undefined)} />
        <Row label="MUSD offered at $1 or more" value={musd(holdings?.[6])} />
        {belowFloor && <p className="text-sm pt-2">MUSD is below the floor price. Bids and deposits are paused.</p>}
      </section>

      <section className="rounded-lg border border-current/15 p-5 space-y-4">
        <div className="flex items-center justify-between">
          <h2 className="font-semibold">Your position</h2>
          {isConnected ? (
            <button className="text-sm underline" onClick={() => disconnect()}>
              {address?.slice(0, 6)}…{address?.slice(-4)} · disconnect
            </button>
          ) : (
            <button
              className="rounded-md bg-current/90 px-3 py-1.5 text-sm"
              onClick={() => connect({ connector: connectors[0], chainId: chain.id })}
            >
              <span className="text-[var(--background)]">Connect wallet</span>
            </button>
          )}
        </div>

        {wrongChain && (
          <button className="underline text-sm" onClick={() => switchChain({ chainId: chain.id })}>
            Switch to {cfg.label}
          </button>
        )}

        {isConnected && !wrongChain && (
          <>
            <Row label="Your share value" value={usd(myValue)} />
            <Row label="Your mUSDC" value={usd(usdBalance.data)} />
            <Row
              label="MEZO earned, ready to claim"
              value={myMezo === undefined ? "–" : `${fmtNum(Number(formatUnits(myMezo, 18)), 2)} MEZO`}
            />
            {net === "testnet" && (
              <p className="text-xs opacity-70">
                Mezo testnet has no gauge for this pool, so testnet deposits earn no MEZO. Gauge rewards are paid on mainnet;
                the fork tests measure them against mainnet&apos;s real gauge.
              </p>
            )}

            <div className="flex gap-2 pt-2">
              <input
                className="flex-1 rounded-md border border-current/20 bg-transparent px-3 py-2 tabular-nums"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                inputMode="decimal"
                aria-label="mUSDC to deposit"
              />
              {needsApproval ? (
                <button
                  className="rounded-md border border-current/30 px-4"
                  disabled={isPending || amountWei === 0n}
                  onClick={() =>
                    run(() =>
                      writeContractAsync({ address: USD, abi: erc20Abi, functionName: "approve", args: [VAULT, amountWei] }),
                    )
                  }
                >
                  Approve
                </button>
              ) : (
                <button
                  className="rounded-md border border-current/30 px-4"
                  disabled={isPending || amountWei === 0n || belowFloor}
                  onClick={() =>
                    run(() =>
                      writeContractAsync({ ...vault, functionName: "depositAndDeploy", args: [amountWei, 0n, address!] }),
                    )
                  }
                >
                  Deposit
                </button>
              )}
            </div>

            <p className="text-xs opacity-70">
              {needsApproval
                ? "Step 1 of 2: approve lets the vault take this much mUSDC from your wallet. Then deposit."
                : "Step 2 of 2: deposit. Each new deposit amount needs its own approval first."}
            </p>

            <div className="flex flex-wrap gap-2">
              <button
                className="rounded-md border border-current/30 px-4 py-2 text-sm"
                disabled={isPending || !myShares}
                onClick={() =>
                  run(() => writeContractAsync({ ...vault, functionName: "redeem", args: [myShares!, 0n, 0n, address!] }))
                }
              >
                Withdraw everything
              </button>
              <button
                className="rounded-md border border-current/30 px-4 py-2 text-sm"
                disabled={isPending || Date.now() / 1000 < nextRebalance}
                onClick={() => run(() => writeContractAsync({ ...vault, functionName: "rebalance" }))}
                title="Anyone can re-centre the book. Allowed once per cooldown."
              >
                Rebalance
              </button>
            </div>
            <p className="text-xs opacity-70">
              Rebalance moves the vault&apos;s orders back to today&apos;s price. Anyone can call it once per cooldown and
              earns 1% of the MEZO it collects.
            </p>
          </>
        )}

        {txHash && (
          <p className="text-sm">
            {receipt.isLoading ? "Waiting for confirmation… " : receipt.isSuccess ? "Confirmed: " : ""}
            <a className="underline" href={`${chain.blockExplorers.default.url}/tx/${txHash}`}>
              {txHash.slice(0, 10)}…
            </a>
          </p>
        )}
        {error && <p className="text-sm text-red-600">{error}</p>}
      </section>
    </main>
  );
}
