/**
 * screenshots.spec.ts — captures admin UI screenshots for the documentation.
 *
 * Run via create_snapshot.sh (project root), or directly:
 *   npx playwright test tests/screenshots.spec.ts --project=chromium
 *
 * Output: docs/docs.md/assets/screenshots/*.png
 * Each test always saves a screenshot, even when there is no live data — the
 * structural UI (empty state) is still useful for new users.
 */

import { test, Page } from "@playwright/test";
import path from "path";
import fs from "fs";

// ---------------------------------------------------------------------------
// Output directory
// ---------------------------------------------------------------------------

const OUT = path.resolve(__dirname, "../../docs/docs.md/assets/screenshots");
fs.mkdirSync(OUT, { recursive: true });

function snap(name: string) {
  return { path: path.join(OUT, name), animations: "disabled" as const };
}

// ---------------------------------------------------------------------------
// Navigation helpers (mirrors patterns in gateways.spec.ts)
// ---------------------------------------------------------------------------

async function waitReady(page: Page) {
  await page.waitForLoadState("networkidle");
  // Dismiss any lingering loading spinners before snapping
  await page.waitForTimeout(400);
}

/** Click the "myratest" tenant button on /gateways. Returns false when not found. */
async function selectMyratest(page: Page): Promise<boolean> {
  const btn = page.getByRole("button", { name: /^myratest$/i });
  if (!await btn.isVisible().catch(() => false)) return false;
  await btn.click();
  await page.waitForTimeout(600);
  return true;
}

/** Open the first available gateway's detail page. Returns false when none. */
async function openFirstGateway(page: Page): Promise<boolean> {
  const ok = await selectMyratest(page);
  if (!ok) return false;
  const btn = page.getByRole("button", { name: /Open →/i }).first();
  if (!await btn.isVisible().catch(() => false)) return false;
  await btn.click();
  await page.waitForTimeout(600);
  return true;
}

// ---------------------------------------------------------------------------
// 1. Dashboard overview
// ---------------------------------------------------------------------------

test("dashboard-overview", async ({ page }) => {
  await page.goto("/dashboard");
  await waitReady(page);
  await page.screenshot(snap("dashboard-overview.png"));
});

// ---------------------------------------------------------------------------
// 2. Analytics tabs
// ---------------------------------------------------------------------------

test("analytics-tabs", async ({ page }) => {
  await page.goto("/analytics");
  await waitReady(page);
  await page.screenshot(snap("analytics-tabs.png"));
});

// ---------------------------------------------------------------------------
// 3. Tenants list
// ---------------------------------------------------------------------------

test("tenants-list", async ({ page }) => {
  await page.goto("/tenants");
  await waitReady(page);
  await page.screenshot(snap("tenants-list.png"));
});

// ---------------------------------------------------------------------------
// 4. Gateway list (after selecting a tenant)
// ---------------------------------------------------------------------------

test("gateway-list", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  // Try to select a tenant so the gateway list is visible; fall back to the
  // initial "Select Tenant" view if no tenants exist.
  await selectMyratest(page).catch(() => {});
  await page.screenshot(snap("gateway-list.png"));
});

// ---------------------------------------------------------------------------
// 5. Gateway detail
// ---------------------------------------------------------------------------

test("gateway-detail", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  const opened = await openFirstGateway(page);
  if (!opened) {
    // No gateway available — screenshot the gateway list as fallback
    await selectMyratest(page).catch(() => {});
  }
  await page.screenshot(snap("gateway-detail.png"));
});

// ---------------------------------------------------------------------------
// 6. Gateway edit modal (config form)
// ---------------------------------------------------------------------------

test("gateway-edit-modal", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  const opened = await openFirstGateway(page);
  if (opened) {
    const editBtn = page.getByRole("button", { name: /^Edit$/i }).first();
    if (await editBtn.isVisible().catch(() => false)) {
      await editBtn.click();
      await page.waitForTimeout(400);
    }
  }
  await page.screenshot(snap("gateway-edit-modal.png"));
});

// ---------------------------------------------------------------------------
// 7. Routing rule editor modal
// ---------------------------------------------------------------------------

test("routing-rule-editor", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  const opened = await openFirstGateway(page);
  if (opened) {
    const newRuleBtn = page.getByRole("button", { name: /\+ New Rule/i });
    if (await newRuleBtn.isVisible().catch(() => false)) {
      await newRuleBtn.click();
      await page.waitForTimeout(400);
      // Add one condition so the modal shows a populated state
      const addCondBtn = page.getByRole("button", { name: /^\+ Add$/i }).first();
      if (await addCondBtn.isVisible().catch(() => false)) {
        await addCondBtn.click();
        await page.waitForTimeout(200);
      }
    }
  }
  await page.screenshot(snap("routing-rule-editor.png"));
});

// ---------------------------------------------------------------------------
// 8. Guardrails builder (Guardrails card on the gateway detail page)
// ---------------------------------------------------------------------------

test("guardrails-builder", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  const opened = await openFirstGateway(page);
  if (opened) {
    // Scroll to the "Save Guardrails" button — unique to the Guardrails card
    // on the detail page (NOT inside the Edit modal).
    const saveBtn = page.getByRole("button", { name: /Save Guardrails/i });
    if (await saveBtn.isVisible().catch(() => false)) {
      await saveBtn.scrollIntoViewIfNeeded();
      await page.waitForTimeout(200);
    }
  }
  await page.screenshot(snap("guardrails-builder.png"));
});

// ---------------------------------------------------------------------------
// 9. Playground layout
// ---------------------------------------------------------------------------

test("playground-layout", async ({ page }) => {
  await page.goto("/playground");
  await waitReady(page);
  // Select the myratest tenant if available
  const tenantSelect = page.locator("select").first();
  if (await tenantSelect.isVisible().catch(() => false)) {
    const options = await tenantSelect.locator("option").allTextContents();
    if (options.some(o => /myratest/i.test(o))) {
      await tenantSelect.selectOption({ label: "myratest" });
      await page.waitForTimeout(600);
    }
  }
  await page.screenshot(snap("playground-layout.png"));
});

// ---------------------------------------------------------------------------
// 10. Request log table
// ---------------------------------------------------------------------------

test("logs-table", async ({ page }) => {
  await page.goto("/logs");
  await waitReady(page);
  await page.screenshot(snap("logs-table.png"));
});
