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

  // ── new filter controls ────────────────────────────────────────────────────

  test("shows model text input filter", async ({ page }) => {
    await expect(page.getByPlaceholder(/e\.g\. gpt-4o/i)).toBeVisible();
  });

  test("shows status filter select with key options", async ({ page }) => {
    // Use locator("label") to avoid matching <th>Status</th> in the table header
    const statusLabel = page.locator("label").filter({ hasText: /^Status$/ });
    await expect(statusLabel).toBeVisible();
    const statusSelect = statusLabel.locator("..").locator("select");
    await expect(statusSelect).toBeVisible();
    await expect(statusSelect.locator("option[value='200']")).toHaveCount(1);
    await expect(statusSelect.locator("option[value='429']")).toHaveCount(1);
    await expect(statusSelect.locator("option[value='500']")).toHaveCount(1);
  });

  test("shows blocked filter select", async ({ page }) => {
    // Use locator("label") to avoid matching <option>Blocked</option> in guardrail select
    const blockedLabel = page.locator("label").filter({ hasText: /^Blocked$/ });
    await expect(blockedLabel).toBeVisible();
    const blockedSelect = blockedLabel.locator("..").locator("select");
    await expect(blockedSelect).toBeVisible();
    await expect(blockedSelect.locator("option", { hasText: /Blocked only/i })).toHaveCount(1);
  });

  test("total filter count includes new filters", async ({ page }) => {
    // tenant + provider + status + blocked + guardrail + limit = at least 6 selects
    const count = await page.locator("select").count();
    expect(count).toBeGreaterThanOrEqual(6);
  });

  test("model filter input accepts text and triggers reload", async ({ page }) => {
    const modelInput = page.getByPlaceholder(/e\.g\. gpt-4o/i);
    await modelInput.fill("gpt-4o-mini");
    await page.waitForTimeout(300);
    // Page should not crash and should still show heading
    await expect(page.getByRole("heading", { name: /Request Logs/i })).toBeVisible();
  });

  test("status filter select changes selection without errors", async ({ page }) => {
    const statusGroup = page.locator("label", { hasText: /^Status$/ }).locator("..");
    const statusSelect = statusGroup.locator("select");
    await statusSelect.selectOption("200");
    await page.waitForTimeout(300);
    await expect(page.getByRole("heading", { name: /Request Logs/i })).toBeVisible();
    // revert
    await statusSelect.selectOption("");
  });

  test("blocked filter restricts to blocked rows only", async ({ page }) => {
    const blockedGroup = page.locator("label", { hasText: /^Blocked$/ }).locator("..");
    const blockedSelect = blockedGroup.locator("select");
    await blockedSelect.selectOption("1");
    await page.waitForTimeout(300);
    // If table is shown, every row should have the blocked badge
    const table = page.locator("table");
    if (!await table.isVisible()) return; // empty state is fine too
    const rows = page.locator("tbody tr");
    for (let i = 0; i < Math.min(await rows.count(), 5); i++) {
      await expect(rows.nth(i).getByText("blocked")).toBeVisible();
    }
  });

  test("no JS runtime errors on load", async ({ page }) => {
    const errors: string[] = [];
    page.on("console", (msg) => {
      if (msg.type() === "error") errors.push(msg.text());
    });
    await page.goto("/logs");
    await page.waitForTimeout(800);
    const fatal = errors.filter(
      (e) =>
        !e.includes("favicon") &&
        !e.includes("net::ERR") &&
        !e.includes("403") &&
        !e.includes("Failed to load resource"),
    );
    expect(fatal).toHaveLength(0);
  });
});
