import { expect, test } from "@playwright/test";

const dollars = (s: string) => Number(s.replace(/[^0-9.]/g, ""));

test("first screen shows what selling MUSD pays this block, with no wallet", async ({ page }) => {
  await page.goto("/plumb/");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("A standing bid under MUSD");
  const panel = page.getByTestId("live-depth");
  await expect(panel).toBeVisible({ timeout: 45_000 });
  await expect(panel).toContainText("Live from Mezo mainnet, block");

  // The 100k row: a real quote from the real pool, priced near $1 while the book holds.
  const row = page.getByTestId("quote-100000");
  const cells = await row.locator("td").allInnerTexts();
  expect(cells[0]).toBe("100,000 MUSD");
  expect(dollars(cells[1])).toBeGreaterThan(1_000);
  const avg = dollars(cells[2]);
  expect(avg).toBeGreaterThan(0);
  expect(avg).toBeLessThanOrEqual(1.01);
  await page.waitForTimeout(1500);
});

test("vault page reads the live testnet vault: band, bid and total value", async ({ page }) => {
  await page.goto("/plumb/vault/");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("Plumb vault");
  const total = page.locator("div", { hasText: /^Total value/ }).last();
  await expect(total).not.toContainText("–", { timeout: 45_000 });
  await expect(page.getByText("At today's price (earns MEZO)")).toBeVisible();
  const band = page.locator("div", { hasText: /^At today's price \(earns MEZO\)/ }).last();
  await expect(band).toContainText("MUSD", { timeout: 45_000 });
  await page.waitForTimeout(1500);
});
