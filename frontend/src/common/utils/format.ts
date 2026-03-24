/** Shared number-formatting utilities — mirrors date.ts pattern. */

/** Integer or float with thousands separator. Returns "—" for null/undefined. */
export function fmtNumber(n: number | null | undefined, decimals = 0): string {
  if (n == null) return "—";
  return n.toLocaleString("en-US", { maximumFractionDigits: decimals });
}

/** Currency: "$1,234.50". Returns "—" for null/undefined. */
export function fmtCost(n: number | null | undefined): string {
  if (n == null) return "—";
  return "$" + n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/** Milliseconds with thousands separator: "120,000 ms". Returns "—" for null/undefined. */
export function fmtMs(n: number | null | undefined): string {
  if (n == null) return "—";
  return n.toLocaleString("en-US", { maximumFractionDigits: 0 }) + " ms";
}

/** Seconds with thousands separator: "120,000s". Returns "—" for null/undefined. */
export function fmtSec(n: number | null | undefined): string {
  if (n == null) return "—";
  return n.toLocaleString("en-US", { maximumFractionDigits: 0 }) + "s";
}
