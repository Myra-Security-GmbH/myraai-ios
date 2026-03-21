/** Format an ISO 8601 string as a local date (YYYY-MM-DD). */
export function fmtDate(iso: string | null | undefined): string {
  if (!iso) return "";
  return new Date(iso).toLocaleDateString();
}

/** Format an ISO 8601 string as a local date+time. */
export function fmtDateTime(iso: string | null | undefined): string {
  if (!iso) return "";
  return new Date(iso).toLocaleString();
}

/** Format a Date object as a local time string. */
export function fmtTime(date: Date | null | undefined): string {
  if (!date) return "";
  return date.toLocaleTimeString();
}
