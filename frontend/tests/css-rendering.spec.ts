/**
 * css-rendering.spec.ts — HTML/CSS rendering quality tests.
 *
 * Covers accessibility and visual-correctness issues identified during the
 * CSS review.  Tests assert the correct rendered behaviour; they FAIL while
 * the bugs exist and PASS once the fixes are applied.
 *
 * Issues detected:
 *   • `.tab--active` uses hardcoded `color: #002b4a` — invisible in dark mode
 *     (contrast ratio ~1.4 against #071929 background; WCAG AA requires ≥ 4.5)
 *   • `.settings-input` has no `width: 100%; box-sizing: border-box` —
 *     number inputs do not fill their flex-column parent
 *   • Layout.module.scss `.btn--primary` uses hardcoded `#002b4a` instead of
 *     `var(--primary)` — prevents dark-mode re-theming
 *   • Layout.module.scss `.form-input:focus` uses hardcoded `#002b4a` instead of
 *     `var(--accent)` — prevents dark-mode re-theming
 */

import { test, expect, type Page } from "./base";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const ADMIN_URL  = process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173";
const ADMIN_BASE = `${ADMIN_URL}/admin/v1`;

// WCAG 2.1 AA requirements
const WCAG_AA_NORMAL = 4.5;
const WCAG_AA_LARGE  = 3.0;

// ---------------------------------------------------------------------------
// Contrast-ratio helpers (runs inside the browser via page.evaluate)
// ---------------------------------------------------------------------------

/** Parse "rgb(r, g, b)" or "rgba(r, g, b, a)" to [r,g,b]. */
function parseRgb(cssColor: string): [number, number, number] | null {
  const m = cssColor.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/);
  if (!m) return null;
  return [Number(m[1]), Number(m[2]), Number(m[3])];
}

/** Relative luminance (WCAG 2.1 §1.4.3 formula). */
function relativeLuminance(rgb: [number, number, number]): number {
  const c = rgb.map((v) => {
    const s = v / 255;
    return s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  }) as [number, number, number];
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

/** WCAG contrast ratio between two CSS colour strings. Returns NaN on parse failure. */
function contrastRatio(fg: string, bg: string): number {
  const fgRgb = parseRgb(fg);
  const bgRgb = parseRgb(bg);
  if (!fgRgb || !bgRgb) return NaN;
  const l1 = relativeLuminance(fgRgb);
  const l2 = relativeLuminance(bgRgb);
  const lighter = Math.max(l1, l2);
  const darker  = Math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------

interface TenantRow { id: string; slug: string }
interface ProjectRow { id: string; name: string }

async function getMyratestTenantId(page: Page): Promise<string> {
  const r = await page.context().request.get(`${ADMIN_BASE}/tenants`);
  expect(r.ok(), `GET /tenants: ${await r.text()}`).toBeTruthy();
  const tenants = (await r.json()) as TenantRow[];
  const t = tenants.find((t) => t.slug === "myratest");
  expect(t, "myratest tenant must exist").toBeTruthy();
  return t!.id;
}

async function createProject(page: Page, tenantId: string, name: string): Promise<string> {
  const r = await page.context().request.post(`${ADMIN_BASE}/projects`, {
    data: { name, icon: "🎨", color: "#6d28d9", tenant_id: tenantId },
  });
  expect(r.ok(), `create project: ${await r.text()}`).toBeTruthy();
  return ((await r.json()) as ProjectRow).id;
}

async function deleteProject(page: Page, id: string) {
  await page.context().request.delete(`${ADMIN_BASE}/projects/${id}`).catch(() => {});
}

// ---------------------------------------------------------------------------
// Suite 1 — Dark-mode active tab contrast
// ---------------------------------------------------------------------------

test.describe("CSS — dark mode tab active contrast", () => {
  test.setTimeout(60_000);

  /**
   * In dark mode the active-tab text must satisfy WCAG AA (≥ 4.5:1 contrast).
   *
   * Root cause: Layout.module.scss `.tab--active` has hardcoded `color: #002b4a`
   * which is nearly invisible on the dark-mode `--content-bg: #071929`
   * (contrast ratio ≈ 1.4).
   *
   * Fix: replace hardcoded `color: #002b4a` with `color: var(--text-primary)`,
   * and `border-bottom-color: #002b4a` with `border-bottom-color: var(--accent)`.
   */
  test("active tab text is readable in dark mode (WCAG AA ≥ 4.5:1)", async ({ page }) => {
    const tenantId = await getMyratestTenantId(page);
    const projectId = await createProject(page, tenantId, `css-contrast-test-${Date.now()}`);

    try {
      // Force dark mode before navigation so ThemeContext picks it up from localStorage
      await page.addInitScript(() => {
        localStorage.setItem("theme", "dark");
      });

      await page.goto(`/projects/${projectId}`);

      // Wait for the tabs to render (ProjectDetail renders "Overview", "Files", etc.)
      const activeTab = page.locator("[class*='tab--active']").first();
      await expect(activeTab).toBeVisible({ timeout: 10_000 });

      const { tabColor, bgColor } = await page.evaluate(() => {
        const el = document.querySelector("[class*='tab--active']") as HTMLElement | null;
        if (!el) return { tabColor: "", bgColor: "" };

        const computedTab = window.getComputedStyle(el);
        const tabColor    = computedTab.color;

        // Walk up to find the nearest opaque background
        let bg = "";
        let node: HTMLElement | null = el;
        while (node) {
          const c = window.getComputedStyle(node).backgroundColor;
          if (c && !c.includes("rgba(0, 0, 0, 0)") && c !== "transparent") {
            bg = c;
            break;
          }
          node = node.parentElement;
        }
        // Fallback: use the document body background
        if (!bg) bg = window.getComputedStyle(document.body).backgroundColor;
        return { tabColor, bgColor: bg };
      });

      expect(
        tabColor,
        "Could not read computed color of active tab element",
      ).toBeTruthy();
      expect(
        bgColor,
        "Could not determine background colour for contrast calculation",
      ).toBeTruthy();

      const ratio = contrastRatio(tabColor, bgColor);
      expect(
        isNaN(ratio),
        `Could not parse colours for contrast calculation: fg="${tabColor}", bg="${bgColor}"`,
      ).toBe(false);

      expect(
        ratio,
        `Dark-mode active tab contrast ratio is ${ratio.toFixed(2)}:1 — ` +
          `WCAG AA requires ≥ ${WCAG_AA_NORMAL}:1.\n` +
          `tab color: ${tabColor}, background: ${bgColor}\n` +
          `Fix: replace "color: #002b4a" with "color: var(--text-primary)" in ` +
          `Layout.module.scss .tab { &--active { ... } }.`,
      ).toBeGreaterThanOrEqual(WCAG_AA_NORMAL);
    } finally {
      await deleteProject(page, projectId);
      // Restore light theme so other tests are unaffected
      await page.evaluate(() => localStorage.removeItem("theme"));
    }
  });
});

// ---------------------------------------------------------------------------
// Suite 2 — Settings input fills its container
// ---------------------------------------------------------------------------

test.describe("CSS — settings input width", () => {
  test.setTimeout(30_000);

  /**
   * The `.settings-input` (number input in the chat settings drawer) should
   * fill its `.settings-field` flex container.
   *
   * Root cause: `.settings-input` has no `width` rule, so number inputs use
   * their intrinsic size (~10ch) rather than filling the container.
   *
   * Fix: add `width: 100%; box-sizing: border-box;` to `.settings-input`.
   */
  test("max-tokens input fills its container width", async ({ page }) => {
    await page.goto("/chat");
    await page.waitForTimeout(500);

    // Open the settings drawer
    const settingsBtn = page.locator("button[title='Settings']");
    await expect(settingsBtn).toBeVisible({ timeout: 10_000 });
    await settingsBtn.click();

    // Wait for the drawer to appear (contains a number input for Max tokens)
    const maxTokensInput = page.locator("input[type='number']").first();
    await expect(maxTokensInput).toBeVisible({ timeout: 5_000 });

    const { inputWidth, containerWidth } = await page.evaluate(() => {
      const input = document.querySelector("input[type='number']") as HTMLElement | null;
      if (!input) return { inputWidth: 0, containerWidth: 0 };

      const container = input.parentElement as HTMLElement | null;
      if (!container) return { inputWidth: input.getBoundingClientRect().width, containerWidth: 0 };

      return {
        inputWidth:     input.getBoundingClientRect().width,
        containerWidth: container.getBoundingClientRect().width,
      };
    });

    expect(
      containerWidth,
      "Could not determine container width — settings drawer may not have rendered",
    ).toBeGreaterThan(0);

    // The input should fill at least 90% of its container
    const fillRatio = inputWidth / containerWidth;
    expect(
      fillRatio,
      `Max-tokens input fills only ${(fillRatio * 100).toFixed(0)}% of its container ` +
        `(${inputWidth.toFixed(0)}px / ${containerWidth.toFixed(0)}px).\n` +
        `Fix: add "width: 100%; box-sizing: border-box;" to .settings-input in Chat.module.scss.`,
    ).toBeGreaterThanOrEqual(0.9);
  });
});

// ---------------------------------------------------------------------------
// Suite 3 — Primary button colour responds to theme (not hardcoded)
// ---------------------------------------------------------------------------

test.describe("CSS — primary button dark-mode re-theming", () => {
  test.setTimeout(30_000);

  /**
   * In dark mode, primary buttons should use a lighter colour so they remain
   * visible on the dark surface.  The hardcoded `background: #002b4a` in
   * Layout.module.scss `.btn--primary` prevents this.
   *
   * Fix: replace `background: #002b4a` with `background: var(--primary)`.
   * In dark mode `--primary` resolves to `#29d9ff`, giving much better
   * contrast against `--content-bg: #071929`.
   */
  test("primary button has adequate contrast in dark mode", async ({ page }) => {
    await page.addInitScript(() => {
      localStorage.setItem("theme", "dark");
    });

    await page.goto("/tenants");
    await page.waitForTimeout(500);

    // Find any .btn--primary rendered on the page (e.g. "New tenant" button)
    const primaryBtn = page.locator("[class*='btn--primary']").first();
    const btnVisible = await primaryBtn.isVisible({ timeout: 5_000 }).catch(() => false);
    if (!btnVisible) {
      // No primary button visible on this page — skip gracefully
      test.skip(true, "No primary button visible on /gateways — cannot test");
      return;
    }

    const { btnBg, bgColor } = await page.evaluate(() => {
      const btn = document.querySelector("[class*='btn--primary']") as HTMLElement | null;
      if (!btn) return { btnBg: "", bgColor: "" };

      const btnBg = window.getComputedStyle(btn).backgroundColor;

      let bg = "";
      let node: HTMLElement | null = btn.parentElement;
      while (node) {
        const c = window.getComputedStyle(node).backgroundColor;
        if (c && !c.includes("rgba(0, 0, 0, 0)") && c !== "transparent") {
          bg = c;
          break;
        }
        node = node.parentElement;
      }
      if (!bg) bg = window.getComputedStyle(document.body).backgroundColor;
      return { btnBg, bgColor: bg };
    });

    const ratio = contrastRatio(btnBg, bgColor);
    expect(
      ratio,
      `Primary button background contrast is ${ratio.toFixed(2)}:1 in dark mode — ` +
        `WCAG AA for large text requires ≥ ${WCAG_AA_LARGE}:1.\n` +
        `button bg: ${btnBg}, page bg: ${bgColor}\n` +
        `Fix: replace "background: #002b4a" with "background: var(--primary)" in ` +
        `Layout.module.scss .btn--primary.`,
    ).toBeGreaterThanOrEqual(WCAG_AA_LARGE);
  });
});

// ---------------------------------------------------------------------------
// Suite 4 — Form input focus border responds to theme
// ---------------------------------------------------------------------------

test.describe("CSS — form input focus border dark-mode re-theming", () => {
  test.setTimeout(30_000);

  /**
   * `.form-input:focus` has `border-color: #002b4a` (hardcoded).
   * In dark mode this nearly invisible navy border is indistinguishable from
   * the dark surface.  It should use `var(--accent)` which is `#29d9ff`
   * in dark mode.
   *
   * Fix: replace `border-color: #002b4a` with `border-color: var(--accent)`.
   */
  test("form input focus border is visible in dark mode", async ({ page }) => {
    await page.addInitScript(() => {
      localStorage.setItem("theme", "dark");
    });

    // /commands: form-input elements are inside the "New command" modal
    await page.goto("/commands");
    await page.waitForTimeout(500);

    // Open the modal to expose form inputs
    const newBtn = page.locator("button", { hasText: /new command/i }).first();
    await expect(newBtn).toBeVisible({ timeout: 5_000 });
    await newBtn.click();

    // Find any form input on the page
    const formInput = page.locator("[class*='form-input']").first();
    const inputVisible = await formInput.isVisible({ timeout: 5_000 }).catch(() => false);
    if (!inputVisible) {
      test.skip(true, "No form-input found on /commands — cannot test");
      return;
    }

    // In headless Playwright, :focus CSS may not fire reliably from JS .focus().
    // Instead, verify the CSS focus rule uses var(--accent) and that --accent
    // has adequate contrast vs the background in dark mode.
    const { accentColor, bgColor, focusRuleUsesVar } = await page.evaluate(() => {
      const root = document.documentElement;
      const style = window.getComputedStyle(root);
      const accentColor = style.getPropertyValue("--accent").trim();
      const bgColor = style.getPropertyValue("--content-bg").trim() ||
        window.getComputedStyle(document.body).backgroundColor;

      // Verify the compiled CSS has border-color: var(--accent...) for :focus
      // by scanning the document's stylesheets.
      let focusRuleUsesVar = false;
      for (const sheet of Array.from(document.styleSheets)) {
        try {
          for (const rule of Array.from(sheet.cssRules)) {
            if (rule instanceof CSSStyleRule &&
                rule.selectorText?.includes(":focus") &&
                rule.selectorText?.toLowerCase().includes("form-input") &&
                rule.style.borderColor?.includes("var(--accent")) {
              focusRuleUsesVar = true;
            }
          }
        } catch { /* cross-origin sheet */ }
      }
      return { accentColor, bgColor, focusRuleUsesVar };
    });

    // 1. The CSS :focus rule must use var(--accent), not a hardcoded colour.
    expect(
      focusRuleUsesVar,
      `The :focus rule on .form-input does not use var(--accent).\n` +
        `Fix: replace "border-color: #002b4a" with "border-color: var(--accent)" in ` +
        `Layout.module.scss .form-input:focus.`,
    ).toBe(true);

    // 2. In dark mode, --accent must have adequate contrast vs the content background.
    // Convert CSS hex colour to rgb() string for contrastRatio helper.
    const toRgb = (hex: string): string => {
      const h = hex.replace("#", "");
      const r = parseInt(h.substring(0, 2), 16);
      const g = parseInt(h.substring(2, 4), 16);
      const b = parseInt(h.substring(4, 6), 16);
      return `rgb(${r}, ${g}, ${b})`;
    };
    const accentRgb = accentColor.startsWith("#") ? toRgb(accentColor) : accentColor;
    const bgRgb     = bgColor.startsWith("#")     ? toRgb(bgColor)     : bgColor;
    const ratio = contrastRatio(accentRgb, bgRgb);
    expect(
      ratio,
      `Dark-mode --accent (${accentColor}) vs --content-bg (${bgColor}): ` +
        `contrast ${isNaN(ratio) ? "NaN" : ratio.toFixed(2)}:1 — ` +
        `WCAG AA for UI components requires ≥ ${WCAG_AA_LARGE}:1.\n` +
        `Fix: ensure --accent in [data-theme="dark"] is a light colour (e.g. #29d9ff).`,
    ).toBeGreaterThanOrEqual(WCAG_AA_LARGE);
  });
});
