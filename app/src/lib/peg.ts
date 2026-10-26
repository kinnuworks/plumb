/**
 * Price helpers for the MUSD/mUSDC pool on Mezo mainnet, where mUSDC (6 decimals) is token0 and
 * MUSD (18 decimals) is token1. The pool price is raw MUSD per raw mUSDC.
 */

const DECIMALS_GAP = 12;

/** USD price of one MUSD at a pool tick. */
export function musdPriceAtTick(tick: number): number {
  const rawMusdPerUsd = Math.pow(1.0001, tick);
  return Math.pow(10, DECIMALS_GAP) / rawMusdPerUsd;
}

/** Tick where 1 MUSD = 1 USD. */
export const PAR_TICK = Math.log(Math.pow(10, DECIMALS_GAP)) / Math.log(1.0001);

/** Basis points MUSD trades below $1 (negative above $1). */
export function depegBps(tick: number): number {
  return (1 - musdPriceAtTick(tick)) * 10_000;
}

export function fmtUsd(n: number, digits = 0): string {
  return n.toLocaleString("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: digits,
    minimumFractionDigits: digits,
  });
}

export function fmtNum(n: number, digits = 0): string {
  return n.toLocaleString("en-US", { maximumFractionDigits: digits, minimumFractionDigits: digits });
}

export function fmtCompact(n: number): string {
  return n.toLocaleString("en-US", { notation: "compact", maximumFractionDigits: 2 });
}
