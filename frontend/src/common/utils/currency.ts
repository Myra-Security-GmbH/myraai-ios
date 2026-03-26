import { fmtCost } from "src/common/utils/format";

export type Currency = "USD" | "EUR";

// Module-level rate cache — avoids re-fetching within a browser session.
// frankfurter.app serves ECB data, updated each business day.
let _rateCache: { rate: number; date: string } | null = null;

export async function fetchEurRate(): Promise<number> {
  const today = new Date().toISOString().slice(0, 10);
  if (_rateCache?.date === today) return _rateCache.rate;
  const res = await fetch("https://api.frankfurter.app/latest?from=USD&to=EUR");
  const data = await res.json();
  const rate = data.rates?.EUR as number;
  _rateCache = { rate, date: today };
  return rate;
}

export function fmtCurrency(n: number | undefined | null, currency: Currency, eurRate: number): string {
  if (currency === "EUR") {
    if (n == null || n === 0) return "€0.00";
    return `€${(n * eurRate).toFixed(2)}`;
  }
  return fmtCost(n);
}
