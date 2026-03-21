const DEDUP_WINDOW_MS = 5000;
const seen = new Map<string, number>();

export function reportError(message: string, stack?: string): void {
  const key = message.slice(0, 120);
  const now = Date.now();
  const last = seen.get(key);
  if (last && now - last < DEDUP_WINDOW_MS) return;
  seen.set(key, now);

  const payload = {
    message,
    stack,
    url: window.location.href,
    user_agent: navigator.userAgent,
    ts: new Date().toISOString(),
  };

  // Fire-and-forget; swallow any network errors to avoid infinite loops
  fetch("/admin/v1/client-errors", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
    keepalive: true,
  }).catch(() => {});
}
