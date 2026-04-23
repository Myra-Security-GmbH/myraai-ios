/** Format a Unix-seconds timestamp or ISO string as a local date (YYYY-MM-DD).
 *  Accepts number (Unix seconds) or string (ISO 8601) for backward compatibility. */
export function fmtDate(ts: number | string | null | undefined): string {
  if (ts == null || ts === "" || ts === 0) return "";
  const d = typeof ts === "number" ? new Date(ts * 1000) : new Date(ts);
  return d.toLocaleDateString();
}

/** Format a Unix-seconds timestamp or ISO string as a local date+time.
 *  Accepts number (Unix seconds) or string (ISO 8601) for backward compatibility. */
export function fmtDateTime(ts: number | string | null | undefined): string {
  if (ts == null || ts === "" || ts === 0) return "";
  const d = typeof ts === "number" ? new Date(ts * 1000) : new Date(ts);
  return d.toLocaleString();
}

/** Format a Date object as a local time string. */
export function fmtTime(date: Date | null | undefined): string {
  if (!date) return "";
  return date.toLocaleTimeString();
}
