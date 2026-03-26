/**
 * DocLink — small inline "?" link that opens a documentation page in a new tab.
 *
 * Usage:
 *   <DocLink path="/security/guardrails/" />
 *   <DocLink path="/configuration/rate-limiting/" label="rate limit docs" />
 */

const BASE = import.meta.env.VITE_DOCS_URL ?? "https://ai-docs.myra.eu";

export function docsUrl(path: string): string {
  return `${BASE}${path}`;
}

export function DocLink({ path, label = "docs" }: { path: string; label?: string }) {
  return (
    <a
      href={docsUrl(path)}
      target="_blank"
      rel="noopener noreferrer"
      title={label}
      style={{
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        width: 16,
        height: 16,
        borderRadius: "50%",
        background: "var(--text-secondary)",
        color: "var(--content-bg, #fff)",
        fontSize: 10,
        fontWeight: 700,
        lineHeight: 1,
        textDecoration: "none",
        flexShrink: 0,
        opacity: 0.6,
      }}
      onMouseEnter={(e) => (e.currentTarget.style.opacity = "1")}
      onMouseLeave={(e) => (e.currentTarget.style.opacity = "0.6")}
    >
      ?
    </a>
  );
}
