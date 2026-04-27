# CSS / UI Consistency Audit Prompt

Paste the contents of the **PROMPT** section below into a fresh Claude Code session
to run a full dark-mode and MyraUI consistency audit of the frontend.

---

## PROMPT

You are doing a full UI consistency and dark-mode audit of this React/SCSS frontend.
Work systematically: screenshot every page, inspect every component, fix every issue
you find. Do not stop at the first problem per page — find them all.

---

### ENVIRONMENT

- Base URL (production, auth required): `https://ai.myra.eu`
- Auth session (Playwright storageState): `frontend/tests/.auth/docker-session.json`
- Re-authenticate if session is stale:
  ```bash
  cd frontend && ./run-e2e.sh tests/auth.docker.setup.ts --config playwright.docker.config.ts
  ```
- Theme CSS variables are defined in:
  `frontend/src/common/components/sidebar/Sidebar.module.scss` ← `:root` / `[data-theme]`
- Shared CSS classes live in:
  `frontend/src/common/components/layout/Layout.module.scss` ← the design system
- Per-page CSS lives in each module's own `.module.scss` file.
- Dark mode is activated by `document.documentElement.setAttribute("data-theme","dark")`
  and `localStorage.setItem("theme","dark")`. Both must be set before reloading.

---

### HOW TO TAKE SCREENSHOTS

Use a Node ESM script with the local Playwright install.
Run from `frontend/`:

```js
node --input-type=module << 'EOF'
import { chromium } from "./node_modules/playwright/index.mjs";
import path from "path";
const S = path.resolve("tests/.auth/docker-session.json");
const B = "https://ai.myra.eu";
const browser = await chromium.launch();

async function shot(url, label, dark = false, extra = null) {
  const ctx = await browser.newContext({
    storageState: S, colorScheme: dark ? "dark" : "light",
    viewport: { width: 1440, height: 900 }, ignoreHTTPSErrors: true,
  });
  const page = await ctx.newPage();
  await page.goto(B + url);
  await page.waitForLoadState("networkidle");
  if (dark) {
    await page.evaluate(() => {
      localStorage.setItem("theme", "dark");
      document.documentElement.setAttribute("data-theme", "dark");
    });
    await page.reload();
    await page.waitForLoadState("networkidle");
  }
  if (extra) await extra(page);
  await page.screenshot({ path: `/tmp/${label}.png`, fullPage: true });
  await ctx.close();
}

// Add shots here — see page list below
await shot("/dashboard", "dashboard-light");
await shot("/dashboard", "dashboard-dark", true);
// ...
await browser.close();
EOF
```

Read each PNG immediately after capturing it.

---

### PAGES TO AUDIT

Shoot **both light and dark** for every page.

| Route | Notes |
|---|---|
| `/dashboard` | |
| `/logs` | |
| `/monitor` | |
| `/analytics` | |
| `/gateways` | List view |
| `/gateways/:id` | Any real gateway — detail + tabs |
| `/tenants` | |
| `/tenants/:id` | |
| `/users` | |
| `/users/:id` | |
| `/prices` | |
| `/profile` | |
| `/mcp` | |
| `/projects` | |
| `/projects/:id` | |
| `/commands` | |
| `/chat` | Base state (no conversation) |
| `/chat` | With a real conversation open (messages visible) |
| `/chat` | With **memory panel** open (`[data-cy=memories-btn]`) |
| `/chat` | With **settings drawer** open |
| `/playground` | |

**Modals and drawers** — trigger on every page where they exist:

- Create / Edit modals (gateway, tenant, user, project, MCP connector, auth token, slash command)
- Delete confirmation dialogs
- `AppFeedbackWidget` — flag button in sidebar header (`[data-cy=app-feedback-btn]`)
- Memory panel (`[data-cy=memories-btn]`)
- Settings drawer in chat

---

### WHAT TO CHECK ON EVERY SCREENSHOT

#### 1. Dark mode — form elements

Native browser controls (`select`, `input`, `textarea`, `checkbox`, `radio`) must
render with dark backgrounds. If any appear light or washed-out:

- Confirm `color-scheme: light` / `color-scheme: dark` is declared on
  `:root` / `[data-theme="dark"]` in `Sidebar.module.scss` (already done — verify
  it is taking effect on every page, not just pages that include the sidebar).
- Confirm `.form-select` has `-webkit-appearance: none; appearance: none` and a
  themed SVG chevron `background-image` (already in `Layout.module.scss`).
- Check checkboxes, radio buttons, and range inputs — these also rely on
  `color-scheme` to render dark correctly.

#### 2. Dark mode — backgrounds and borders

Nothing should be a hardcoded light value (`#fff`, `white`, `#f9fafb`, `#e5e7eb`,
`#f3f4f6`, etc.) inside a dark-themed container.

Use only CSS variables:

| Purpose | Variable |
|---|---|
| Page background | `var(--content-bg)` |
| Card / panel background | `var(--card-bg)` |
| Subtle section fill | `var(--section-bg)` |
| Input background | `var(--input-bg)` |
| Card border | `var(--card-border)` |
| Table header row | `var(--table-header-bg)` |
| Table row hover | `var(--table-row-hover)` |

#### 3. Dark mode — text colours

No hardcoded text colours (`#374151`, `#002b4a`, `#111827`, `#000`, etc.) on
elements inside dark containers. Use `var(--text-primary)` and
`var(--text-secondary)`.

#### 4. Inline styles that should be CSS classes

Every time you see an inline `style=` on a JSX element, ask:
*"Is there already a `Layout.module.scss` class that covers this?"*

Available classes (non-exhaustive):

| Category | Classes |
|---|---|
| Page shell | `.page` `.page-header` `.page-title` `.page-subtitle` |
| Buttons | `.btn` + `.btn--primary` `.btn--secondary` `.btn--danger` `.btn--sm` |
| Forms | `.form-group` `.form-label` `.form-input` `.form-hint` `.form-actions` `.form-row` |
| Tables | `.table-wrapper` `.table` |
| Badges | `.badge` + `.badge--success` `.badge--warning` `.badge--error` `.badge--neutral` |
| Alerts | `.alert` + `.alert--success` `.alert--error` |
| Cards | `.card` `.card-header` `.card-title` |
| Empty state | `.empty` `.empty-icon` |
| Detail panel | `.detail-panel` `.detail-panel-body` `.detail-header` `.detail-title` |
| Tabs | `.tabs` `.tab` `.tab--active` |
| Stats | `.stats-grid` `.stat-card` `.stat-label` `.stat-value` |
| Sections | `.section-header` `.section-title` |
| Pickers | `.picker-row` `.picker-group` `.picker-options` `.picker-btn` `.picker-btn--selected` |
| Modals | Use shared `<Modal>` component — never a custom overlay |

**Picker classes are only for icon / emoji / colour pickers.**
`picker-btn` has `font-size: 20px` and `min-width: 36px`. Do not use it for
text-label button groups — use `.btn--sm` + `.btn--primary` / `.btn--secondary` instead.

Common violations to look for:

- Custom modal overlays instead of `<Modal>` (`frontend/src/common/components/Modal.tsx`)
- `style={{ color: "#something" }}` on text instead of a badge or alert class
- `style={{ display: "flex", gap: X }}` where `.form-row` or `.form-actions` already exists
- `style={{ fontWeight: 600, fontSize: 14 }}` on headings instead of `.page-title` etc.
- `style={{ background: "#fff" }}` or any hardcoded background colour
- `.picker-btn` used for text-label buttons

#### 5. Spacing and layout consistency

- Page-level components must use `.page` as their root — not a custom wrapper div.
- Modal content must flow: title (handled by `<Modal>`), then `.form-group` fields,
  then `.form-actions` at the bottom.
- `.form-actions` inside modals: the class adds `margin-top: 24px` which is intended
  for full-page forms. In modals, override with `style={{ marginTop: 4 }}` to avoid
  excessive dead space before the action buttons.
- Tables: always `<div className={s["table-wrapper"]}><table className={s.table}>`.
  No bare `<table>` elements.
- Empty states: always use `.empty` (and optionally `.empty-icon`) — no custom
  "no data" paragraphs with inline styles.

#### 6. Button usage

- Primary action: `.btn.btn--primary` (one per form/modal)
- Cancel / secondary: `.btn.btn--secondary`
- Destructive: `.btn.btn--danger`
- Small variant: add `.btn--sm`
- Icon-only toolbar buttons in Chat: use `.icon-btn` from `Chat.module.scss`,
  not a bare `<button>` with inline styles
- Never use `<a>` styled as a button or `<div onClick>` for actions

#### 7. Badges and status indicators

All badges must use `.badge` + `.badge--{success|warning|error|neutral}`.
No custom coloured `<span>` pills with inline `background` colours.
`StatusBadge` (`frontend/src/common/components/StatusBadge.tsx`) is available
for HTTP status codes — use it.

#### 8. Modal consistency

Every dialog / overlay must use the shared `<Modal>` component:

```tsx
import { Modal } from "src/common/components/Modal";

<Modal title="..." onClose={...} error={errorState}>
  {/* content */}
</Modal>
```

Flag any component that builds a custom overlay with `position: fixed`, a backdrop
`div`, or manual `z-index` stacking — replace it with `<Modal>`.

#### 9. Accessibility basics

- Every `<input>` / `<textarea>` / `<select>` must have an associated `<label>`
  (via `htmlFor` + `id`, or `aria-label`).
- Icon-only buttons must have `title=` or `aria-label=`.
- Modal close button must be keyboard-focusable and have `aria-label="Close"`.

---

### KNOWN-GOOD REFERENCE PAGES

Compare suspicious patterns against these before flagging:

- `/dashboard` — hero cards, timeseries, recent-requests table, rate-limited badge
- `/chat` — feedback modal (`AppFeedbackWidget`), memory panel, message bubbles, PII chip
- `/gateways` (list) — table with badges, empty state, create modal

---

### OUTPUT FORMAT

For each page, report findings as:

```
PAGE: /logs  (dark mode)
✘ [HARDCODED COLOR]  LogEntry.tsx:142 — style={{ color: "#6b7280" }}
     → use var(--text-secondary) or className={s["form-hint"]}
✘ [WRONG ELEMENT]  bare <table> without .table-wrapper at line 88
     → wrap in <div className={s["table-wrapper"]}><table className={s.table}>
✘ [DARK BG]  filter panel has background:"#f9fafb" — invisible in dark mode
     → replace with var(--section-bg)
✓ Badges, empty state, form fields all correct.
```

Implement all fixes. After fixing a page, re-screenshot in both modes to confirm
before moving to the next page.

---

### COMPLETION CHECKLIST

After all pages are done:

```bash
# Hot-deploy to production container
cd /home/sas/work/ai-gateway && bash build_frontend.sh 2>/dev/null

# Must be clean — no type errors
cd frontend && npx tsc --noEmit
```

Commit all fixes as a single commit:

```
fix(ui): dark mode, CSS consistency, and MyraUI element audit
```
