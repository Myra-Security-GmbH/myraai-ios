/**
 * clientContext.ts — collect a snapshot of browser-side diagnostic context
 * to attach to feedback / content-report submissions.
 *
 * Schema is mirrored on the server in src/utils/feedback_context.lua. Bump
 * SCHEMA_VERSION when adding fields and update MAX_SCHEMA_VERSION there.
 *
 * Layer 2 (native bridge fields like battery, disk, carrier) is added via
 * collectWithBridge() which awaits a callback from window.Android.* / iOS
 * message handlers. When the bridge isn't present (web browser), Layer 2
 * fields are simply absent — never null — so the server's _unknown
 * quarantine and the admin UI's "—" rendering both work cleanly.
 */

declare global {
  interface Window {
    __myraAppStart?: number;
  }
}

export const SCHEMA_VERSION = 1;

export interface ClientContext {
  schema_version: number;
  submitted_at:   string;
  app_version?:   string;
  app_type:       "iOS" | "Android" | "Web";
  uptime_sec:     number;
  timezone:       string;
  locale:         string;
  user_agent:     string;
  platform:       string;
  online:         boolean;
  connection?:    string;
  save_data?:     boolean;
  color_scheme:   "light" | "dark";
  reduced_motion: boolean;
  screen:         { w: number; h: number; dpr: number };
  viewport:       { w: number; h: number };
  current_route:  string;
  referrer?:      string;

  // Layer 2 — populated by the native bridge when present.
  device_model_raw?: string;
  os_version?:       string;
  device_arch?:      string;
  battery_pct?:      number;
  battery_charging?: boolean;
  disk_free_bytes?:  number;
  disk_total_bytes?: number;
  connection_type?:  string;
  carrier?:          string;
  uptime_app_sec?:   number;
}

interface NavigatorConnectionLike {
  effectiveType?: string;
  type?:          string;
  saveData?:      boolean;
}

function detectAppType(): { type: ClientContext["app_type"]; version: string | undefined } {
  const m = navigator.userAgent.match(/MYRAai-(Android|iOS)\/([\d.]+)(?:\s+\((\d+)\))?/);
  if (m) {
    const platform = (m[1] === "iOS" ? "iOS" : "Android") as "iOS" | "Android";
    const version = m[3] ? `${m[2]} (${m[3]})` : m[2];
    return { type: platform, version };
  }
  return { type: "Web", version: undefined };
}

/** Synchronous Layer 1 collection — works in any browser/WebView. */
export function collect(): ClientContext {
  const conn = (navigator as Navigator & { connection?: NavigatorConnectionLike }).connection;
  const { type: appType, version: appVersion } = detectAppType();
  const ua = navigator as Navigator & { userAgentData?: { platform?: string } };

  const startMs = window.__myraAppStart ?? performance.now();
  const uptimeSec = Math.max(0, Math.round((performance.now() - startMs) / 1000));

  const out: ClientContext = {
    schema_version: SCHEMA_VERSION,
    submitted_at:   new Date().toISOString(),
    app_type:       appType,
    uptime_sec:     uptimeSec,
    timezone:       (() => { try { return Intl.DateTimeFormat().resolvedOptions().timeZone; } catch { return "UTC"; } })(),
    locale:         navigator.language,
    user_agent:     navigator.userAgent,
    platform:       ua.userAgentData?.platform ?? navigator.platform ?? "",
    online:         navigator.onLine,
    color_scheme:   matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light",
    reduced_motion: matchMedia("(prefers-reduced-motion)").matches,
    screen:         { w: screen.width, h: screen.height, dpr: window.devicePixelRatio },
    viewport:       { w: window.innerWidth, h: window.innerHeight },
    current_route:  window.location.pathname + window.location.search,
  };
  if (appVersion)        out.app_version = appVersion;
  if (conn?.effectiveType ?? conn?.type) out.connection = conn?.effectiveType ?? conn?.type;
  if (typeof conn?.saveData === "boolean") out.save_data = conn.saveData;
  if (document.referrer)  out.referrer = document.referrer;
  return out;
}

/**
 * Layer 1 + Layer 2 — when the native bridge is present, also includes
 * battery / disk / connection / device fields. Gracefully resolves with
 * Layer 1 only if the bridge is missing, throws, or doesn't respond
 * within 1 s.
 */
export function collectWithBridge(timeoutMs = 1000): Promise<ClientContext> {
  const layer1 = collect();
  const bridge = window.Android?.getDeviceContext;
  if (typeof bridge !== "function") return Promise.resolve(layer1);

  return new Promise((resolve) => {
    const cb = "__myraOnDeviceContext_" + Date.now() + "_" + Math.random().toString(36).slice(2);
    let settled = false;
    const finish = (extra?: Partial<ClientContext>) => {
      if (settled) return;
      settled = true;
      try { delete (window as unknown as Record<string, unknown>)[cb]; } catch { /* ignore */ }
      resolve({ ...layer1, ...(extra ?? {}) });
    };
    (window as unknown as Record<string, (v: Partial<ClientContext>) => void>)[cb] =
      (v) => finish(v);
    try {
      bridge(cb);
    } catch {
      finish();
      return;
    }
    setTimeout(() => finish(), timeoutMs);
  });
}
