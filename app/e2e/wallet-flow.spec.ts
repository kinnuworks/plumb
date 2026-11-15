import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test, type Page } from "@playwright/test";
import { createPublicClient, createWalletClient, defineChain, http, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

// A real wallet flow on Mezo testnet: connect, approve, deposit, withdraw. The browser gets a
// minimal injected wallet that signs with a throwaway testnet key (app/.env.e2e, gitignored)
// and sends real transactions. Nothing is mocked; every step waits for a mined receipt.

const env = Object.fromEntries(
  readFileSync(join(process.cwd(), ".env.e2e"), "utf8")
    .split("\n")
    .filter((l) => l.includes("="))
    .map((l) => l.split("=") as [string, string]),
);
const testnet = defineChain({
  id: 31611,
  name: "Mezo Testnet",
  nativeCurrency: { name: "Bitcoin", symbol: "BTC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.test.mezo.org"] } },
});
const account = privateKeyToAccount(env.E2E_PRIVATE_KEY as Hex);
const pub = createPublicClient({ chain: testnet, transport: http() });
const wallet = createWalletClient({ chain: testnet, transport: http(), account });

async function injectWallet(page: Page) {
  await page.exposeFunction("__e2eRpc", async (method: string, params: unknown[]) => {
    switch (method) {
      case "eth_requestAccounts":
      case "eth_accounts":
        return [account.address];
      case "eth_chainId":
        return "0x" + testnet.id.toString(16);
      case "net_version":
        return String(testnet.id);
      case "wallet_switchEthereumChain":
      case "wallet_addEthereumChain":
      case "wallet_requestPermissions":
        return null;
      case "eth_sendTransaction": {
        const tx = params[0] as { to: Hex; data?: Hex; value?: Hex; gas?: Hex };
        return wallet.sendTransaction({
          to: tx.to,
          data: tx.data,
          value: tx.value ? BigInt(tx.value) : undefined,
          gas: tx.gas ? BigInt(tx.gas) : undefined,
        });
      }
      default:
        return pub.request({ method: method as never, params: params as never });
    }
  });
  await page.addInitScript(() => {
    const w = window as unknown as {
      ethereum: unknown;
      __e2eRpc: (m: string, p: unknown[]) => Promise<unknown>;
    };
    w.ethereum = {
      isMetaMask: true,
      request: ({ method, params }: { method: string; params?: unknown[] }) => w.__e2eRpc(method, params ?? []),
      on: () => {},
      removeListener: () => {},
    };
  });
}

/** Clicks a button that sends a transaction and waits until that new transaction is mined. */
async function clickAndConfirm(page: Page, name: string) {
  const link = page.locator("a[href*='/tx/']");
  const before = (await link.count()) ? await link.first().getAttribute("href") : null;
  await page.getByRole("button", { name }).click();
  await expect(link.first()).not.toHaveAttribute("href", before ?? "none", { timeout: 60_000 });
  await expect(page.getByText("Confirmed:")).toBeVisible({ timeout: 120_000 });
  const href = (await link.first().getAttribute("href")) ?? "";
  const hash = href.split("/tx/")[1] as Hex;
  // Mezo's testnet RPC sometimes answers "not found" for a mined transaction; ask again.
  let receipt: Awaited<ReturnType<typeof pub.getTransactionReceipt>> | undefined;
  for (let i = 0; i < 60 && !receipt; i++) {
    receipt = await pub.getTransactionReceipt({ hash }).catch(() => undefined);
    if (!receipt) await new Promise((r) => setTimeout(r, 3000));
  }
  if (!receipt) throw new Error(`${name} transaction ${hash}: no receipt after 3 minutes`);
  expect(receipt.status, `${name} transaction ${hash}`).toBe("success");
  console.log(`${name}: ${hash}`);
}

test("a wallet deposits into the testnet vault and withdraws in kind", async ({ page }) => {
  test.setTimeout(300_000);
  const btc = await pub.getBalance({ address: account.address });
  expect(btc, "the throwaway testnet wallet needs gas").toBeGreaterThan(10n ** 14n);

  await injectWallet(page);
  await page.goto("/plumb/vault/");
  await expect(page.getByRole("tab", { name: /Mezo testnet/ })).toHaveAttribute("aria-selected", "true");
  await page.getByRole("button", { name: "Connect wallet" }).click();
  await expect(page.getByText(/Your share value/)).toBeVisible({ timeout: 30_000 });

  await page.getByLabel("mUSDC to deposit").fill("20");
  if (await page.getByRole("button", { name: "Approve" }).isVisible()) await clickAndConfirm(page, "Approve");
  // The Deposit button replaces Approve once the new allowance has been read back.
  await expect(page.getByRole("button", { name: "Deposit" })).toBeVisible({ timeout: 60_000 });
  await clickAndConfirm(page, "Deposit");
  const share = page.locator("div", { hasText: /^Your share value/ }).last();
  await expect(share).not.toContainText("$0.00", { timeout: 60_000 });
  await page.waitForTimeout(1500);

  await clickAndConfirm(page, "Withdraw everything");
  await expect(share).toContainText("$0.00", { timeout: 60_000 });
  await page.waitForTimeout(1500);
});
