/**
 * clientContext.ts — collect a snapshot of browser-side diagnostic context
 * to attach to feedback / content-report submissions.
 *
 * Schema is mirrored on the server in src/utils/feedback_context.lua.  Bump
 * SCHEMA_VERSION when adding fields (and update MAX_SCHEMA_VERSION there).
 *
 * The collector is JS-only: device-class info (model, OS, app version,
 * arch) rides on the User-Agent string set by the native WebView wrappers
 * and is parsed server-side, not re-sent here.  The "Layer 2" runtime
 * fields (battery + connection) come from standard browser APIs when the
 * platform exposes them — Android Chrome WebView supports both, iOS
 * WKWebView exposes neither.  Unsupported fields are silently absent
 * (never null), which the server-side validator and admin UI both render
 * cleanly.
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
  /** NetworkInformation effective type ("4g", "wifi", etc.) when supported. */
  connection?:    string;
  save_data?:     boolean;
  color_scheme:   "light" | "dark";
  reduced_motion: boolean;
  screen:         { w: number; h: number; dpr: number };
  viewport:       { w: number; h: number };
  current_route:  string;
  referrer?:      string;
  /** 0–100 — present on Android Chrome WebView only (Battery API removed from WebKit). */
  battery_pct?:      number;
  battery_charging?: boolean;
}

interface NavigatorConnectionLike {
  effectiveType?: string;
  type?:          string;
  saveData?:      boolean;
}

interface BatteryManagerLike {
  level:    number;   // 0..1
  charging: boolean;
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

/** Synchronous Layer-1 fields. */
function collectSync(): ClientContext {
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
  if (appVersion) out.app_version = appVersion;
  if (conn?.effectiveType ?? conn?.type) out.connection = conn?.effectiveType ?? conn?.type;
  if (typeof conn?.saveData === "boolean") out.save_data = conn.saveData;
  if (document.referrer) out.referrer = document.referrer;
  return out;
}

/**
 * Collect Layer-1 fields plus, where the platform supports it, battery
 * state via navigator.getBattery() (Android Chrome WebView supports it;
 * iOS WKWebView removed it for privacy).  Resolves immediately if the
 * Battery API is missing or rejects.  Bounded by a 500 ms watchdog so a
 * misbehaving promise can't block submission.
 */
export async function collect(): Promise<ClientContext> {
  const base = collectSync();

  const getBattery = (navigator as Navigator & {
    getBattery?: () => Promise<BatteryManagerLike>;
  }).getBattery;
  if (typeof getBattery !== "function") return base;

  return new Promise<ClientContext>((resolve) => {
    let settled = false;
    const finish = (extra: Partial<ClientContext>) => {
      if (settled) return;
      settled = true;
      resolve({ ...base, ...extra });
    };
    setTimeout(() => finish({}), 500);
    getBattery
      .call(navigator)
      .then((b) => finish({
        battery_pct:      Math.round(b.level * 100),
        battery_charging: b.charging,
      }))
      .catch(() => finish({}));
  });
}
