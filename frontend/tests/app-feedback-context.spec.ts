/**
 * app-feedback-context.spec.ts — verify the AppFeedbackWidget attaches a
 * Layer-1 client_context blob to its POST and that the recognised fields
 * mirror runtime state (route, viewport, timezone, color scheme,
 * schema_version).
 *
 * Tests intercept the outgoing POST in-flight; no DB inspection needed for
 * the wire-format assertions. Cleanup deletes the persisted row to keep
 * subsequent runs clean.
 */

import { test, expect, Page } from "@playwright/test";
import { execSync } from "child_process";

const ADMIN_BASE = process.env.PLAYWRIGHT_ADMIN_URL
  ? `${process.env.PLAYWRIGHT_ADMIN_URL}/admin/v1`
  : "http://localhost:5173/admin/v1";

const DB_HOST = process.env.E2E_DB_HOST ?? "172.17.0.1";
const DB_USER = process.env.E2E_DB_USER ?? "gateway_int";
const DB_PASS = process.env.E2E_DB_PASS ?? "yefVaf]oresev8";
const DB_NAME = process.env.E2E_DB_NAME ?? "ai_gateway_int";

function sql(query: string) {
  execSync(
    `mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} ${DB_NAME} -e ${JSON.stringify(query)}`,
    { stdio: "pipe" }
  );
}

async function openWidgetAndCapturePOST(page: Page, summary: string) {
  const captured = page.waitForRequest(
    req => req.method() === "POST" && req.url().includes("/admin/v1/app-feedback"),
    { timeout: 10000 }
  );
  // Open the widget via the sidebar's send-feedback button.
  await page.locator("[data-cy='app-feedback-btn']").click();
  await page.locator("[data-cy='app-feedback-summary']").fill(summary);
  await page.locator("[data-cy='app-feedback-submit']").click();
  return captured;
}

async function deleteRowsBySummary(summary: string) {
  sql(`DELETE FROM app_feedback WHERE summary = ${JSON.stringify(summary)}`);
}

// Pre-acknowledge the AIDisclosureModal so its overlay does not intercept
// clicks on the sidebar feedback button.
test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    try { localStorage.setItem("aig:ai-disclosure-acknowledged-v1", "1"); } catch { /* ignore */ }
  });
});

test.describe("app-feedback Layer 1 client_context", () => {
  test("payload includes current_route from window.location", async ({ page }) => {
    const summary = `e2e-ctx-route-${Date.now()}`;
    await page.goto("/projects");
    await expect(page.locator("[data-cy='app-feedback-btn']")).toBeVisible();
    const reqP = openWidgetAndCapturePOST(page, summary);
    const req  = await reqP;
    const body = req.postDataJSON();
    expect(body.client_context).toBeDefined();
    expect(body.client_context.current_route).toBe("/projects");
    await deleteRowsBySummary(summary);
  });

  test("viewport in payload matches Playwright's configured viewport", async ({ page, browser }) => {
    const ctx = await browser.newContext({
      viewport: { width: 1234, height: 567 },
      storageState: "tests/.auth/docker-session.json",
    });
    await ctx.addInitScript(() => {
      try { localStorage.setItem("aig:ai-disclosure-acknowledged-v1", "1"); } catch { /* ignore */ }
    });
    try {
      const p = await ctx.newPage();
      await p.goto("/dashboard");
      await expect(p.locator("[data-cy='app-feedback-btn']")).toBeVisible();
      const summary = `e2e-ctx-viewport-${Date.now()}`;
      const reqP = openWidgetAndCapturePOST(p, summary);
      const req  = await reqP;
      const body = req.postDataJSON();
      expect(body.client_context.viewport.w).toBe(1234);
      expect(body.client_context.viewport.h).toBe(567);
      await deleteRowsBySummary(summary);
    } finally {
      await ctx.close();
    }
  });

  test("timezone and locale match navigator values", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page.locator("[data-cy='app-feedback-btn']")).toBeVisible();
    const navTimezone = await page.evaluate(() => Intl.DateTimeFormat().resolvedOptions().timeZone);
    const navLocale   = await page.evaluate(() => navigator.language);
    const summary = `e2e-ctx-tz-${Date.now()}`;
    const reqP = openWidgetAndCapturePOST(page, summary);
    const req  = await reqP;
    const body = req.postDataJSON();
    expect(body.client_context.timezone).toBe(navTimezone);
    expect(body.client_context.locale).toBe(navLocale);
    await deleteRowsBySummary(summary);
  });

  test("color_scheme follows the active theme", async ({ page, browser }) => {
    const ctx = await browser.newContext({
      colorScheme: "dark",
      storageState: "tests/.auth/docker-session.json",
    });
    await ctx.addInitScript(() => {
      try { localStorage.setItem("aig:ai-disclosure-acknowledged-v1", "1"); } catch { /* ignore */ }
    });
    try {
      const p = await ctx.newPage();
      await p.goto("/dashboard");
      await expect(p.locator("[data-cy='app-feedback-btn']")).toBeVisible();
      const summary = `e2e-ctx-dark-${Date.now()}`;
      const reqP = openWidgetAndCapturePOST(p, summary);
      const req  = await reqP;
      const body = req.postDataJSON();
      expect(body.client_context.color_scheme).toBe("dark");
      await deleteRowsBySummary(summary);
    } finally {
      await ctx.close();
    }
  });

  test("schema_version is the integer 1", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page.locator("[data-cy='app-feedback-btn']")).toBeVisible();
    const summary = `e2e-ctx-schema-${Date.now()}`;
    const reqP = openWidgetAndCapturePOST(page, summary);
    const req  = await reqP;
    const body = req.postDataJSON();
    expect(body.client_context.schema_version).toBe(1);
    await deleteRowsBySummary(summary);
  });
});
