import { test, expect } from "@playwright/test";

test.describe("Logs page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/logs");
    await page.waitForTimeout(600);
  });

  test("shows logs page heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: /Request Logs/i })).toBeVisible();
  });

  test("shows tenant filter select", async ({ page }) => {
    await expect(page.locator("select").first()).toBeVisible();
  });

  test("shows provider filter with expected options", async ({ page }) => {
    const selects = page.locator("select");
    // Second select is provider filter
    const providerSelect = selects.nth(1);
    await expect(providerSelect).toBeVisible();
    await expect(providerSelect.locator("option", { hasText: "anthropic" })).toHaveCount(1);
  });

  test("shows limit filter select", async ({ page }) => {
    // There should be at least 3 selects: tenant, provider, limit
    const count = await page.locator("select").count();
    expect(count).toBeGreaterThanOrEqual(3);
  });

  test("shows table or empty state", async ({ page }) => {
    const hasTable = await page.locator("table").isVisible().catch(() => false);
    const hasEmpty = await page.getByText(/No logs|No requests/i).isVisible().catch(() => false);
    expect(hasTable || hasEmpty).toBe(true);
  });

  test("table has time and provider columns when data present", async ({ page }) => {
    const table = page.locator("table");
    if (!await table.isVisible()) { test.skip(); return; }
    await expect(page.getByRole("columnheader", { name: /Time|ts/i }).first()).toBeVisible();
    await expect(page.getByRole("columnheader", { name: /Provider/i })).toBeVisible();
  });

  test("refresh button is visible", async ({ page }) => {
    await expect(page.getByRole("button", { name: /Refresh/i })).toBeVisible();
  });
});
