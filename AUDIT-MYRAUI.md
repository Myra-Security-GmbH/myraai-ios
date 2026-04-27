# MyraUI & Design System Audit Guide

Use this document when reviewing any `.tsx` or `.module.scss` file under `frontend/src/`.
Apply every check to every component. Report every finding with file, line, category, problem,
and fix. This is not a style guide — it is a correctness and consistency audit.

---

## What MyraUI is in this project

MyraUI provides four packages. Their roles are **fixed** — do not use them outside these roles.

| Package | Role | How imported |
|---|---|---|
| `@myraui/core` | CSS reset + baseline. Wrap the whole app once. | `import { Core } from "@myraui/core"` |
| `@myraui/styles` | Design tokens: `pixelToRem()`, typography vars, breakpoint mixins. SCSS only. | `@use "@myraui/styles/scss/..."` in `.module.scss` |
| `@myraui/utils` | `onEnterKey`, `useCallOnClickAway`, `getCyDataId`. Use in TSX. | `import { onEnterKey } from "@myraui/utils"` |
| `@myraui/badge` | Notification counter overlay (unread-count bubble on an icon). **Not a status pill.** | Not currently needed |

The **local design system** lives in:
- `frontend/src/common/components/layout/Layout.module.scss` — all shared CSS classes
- `frontend/src/common/components/sidebar/Sidebar.module.scss` — all CSS custom properties (theme variables)

Every page and component imports Layout.module.scss as `s` and uses classes from it.
**Never bypass these files with inline styles for things they already cover.**

---

## 1. CSS CUSTOM PROPERTIES (theme variables)

Every colour, background, and border must come from a CSS variable.
Hardcoded hex values break dark mode.

### 1.1 — Background colours

```tsx
// BAD — hardcoded; invisible or wrong in dark mode
<div style={{ background: "#f9fafb" }}>
<div style={{ background: "#ffffff" }}>
<div style={{ background: "#f3f4f6" }}>

// GOOD — uses theme variable
<div style={{ background: "var(--section-bg)" }}>
<div style={{ background: "var(--card-bg)" }}>
<div style={{ background: "var(--content-bg)" }}>
```

Available background variables and their semantic meaning:

| Variable | Use for |
|---|---|
| `--content-bg` | Page root background |
| `--card-bg` | Card, modal, panel surfaces |
| `--section-bg` | Subtle nested fill inside a card (filter bars, stat sub-rows) |
| `--input-bg` | `<input>`, `<textarea>`, `<select>` backgrounds |
| `--table-header-bg` | `<thead>` rows |
| `--table-row-hover` | `<tbody tr>` on hover; also mini-card fills inside cards |
| `--blocked-row-bg` | Table rows with `className={s.blocked}` |
| `--bg-highlight` | Expandable table rows that have detail (subtle yellow tint) |
| `--bg-subtle` | Alias for `--section-bg`; use either |

### 1.2 — Text colours

```tsx
// BAD
<span style={{ color: "#374151" }}>
<span style={{ color: "#002b4a" }}>
<span style={{ color: "#6b7280" }}>

// GOOD
<span style={{ color: "var(--text-primary)" }}>
<span style={{ color: "var(--text-secondary)" }}>
```

| Variable | Use for |
|---|---|
| `--text-primary` | All body text, labels, headings |
| `--text-secondary` | Hints, captions, inactive labels, table header text |
| `--text-muted` | Same as `--text-secondary`; alias |
| `--accent` | Links, active states, focus rings |

Never use raw `#000`, `#111827`, `#374151`, `#8095a4`, or `#002b4a` in component code.

### 1.3 — Semantic / status colours

These are used for data-driven colouring (success rates, error counts, budget bars).
Never hardcode the hex — the dark theme remaps them to higher-contrast values.

```tsx
// BAD — hardcoded semantic colours
const color = pct >= 80 ? "#10b981" : pct >= 40 ? "#f59e0b" : "#ef4444";

// GOOD — CSS variables
const color = pct >= 80
  ? "var(--badge-success-text)"
  : pct >= 40
  ? "var(--badge-warning-text)"
  : "var(--badge-error-text)";
```

Available semantic colour pairs (each has a `-bg` and a `-text` variant):

| Variable pair | Meaning |
|---|---|
| `--badge-success-bg` / `--badge-success-text` | Good / on / enabled |
| `--badge-warning-bg` / `--badge-warning-text` | Caution / degraded / over-threshold |
| `--badge-error-bg` / `--badge-error-text` | Bad / blocked / failed |
| `--badge-neutral-bg` / `--badge-neutral-text` | Informational / secondary |

### 1.4 — Buttons with accent-coloured backgrounds

In dark mode `--accent` is `#29d9ff` (bright cyan). White text on cyan fails WCAG contrast.
Always use `--btn-primary-text` for text on `--accent` or `--primary` backgrounds.

```tsx
// BAD — invisible/unreadable text in dark mode
<button style={{ background: "var(--accent)", color: "#fff" }}>

// GOOD
<button style={{ background: "var(--accent)", color: "var(--btn-primary-text, #fff)" }}>
```

This applies equally in `.module.scss` files:

```scss
// BAD
.my-btn { background: var(--accent, #0052cc); color: #fff; }

// GOOD
.my-btn { background: var(--accent, #0052cc); color: var(--btn-primary-text, #fff); }
```

The only exceptions where plain `#fff` is correct:
- `.btn--danger` (always dark red background, `#fff` has sufficient contrast in both themes)
- `.stop-btn` (always dark red, same reasoning)
- SVG `fill` / `stroke` on explicitly dark-background shapes

---

## 2. CSS CLASSES — Layout.module.scss

Every component imports `Layout.module.scss` as `s`. The classes below cover the full
surface of the UI. If the thing you're styling has a class for it, **use the class**.

### 2.1 — Page shell

Every page component must use `.page` as its root element.
Never substitute a custom `<div>` with inline padding.

```tsx
// BAD
<div style={{ padding: "32px 40px", background: "var(--content-bg)" }}>

// GOOD
<main className={s.page}>
```

The `.page-header` / `.page-title` / `.page-subtitle` trio handles the top of every page:

```tsx
// GOOD — consistent heading structure
<div className={s["page-header"]}>
  <div>
    <h1 className={s["page-title"]}>Gateways</h1>
    <p className={s["page-subtitle"]}>Manage provider routing and keys</p>
  </div>
  <button className={`${s.btn} ${s["btn--primary"]}`}>+ New Gateway</button>
</div>
```

### 2.2 — Cards

```tsx
// BAD — custom card styling
<div style={{ background: "var(--card-bg)", border: "1px solid var(--card-border)", borderRadius: 8, padding: 24 }}>

// GOOD
<div className={s.card}>
  <div className={s["card-header"]}>
    <h2 className={s["card-title"]}>Provider Keys</h2>
    <button className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`}>+ Add</button>
  </div>
  {/* content */}
</div>
```

### 2.3 — Tables

Every table must be wrapped in `.table-wrapper` and use `.table` on the `<table>` element.
A bare `<table>` without the wrapper loses the scroll shadow, border, and overflow handling.

```tsx
// BAD — bare table
<table style={{ width: "100%" }}>

// GOOD
<div className={s["table-wrapper"]}>
  <table className={s.table}>
    <thead>...</thead>
    <tbody>...</tbody>
  </table>
</div>
```

For blocked/guardrail rows, add the `.blocked` class on the `<tr>`:
```tsx
<tr className={row.blocked ? s.blocked : ""}>
```

### 2.4 — Badges (status pills)

All status indicators must use `.badge` + a modifier. Never use a custom `<span>` with
inline background colours.

```tsx
// BAD — custom coloured span
<span style={{ background: "#dcfce7", color: "#166534", borderRadius: 4, padding: "2px 8px" }}>active</span>

// GOOD
<span className={`${s.badge} ${s["badge--success"]}`}>active</span>
```

The four modifiers map to semantic meaning, not arbitrary colours:

| Class | Use for |
|---|---|
| `badge--success` | Enabled, active, passing, on |
| `badge--warning` | Degraded, rate-limited, near-limit, caution |
| `badge--error` | Blocked, failed, errored, disabled |
| `badge--neutral` | Plan names, slugs, non-semantic labels |

`StatusBadge` (`frontend/src/common/components/StatusBadge.tsx`) wraps this for HTTP
status codes — use it instead of hand-rolling the badge for HTTP responses.

The `@myraui/badge` package (`Badge` component) is **not** for status pills.
It is a notification counter overlay (a "3" bubble in the corner of an icon).
Only use it if adding unread-count indicators to sidebar navigation items.

### 2.5 — Buttons

```tsx
// BAD — custom button with inline styles
<button style={{ background: "var(--accent)", color: "var(--btn-primary-text)", padding: "8px 16px" }}>

// GOOD — use the .btn system
<button className={`${s.btn} ${s["btn--primary"]}`}>Save</button>
<button className={`${s.btn} ${s["btn--secondary"]}`}>Cancel</button>
<button className={`${s.btn} ${s["btn--danger"]}`}>Delete</button>
// Small variant:
<button className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`}>+ Add</button>
```

Rules:
- One primary action per form/modal
- Cancel/back actions use `--secondary`
- Destructive actions use `--danger`
- Icon-only buttons in Chat use `.icon-btn` from `Chat.module.scss`, not bare `<button>`
- Never use `<a>` styled as a button or `<div onClick>` for actions

### 2.6 — Forms

```tsx
// BAD — layout built with inline styles
<div style={{ marginBottom: 16 }}>
  <label style={{ display: "block", fontWeight: 500, marginBottom: 6 }}>Name</label>
  <input style={{ width: "100%", padding: "9px 12px", border: "1px solid var(--card-border)" }} />
  <p style={{ fontSize: 12, color: "var(--text-secondary)", marginTop: 4 }}>Max 64 characters</p>
</div>

// GOOD
<div className={s["form-group"]}>
  <label className={s["form-label"]} htmlFor="name">Name</label>
  <input id="name" className={s["form-input"]} />
  <p className={s["form-hint"]}>Max 64 characters</p>
</div>
```

Two-column layouts use `.form-row` (collapses to single column on mobile automatically):
```tsx
<div className={s["form-row"]}>
  <div className={s["form-group"]}>...</div>
  <div className={s["form-group"]}>...</div>
</div>
```

For `<select>` elements, use `.form-select` alone — it already extends `.form-input`.
Do NOT add both classes:
```tsx
// BAD — form-select already extends form-input
<select className={`${s["form-input"]} ${s["form-select"]}`}>

// GOOD
<select className={s["form-select"]}>
```

### 2.7 — Form actions (button row at bottom of form)

`.form-actions` provides right-aligned buttons, a border-top separator, and 24px top margin.
Inside a `<Modal>`, override `marginTop` to avoid excess space:

```tsx
// Full-page form — use .form-actions as-is
<div className={s["form-actions"]}>
  <button className={`${s.btn} ${s["btn--secondary"]}`}>Cancel</button>
  <button className={`${s.btn} ${s["btn--primary"]}`}>Save</button>
</div>

// Inside a <Modal> — tighten the top margin
<div className={s["form-actions"]} style={{ marginTop: 4 }}>
  <button className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
  <button className={`${s.btn} ${s["btn--primary"]}`}>Save</button>
</div>
```

Do NOT use `style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}` as a
substitute for `.form-actions`.

### 2.8 — Section headers (title + action button inside a card/panel)

```tsx
// BAD — manual flex row
<div style={{ display: "flex", justifyContent: "space-between", marginBottom: 16 }}>
  <h3 style={{ fontWeight: 600 }}>Auth Tokens</h3>
  <button>+ Add Token</button>
</div>

// GOOD
<div className={s["section-header"]}>
  <h3 className={s["section-title"]}>Auth Tokens</h3>
  <button className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`}>+ Add Token</button>
</div>
```

### 2.9 — Stat cards

```tsx
// GOOD — stat grid with cards
<div className={s["stats-grid"]}>
  <div className={s["stat-card"]}>
    <div className={s["stat-label"]}>Requests</div>
    <div className={s["stat-value"]}>14,661</div>
    <div className={s["stat-sub"]}>Last 7 days</div>
  </div>
</div>
```

For text values (emails, slugs, dates) that don't suit the large 28px numeral, use the modifier:
```tsx
<div className={`${s["stat-value"]} ${s["stat-value--text"]}`}>{user.email}</div>
```

### 2.10 — Empty states

```tsx
// BAD — custom empty state
<p style={{ textAlign: "center", color: "var(--text-secondary)", padding: 48 }}>No results</p>

// GOOD
<div className={s.empty}>
  <div className={s["empty-icon"]}>📋</div>
  No commands yet. Create one to use /commandname shortcuts in chat.
</div>
```

### 2.11 — Alerts

```tsx
// BAD — custom error banner
<div style={{ background: "#fee2e2", color: "#991b1b", borderRadius: 6, padding: 12 }}>

// GOOD
<div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>
<div className={`${s.alert} ${s["alert--warning"]}`}>{warning}</div>
<div className={`${s.alert} ${s["alert--success"]}`}>{successMsg}</div>
```

### 2.12 — Modals

Every dialog must use the shared `Modal` component.
Never build a custom overlay with `position: fixed`, a backdrop `<div>`, or manual `z-index`.

```tsx
// BAD — custom overlay
<div style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.4)", zIndex: 1000 }}>
  <div style={{ background: "var(--card-bg)", borderRadius: 12, padding: 28, width: 480 }}>

// GOOD
import { Modal } from "src/common/components/Modal";

<Modal title="Create Gateway" onClose={onClose} error={errorMessage}>
  <div className={s["form-group"]}>...</div>
  <div className={s["form-actions"]} style={{ marginTop: 4 }}>...</div>
</Modal>
```

### 2.13 — Tabs

```tsx
// GOOD — tab navigation bar
<div className={s.tabs}>
  <button
    className={`${s.tab} ${activeTab === "keys" ? s["tab--active"] : ""}`}
    onClick={() => setActiveTab("keys")}
  >
    Provider Keys
  </button>
</div>
```

### 2.14 — Monospace / code

```tsx
// BAD — inline font-family
<td style={{ fontFamily: "monospace", fontSize: 12 }}>{token.id}</td>
// BAD — also sets redundant fontSize (mono already sets 12px)
<td className={s.mono} style={{ fontSize: 12 }}>

// GOOD — .mono for plain monospace table cells
<td className={s.mono}>{token.id}</td>

// GOOD — .code for inline identifiers with a pill background inside prose
<span className={s.code}>{gateway.slug}</span>
```

### 2.15 — Dividers

```tsx
// BAD — inline <hr>
<hr style={{ border: "none", borderTop: "1px solid var(--card-border)", margin: "16px 0" }} />

// GOOD
<hr className={s.divider} />
```

### 2.16 — Picker classes (icon / emoji / colour pickers only)

`.picker-btn` has `font-size: 20px` and `min-width: 36px`. It is **only** for icon or emoji
picker buttons. Do not use it for text-label button groups.

```tsx
// BAD — text label inside a picker-btn
<button className={s["picker-btn"]}>Blocked</button>

// GOOD — text button groups use btn--sm + primary/secondary
<button className={`${s.btn} ${s["btn--sm"]} ${isActive ? s["btn--primary"] : s["btn--secondary"]}`}>
  Blocked
</button>

// GOOD — emoji picker uses picker-btn correctly
<button className={`${s["picker-btn"]} ${icon === "🚀" ? s["picker-btn--selected"] : ""}`}>
  🚀
</button>
```

---

## 3. @myraui/utils — ALWAYS USE THESE

### 3.1 — `onEnterKey` for keyboard submit

```tsx
import { onEnterKey } from "@myraui/utils";

// BAD — inline reimplementation (10+ occurrences in codebase)
onKeyDown={(e) => e.key === "Enter" && (e.preventDefault(), addKeyword())}

// GOOD
onKeyDown={(e) => onEnterKey(e, () => { e.preventDefault(); addKeyword(); })}
```

### 3.2 — `useCallOnClickAway` for drawers and panels

```tsx
import { useCallOnClickAway } from "@myraui/utils";

// BAD — manual document listener with manual cleanup
useEffect(() => {
  const handler = (e: MouseEvent) => {
    if (!panelRef.current?.contains(e.target as Node)) onClose();
  };
  document.addEventListener("mousedown", handler);
  return () => document.removeEventListener("mousedown", handler);
}, [onClose]);

// GOOD
const panelRef = useRef<HTMLDivElement>(null);
useCallOnClickAway({ ref: panelRef, callback: onClose });
```

Use this in every slide-over drawer and floating panel that closes on outside click.

### 3.3 — `getCyDataId` for test selectors

```tsx
import { getCyDataId } from "@myraui/utils";

// BAD — ad-hoc data-cy strings
<button data-cy="sidebar-feedback-btn">

// GOOD
const getCyProp = getCyDataId("sidebar");
<button {...getCyProp("feedback-btn")}>
// produces: data-cy="sidebar-feedback-btn"
```

---

## 4. SCSS CONVENTIONS

### 4.1 — Use `pixelToRem()` for all sizing

Raw `px` values in per-page SCSS modules break if the base font size ever changes.
All Layout.module.scss and Sidebar.module.scss values already use `pixelToRem()`.
Per-page modules must do the same.

```scss
// BAD — raw pixels in a .module.scss file
.latency-item { padding: 8px 16px; gap: 8px; border-radius: 8px; }

// GOOD
@use "@myraui/styles/scss/mixins/tools";
.latency-item {
  padding: tools.pixelToRem(8) tools.pixelToRem(16);
  gap: tools.pixelToRem(8);
  border-radius: tools.pixelToRem(8);
}
```

### 4.2 — Use named breakpoints, not magic numbers

```scss
// BAD — magic breakpoint values
@media (max-width: 768px) { ... }
@media (max-width: 560px) { ... }

// GOOD — named breakpoints from myraui/styles
@use "@myraui/styles/scss/mixins/tools";

@include tools.below-breakpoint(md) { ... }   // 768px
@include tools.below-breakpoint(sm) { ... }   // 576px
```

Available breakpoints: `xxl` (1400), `xl` (1200), `lg` (992), `md` (768), `sm` (576), `xs` (0).

### 4.3 — Do not declare new CSS variables outside Sidebar.module.scss

All theme variables live in `Sidebar.module.scss` under `:root` / `[data-theme="dark"]`.
Adding `--my-custom-var` inside a `.module.scss` file without a dark-mode counterpart
will always show the light-mode value in dark mode.

```scss
// BAD — declared in a per-page module, no dark counterpart
.my-component { --highlight: rgba(255, 240, 0, 0.3); }

// GOOD — add to Sidebar.module.scss under both :root and [data-theme="dark"]
:root { --bg-highlight: rgba(253, 246, 178, 0.6); }
[data-theme="dark"] { --bg-highlight: rgba(255, 220, 0, 0.08); }
// then use it anywhere
.my-component { background: var(--bg-highlight); }
```

### 4.4 — `@extend` in SCSS vs class composition in TSX

`Layout.module.scss` uses `@extend` internally (e.g. `.form-select` extends `.form-input`).
This means `.form-select` **already has all `.form-input` styles**. Do not add both in TSX.

```tsx
// BAD — redundant double class
<select className={`${s["form-input"]} ${s["form-select"]}`} />

// GOOD
<select className={s["form-select"]} />
```

---

## 5. MULTI-CLASS COMPOSITION

### 5.1 — Use clsx for conditional classes

Avoid template literals for anything with a conditional branch. Add `clsx` as an explicit
dependency and use it everywhere class names are composed.

```tsx
// BAD — template literal with ternary
className={`${s.tab} ${activeTab === "keys" ? s["tab--active"] : ""}`}

// ALSO BAD — string concatenation
className={[s.btn, s["btn--primary"], isSmall && s["btn--sm"]].filter(Boolean).join(" ")}

// GOOD
import clsx from "clsx";
className={clsx(s.tab, activeTab === "keys" && s["tab--active"])}
className={clsx(s.btn, s["btn--primary"], isSmall && s["btn--sm"])}
```

---

## 6. ACCESSIBILITY BASICS

- Every `<input>`, `<textarea>`, `<select>` must have an associated `<label>` via `htmlFor`
  + `id`, or an `aria-label`.
- Icon-only `<button>` elements must have a `title` or `aria-label`.
- The `<Modal>` component's close button already has `aria-label="Close"` — do not override it.
- Clickable `<tr>` rows must have `role="button"` and `tabIndex={0}` with keyboard handling.

```tsx
// BAD — unlabelled input
<input className={s["form-input"]} placeholder="Search…" />

// GOOD
<input className={s["form-input"]} aria-label="Search" placeholder="Search…" />
// or
<label className={s["form-label"]} htmlFor="search">Search</label>
<input id="search" className={s["form-input"]} />
```

---

## 7. AUDIT GREP COMMANDS

Run these from `frontend/src/` to find violations. Pipe each to `| head -40` for
triage; pipe to a file for a full report.

```bash
# Hardcoded hex colours in TSX (excluding intentional code-block themes)
grep -rn '"#[0-9a-fA-F]\{3,6\}"' src --include="*.tsx" \
  | grep -v "22272e\|adbac7\|d32f2f\|dc2626\|0052cc" \
  | grep "color\|background\|fill\|stroke"

# Hardcoded hex colours in SCSS modules (excluding intentional overrides)
grep -rn ":\s*#[0-9a-fA-F]\{3,6\}" src --include="*.module.scss" \
  | grep -v "Sidebar\|rgba\|transparent"

# color: #fff on var(--accent) or var(--primary) backgrounds — contrast failure in dark mode
grep -rn "accent.*color.*#fff\|color.*#fff" src --include="*.tsx" --include="*.scss" \
  | grep -v "btn-primary-text\|d32f2f\|dc2626\|22272e\|stop-btn"

# Inline flex rows that should use .form-actions or .section-header
grep -rn "display.*flex.*justif.*space-between\|justif.*flex-end.*gap\|gap.*flex-end" \
  src --include="*.tsx" | grep "style={{"

# Bare <table> without .table class
grep -rn "<table " src --include="*.tsx" | grep -v "className.*table"

# .form-select and .form-input used together (form-select already extends form-input)
grep -rn "form-input.*form-select\|form-select.*form-input" src --include="*.tsx"

# Custom modal overlay instead of <Modal> component
grep -rn "position.*fixed.*zIndex\|zIndex.*1000\|modal-overlay" src --include="*.tsx" \
  | grep "style={{" | grep -v "Modal.tsx"

# inline fontFamily: monospace instead of .mono class
grep -rn "fontFamily.*monospace\|font-family.*monospace" src --include="*.tsx"

# Enter key check reinvented instead of onEnterKey utility
grep -rn "\.key.*Enter\|keyCode.*13" src --include="*.tsx" \
  | grep -v "onEnterKey\|test\|spec\|//\|Shift\|Meta\|Ctrl\|ctrlKey\|shiftKey\|metaKey"

# CSS variables used without dark-mode counterpart (catch new vars in per-page modules)
grep -rn "^\s*--[a-z]" src --include="*.module.scss" \
  | grep -v "Sidebar.module.scss"

# Raw px values in per-page SCSS modules (should use pixelToRem)
grep -rn "[0-9]\+px" src --include="*.module.scss" \
  | grep -v "Layout.module\|Sidebar.module\|0px\|1px\|2px\|100%"

# picker-btn used for text labels (not icons/emoji)
grep -rn "picker-btn" src --include="*.tsx" -A1 | grep -v "🔴\|🟢\|🔵\|emoji\|icon\|✓\|#\|picker-btn--\|^--"
```

---

## 8. KNOWN-GOOD REFERENCE PATTERNS

When in doubt, compare against these confirmed-correct components:

| Pattern | Reference |
|---|---|
| Full page with table, empty state, create modal | `frontend/src/modules/tenants/pages/Tenants.tsx` |
| Detail page with stat cards, tabs, section headers | `frontend/src/modules/tenants/pages/TenantDetail.tsx` |
| Form modal with validation and `.form-actions` | `frontend/src/modules/gateways/pages/Gateways.tsx` (gateway create) |
| Badge + StatusBadge usage | `frontend/src/common/components/StatusBadge.tsx` |
| Shared Modal component | `frontend/src/common/components/Modal.tsx` |
| CSS variable definitions (light + dark) | `frontend/src/common/components/sidebar/Sidebar.module.scss` |
| pixelToRem + breakpoints in SCSS | `frontend/src/common/components/layout/Layout.module.scss` |

---

## 9. OUTPUT FORMAT

For each finding, report:

```
FILE: src/modules/users/pages/Users.tsx:175
✘ [HARDCODED FLEX]  style={{ display: "flex", gap: 6 }} wrapping two buttons
     → replace with <div className={s["form-actions"]} style={{ marginTop: 4 }}>

FILE: src/modules/monitor/pages/Monitor.module.scss:43
✘ [RAW PX]  padding: 8px 16px — no pixelToRem
     → tools.pixelToRem(8) tools.pixelToRem(16)

FILE: src/modules/chat/pages/Chat.tsx:2172
✘ [CONTRAST]  color: "#fff" on var(--accent) background — fails dark mode contrast
     → color: "var(--btn-primary-text, #fff)"
```

Findings rated **CONTRAST** or **HARDCODED COLOR** are blocking — they break dark mode.
All others are consistency issues that degrade the audit score but do not block shipping.
