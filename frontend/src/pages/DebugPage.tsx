/**
 * DebugPage — mobile layout diagnostics
 *
 * Accessible at /debug (no auth required).
 * Shows every browser property that affects mobile CSS, plus a derived
 * analysis section, so we can understand exactly what the device reports
 * without needing DevTools.
 */

import { useEffect, useState } from "react";

interface Info {
  // Viewport
  innerWidth: number;
  innerHeight: number;
  outerWidth: number;
  outerHeight: number;
  devicePixelRatio: number;
  // Screen (physical / OS pixels)
  screenWidth: number;
  screenHeight: number;
  screenAvailWidth: number;
  // Document layout (what CSS layout uses)
  docClientWidth: number;
  docClientHeight: number;
  // Meta viewport tag (actual DOM value, after any JS fix)
  metaViewport: string;
  // visualViewport
  vvWidth: number;
  vvHeight: number;
  vvScale: number;
  vvOffsetTop: number;
  // Touch
  maxTouchPoints: number;
  ontouchstart: boolean;
  // Media queries — pointer type
  mq_pointer_coarse: boolean;
  mq_pointer_fine: boolean;
  mq_pointer_none: boolean;
  mq_any_pointer_coarse: boolean;
  mq_hover_none: boolean;
  mq_any_hover_none: boolean;
  // Media queries — width breakpoints
  mq_max640: boolean;
  mq_max979: boolean;
  mq_max1023: boolean;
  mq_max1024: boolean;
  mq_max1366: boolean;
  // Compound queries — the exact conditions used in Chat/Sidebar CSS
  mq_coarse_AND_max979: boolean;   // current mobile CSS threshold
  mq_coarse_AND_max1023: boolean;  // alternative threshold (reference)
  mq_coarse_OR_max1366: boolean;   // old broken OR condition
  // CSS
  htmlFontSize: string;
  bodyFontSize: string;
  // UA
  userAgent: string;
  platform: string;
  // Misc
  dvhSupport: boolean;
  standalone: boolean;
}

function collect(): Info {
  const vv = window.visualViewport;
  const mq = (q: string) => window.matchMedia(q).matches;
  const meta = document.querySelector('meta[name="viewport"]');
  return {
    innerWidth:        window.innerWidth,
    innerHeight:       window.innerHeight,
    outerWidth:        window.outerWidth,
    outerHeight:       window.outerHeight,
    devicePixelRatio:  window.devicePixelRatio,
    screenWidth:       window.screen.width,
    screenHeight:      window.screen.height,
    screenAvailWidth:  window.screen.availWidth,
    docClientWidth:    document.documentElement.clientWidth,
    docClientHeight:   document.documentElement.clientHeight,
    metaViewport:      meta?.getAttribute("content") ?? "(not found)",
    vvWidth:           vv?.width ?? -1,
    vvHeight:          vv?.height ?? -1,
    vvScale:           vv?.scale ?? -1,
    vvOffsetTop:       vv?.offsetTop ?? -1,
    maxTouchPoints:    navigator.maxTouchPoints,
    ontouchstart:      "ontouchstart" in window,
    mq_pointer_coarse:    mq("(pointer: coarse)"),
    mq_pointer_fine:      mq("(pointer: fine)"),
    mq_pointer_none:      mq("(pointer: none)"),
    mq_any_pointer_coarse: mq("(any-pointer: coarse)"),
    mq_hover_none:        mq("(hover: none)"),
    mq_any_hover_none:    mq("(any-hover: none)"),
    mq_max640:         mq("(max-width: 640px)"),
    mq_max979:         mq("(max-width: 979px)"),
    mq_max1023:        mq("(max-width: 1023px)"),
    mq_max1024:        mq("(max-width: 1024px)"),
    mq_max1366:        mq("(max-width: 1366px)"),
    mq_coarse_AND_max979:  mq("(pointer: coarse) and (max-width: 979px)"),
    mq_coarse_AND_max1023: mq("(pointer: coarse) and (max-width: 1023px)"),
    mq_coarse_OR_max1366:  mq("(pointer: coarse), (max-width: 1366px)"),
    htmlFontSize:  getComputedStyle(document.documentElement).fontSize,
    bodyFontSize:  getComputedStyle(document.body).fontSize,
    userAgent:     navigator.userAgent,
    platform:      navigator.platform,
    dvhSupport:    CSS.supports("height", "100dvh"),
    standalone:    (window.navigator as { standalone?: boolean }).standalone === true ||
                   window.matchMedia("(display-mode: standalone)").matches,
  };
}

// Derived analysis from raw values
function analyze(i: Info) {
  const isDesktopMode =
    i.outerWidth > 0 && i.innerWidth > i.outerWidth * 1.5 && i.outerWidth < 600;
  const effectiveVisualWidth =
    i.vvWidth > 0 ? Math.round(i.vvWidth) : Math.round(i.innerWidth * Math.max(i.vvScale, 1));
  const scalePct =
    i.vvScale > 0 ? Math.round(i.vvScale * 100) : 100;
  const jsfixFired =
    i.outerWidth > 0 && i.metaViewport.includes(`width=${i.outerWidth}`);
  const mobileCSSActive = i.mq_coarse_AND_max979;
  const compactLabelsActive = i.mq_max640;
  const pointerTypeMatch = i.mq_pointer_coarse;

  return {
    isDesktopMode,
    effectiveVisualWidth,
    scalePct,
    jsfixFired,
    mobileCSSActive,
    compactLabelsActive,
    pointerTypeMatch,
  };
}

type Severity = "ok" | "warn" | "error" | "info";

function badge(sev: Severity, text: string) {
  const colors: Record<Severity, { bg: string; text: string }> = {
    ok:    { bg: "#d1fae5", text: "#065f46" },
    warn:  { bg: "#fef3c7", text: "#92400e" },
    error: { bg: "#fee2e2", text: "#991b1b" },
    info:  { bg: "#e0f2fe", text: "#0369a1" },
  };
  const c = colors[sev];
  return (
    <span style={{
      display: "inline-block",
      padding: "2px 8px",
      borderRadius: "4px",
      fontWeight: 700,
      fontSize: "13px",
      background: c.bg,
      color: c.text,
    }}>
      {text}
    </span>
  );
}

export default function DebugPage() {
  const [info, setInfo] = useState<Info>(collect);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    const update = () => setInfo(collect());
    window.addEventListener("resize", update);
    window.visualViewport?.addEventListener("resize", update);
    window.visualViewport?.addEventListener("scroll", update);
    return () => {
      window.removeEventListener("resize", update);
      window.visualViewport?.removeEventListener("resize", update);
      window.visualViewport?.removeEventListener("scroll", update);
    };
  }, []);

  function copyAll() {
    const text = JSON.stringify(info, null, 2);
    navigator.clipboard.writeText(text).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  }

  const a = analyze(info);

  const row = (label: string, value: unknown, warn?: boolean) => (
    <tr key={label} style={{ background: warn ? "#fee2e2" : undefined }}>
      <td style={{ padding: "6px 12px", fontWeight: 600, whiteSpace: "nowrap", color: "#374151", borderBottom: "1px solid #e5e7eb" }}>{label}</td>
      <td style={{ padding: "6px 12px", fontFamily: "monospace", borderBottom: "1px solid #e5e7eb", wordBreak: "break-all" }}>
        {String(value)}
      </td>
    </tr>
  );

  const sectionHeader = (label: string) => (
    <tr>
      <td colSpan={2} style={{ padding: "8px 12px", fontWeight: 700, background: "#f0f9ff", borderBottom: "1px solid #e5e7eb" }}>
        {label}
      </td>
    </tr>
  );

  return (
    <div style={{ padding: "16px", maxWidth: "100%", boxSizing: "border-box", fontFamily: "system-ui, sans-serif", fontSize: "15px" }}>
      <div style={{ display: "flex", alignItems: "center", gap: "12px", marginBottom: "16px" }}>
        <h1 style={{ margin: 0, fontSize: "20px" }}>Layout Debug</h1>
        <button
          onClick={copyAll}
          style={{ padding: "6px 14px", background: "#0052cc", color: "#fff", border: "none", borderRadius: "6px", cursor: "pointer", fontSize: "14px" }}
        >
          {copied ? "Copied!" : "Copy JSON"}
        </button>
      </div>

      {/* ── Analysis ──────────────────────────────────────────────────────── */}
      <div style={{ marginBottom: "20px", border: "1px solid #e5e7eb", borderRadius: "8px", overflow: "hidden" }}>
        <div style={{ padding: "10px 14px", fontWeight: 700, background: "#1e3a5f", color: "#fff", fontSize: "14px" }}>
          Analysis
        </div>
        <table style={{ width: "100%", borderCollapse: "collapse", fontSize: "14px" }}>
          <tbody>
            <tr>
              <td style={{ padding: "8px 14px", fontWeight: 600, borderBottom: "1px solid #e5e7eb", whiteSpace: "nowrap" }}>Layout viewport width</td>
              <td style={{ padding: "8px 14px", borderBottom: "1px solid #e5e7eb", fontFamily: "monospace" }}>{info.innerWidth} px</td>
            </tr>
            <tr>
              <td style={{ padding: "8px 14px", fontWeight: 600, borderBottom: "1px solid #e5e7eb", whiteSpace: "nowrap" }}>Visual width (what you see)</td>
              <td style={{ padding: "8px 14px", borderBottom: "1px solid #e5e7eb", fontFamily: "monospace" }}>{a.effectiveVisualWidth} px</td>
            </tr>
            <tr>
              <td style={{ padding: "8px 14px", fontWeight: 600, borderBottom: "1px solid #e5e7eb", whiteSpace: "nowrap" }}>Browser zoom / scale</td>
              <td style={{ padding: "8px 14px", borderBottom: "1px solid #e5e7eb", fontFamily: "monospace" }}>{a.scalePct} %</td>
            </tr>
            <tr style={{ background: a.isDesktopMode ? "#fef3c7" : undefined }}>
              <td style={{ padding: "8px 14px", fontWeight: 600, borderBottom: "1px solid #e5e7eb", whiteSpace: "nowrap" }}>Desktop mode detected?</td>
              <td style={{ padding: "8px 14px", borderBottom: "1px solid #e5e7eb" }}>
                {a.isDesktopMode
                  ? badge("warn", `YES — innerWidth (${info.innerWidth}) >> outerWidth (${info.outerWidth})`)
                  : badge("ok", "no")}
              </td>
            </tr>
            <tr style={{ background: !a.pointerTypeMatch && info.maxTouchPoints > 0 ? "#fee2e2" : undefined }}>
              <td style={{ padding: "8px 14px", fontWeight: 600, borderBottom: "1px solid #e5e7eb", whiteSpace: "nowrap" }}>pointer: coarse?</td>
              <td style={{ padding: "8px 14px", borderBottom: "1px solid #e5e7eb" }}>
                {a.pointerTypeMatch
                  ? badge("ok", "YES")
                  : info.maxTouchPoints > 0
                    ? badge("error", "NO — touch device but pointer:coarse=false; mobile CSS won't fire")
                    : badge("info", "no (non-touch device)")}
              </td>
            </tr>
            <tr style={{ background: !a.mobileCSSActive && info.maxTouchPoints > 0 ? "#fee2e2" : undefined }}>
              <td style={{ padding: "8px 14px", fontWeight: 600, borderBottom: "1px solid #e5e7eb", whiteSpace: "nowrap" }}>Mobile CSS active?<br /><span style={{ fontWeight: 400, fontSize: "12px", color: "#6b7280" }}>(pointer:coarse AND max-width:979px)</span></td>
              <td style={{ padding: "8px 14px", borderBottom: "1px solid #e5e7eb" }}>
                {a.mobileCSSActive
                  ? badge("ok", "YES — compact config bar, sidebar drawer, hamburger clearance")
                  : info.innerWidth > 979
                    ? badge("warn", `NO — innerWidth (${info.innerWidth}) > 979 px threshold`)
                    : badge("info", "no")}
              </td>
            </tr>
            <tr>
              <td style={{ padding: "8px 14px", fontWeight: 600, borderBottom: "1px solid #e5e7eb", whiteSpace: "nowrap" }}>Compact labels active?<br /><span style={{ fontWeight: 400, fontSize: "12px", color: "#6b7280" }}>(max-width:640px)</span></td>
              <td style={{ padding: "8px 14px", borderBottom: "1px solid #e5e7eb" }}>
                {a.compactLabelsActive
                  ? badge("ok", "YES — Tenant/Gateway/Model labels hidden")
                  : badge("info", `NO — innerWidth (${info.innerWidth}) > 640 px, labels shown`)}
              </td>
            </tr>
            <tr style={{ background: a.isDesktopMode && !a.jsfixFired ? "#fef3c7" : undefined }}>
              <td style={{ padding: "8px 14px", fontWeight: 600, borderBottom: "1px solid #e5e7eb", whiteSpace: "nowrap" }}>JS viewport fix fired?</td>
              <td style={{ padding: "8px 14px", borderBottom: "1px solid #e5e7eb" }}>
                {a.jsfixFired
                  ? badge("ok", `YES — meta viewport set to width=${info.outerWidth}`)
                  : a.isDesktopMode
                    ? badge("warn", "NO — desktop mode detected but fix did not change the tag (Chrome likely ignores it)")
                    : badge("info", "no (not in desktop mode)")}
              </td>
            </tr>
            <tr>
              <td style={{ padding: "8px 14px", fontWeight: 600, whiteSpace: "nowrap" }}>Root font size</td>
              <td style={{ padding: "8px 14px", fontFamily: "monospace" }}>{info.htmlFontSize}</td>
            </tr>
          </tbody>
        </table>
      </div>

      {/* ── Raw data table ─────────────────────────────────────────────────── */}
      <table style={{ width: "100%", borderCollapse: "collapse", fontSize: "14px" }}>
        <thead>
          <tr style={{ background: "#f9fafb" }}>
            <th style={{ padding: "8px 12px", textAlign: "left", borderBottom: "2px solid #e5e7eb" }}>Property</th>
            <th style={{ padding: "8px 12px", textAlign: "left", borderBottom: "2px solid #e5e7eb" }}>Value</th>
          </tr>
        </thead>
        <tbody>
          {sectionHeader("Viewport (layout — what CSS uses)")}
          {row("window.innerWidth",       info.innerWidth)}
          {row("window.innerHeight",      info.innerHeight)}
          {row("window.outerWidth",       info.outerWidth)}
          {row("window.outerHeight",      info.outerHeight)}
          {row("devicePixelRatio",        info.devicePixelRatio)}
          {row("document.clientWidth",    info.docClientWidth)}
          {row("document.clientHeight",   info.docClientHeight)}
          {row("meta[name=viewport]",     info.metaViewport)}

          {sectionHeader("Screen (physical / OS pixels)")}
          {row("screen.width",            info.screenWidth)}
          {row("screen.height",           info.screenHeight)}
          {row("screen.availWidth",       info.screenAvailWidth)}

          {sectionHeader("visualViewport (visible portion after pinch/scale)")}
          {row("vv.width",                info.vvWidth)}
          {row("vv.height",               info.vvHeight)}
          {row("vv.scale",                info.vvScale)}
          {row("vv.offsetTop",            info.vvOffsetTop)}

          {sectionHeader("Touch detection")}
          {row("navigator.maxTouchPoints", info.maxTouchPoints, info.maxTouchPoints === 0 && info.ontouchstart)}
          {row("'ontouchstart' in window",  info.ontouchstart)}

          {sectionHeader("Media queries — pointer / hover")}
          {row("(pointer: coarse)",         info.mq_pointer_coarse,  !info.mq_pointer_coarse && info.maxTouchPoints > 0)}
          {row("(pointer: fine)",           info.mq_pointer_fine)}
          {row("(pointer: none)",           info.mq_pointer_none)}
          {row("(any-pointer: coarse)",     info.mq_any_pointer_coarse)}
          {row("(hover: none)",             info.mq_hover_none)}
          {row("(any-hover: none)",         info.mq_any_hover_none)}

          {sectionHeader("Media queries — width")}
          {row("(max-width: 640px)",        info.mq_max640)}
          {row("(max-width: 979px)",        info.mq_max979)}
          {row("(max-width: 1023px)",       info.mq_max1023)}
          {row("(max-width: 1024px)",       info.mq_max1024)}
          {row("(max-width: 1366px)",       info.mq_max1366)}

          {sectionHeader("Compound queries — exact CSS conditions used in this app")}
          {row("(pointer:coarse) AND (max-width:979px)  ← current mobile CSS",  info.mq_coarse_AND_max979)}
          {row("(pointer:coarse) AND (max-width:1023px) ← alternative",         info.mq_coarse_AND_max1023)}
          {row("(pointer:coarse) OR  (max-width:1366px) ← old broken OR",       info.mq_coarse_OR_max1366)}

          {sectionHeader("Misc")}
          {row("HTML font-size (computed)", info.htmlFontSize)}
          {row("Body font-size (computed)", info.bodyFontSize)}
          {row("CSS.supports 100dvh",       info.dvhSupport)}
          {row("Standalone / PWA",          info.standalone)}
          {row("navigator.platform",        info.platform)}
          {row("navigator.userAgent",       info.userAgent)}
        </tbody>
      </table>
    </div>
  );
}
