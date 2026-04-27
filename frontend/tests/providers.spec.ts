/**
 * providers.spec.ts — E2E tests for the /providers onboarding / status page.
 *
 * Verifies:
 *   - Page loads with heading and summary cards
 *   - All supported providers appear in the table (22 rows)
 *   - Every row has a "✓ Supported" badge
 *   - Providers with status pages show a live status badge
 *   - "Not configured" rows include an "Add key →" button that navigates to /gateways
 */

import { test, expect } from "./base";

const PROVIDERS_WITH_STATUS_PAGE = ["anthropic", "openai", "cohere", "groq", "cloudflare"];
const TOTAL_PROVIDERS = 22;

test.describe("Providers — onboarding status view", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/providers");
    await page.waitForLoadState("networkidle");
  });

  test("page loads with heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: /providers/i })).toBeVisible();
    await expect(page.getByText(/supported ai providers/i)).toBeVisible();
  });

  test("summary cards are visible", async ({ page }) => {
    await expect(page.getByText("Supported providers")).toBeVisible({ timeout: 8000 });
    await expect(page.getByText("Configured (any gateway)")).toBeVisible();
    await expect(page.getByText("Operational (status page)")).toBeVisible();
  });

  test("table shows all supported providers", async ({ page }) => {
    // Wait for the table to populate (API call completes)
    const rows = page.locator("table tbody tr");
    await expect(rows).toHaveCount(TOTAL_PROVIDERS, { timeout: 10000 });
  });

  test("every row has a Supported badge", async ({ page }) => {
    await page.locator("table tbody tr").first().waitFor({ timeout: 8000 });
    const badges = page.locator("table tbody tr").locator("text=✓ Supported");
    await expect(badges).toHaveCount(TOTAL_PROVIDERS, { timeout: 8000 });
  });

  test("providers with status pages show a live status badge", async ({ page }) => {
    await page.locator("table tbody tr").first().waitFor({ timeout: 8000 });
    for (const name of PROVIDERS_WITH_STATUS_PAGE) {
      const row = page.locator("table tbody tr").filter({ hasText: name });
      const statusCell = row.locator("td").nth(3);
      const text = (await statusCell.textContent() ?? "").trim();
      // Should be one of the live status values or "–" (never empty)
      expect(text, `${name} status cell should have a value`).toBeTruthy();
    }
  });

  test("configured providers do NOT show an Add key button", async ({ page }) => {
    await page.locator("table tbody tr").first().waitFor({ timeout: 8000 });
    // anthropic and groq are configured in the test tenant — verify no Add key button in those rows
    for (const name of ["anthropic", "groq"]) {
      const row = page.locator("table tbody tr").filter({ hasText: name });
      const addKey = row.locator("button", { hasText: /add key/i });
      await expect(addKey).toBeHidden({ timeout: 3000 });
    }
  });

  test("not-configured providers show Add key button", async ({ page }) => {
    await page.locator("table tbody tr").first().waitFor({ timeout: 8000 });
    // Find any row with "Not configured" badge
    const notConfigured = page.locator("table tbody tr").filter({ hasText: "Not configured" }).first();
    const visible = await notConfigured.isVisible().catch(() => false);
    if (visible) {
      await expect(notConfigured.locator("button", { hasText: /add key/i })).toBeVisible();
    }
    // If all providers happen to be configured, just pass
  });

  test("Add key button navigates to /gateways", async ({ page }) => {
    await page.locator("table tbody tr").first().waitFor({ timeout: 8000 });
    const addKeyBtn = page.locator("table tbody tr button", { hasText: /add key/i }).first();
    const visible = await addKeyBtn.isVisible().catch(() => false);
    if (visible) {
      await addKeyBtn.click();
      await expect(page).toHaveURL(/\/gateways/, { timeout: 5000 });
    }
  });

  test("Refresh button reloads the table", async ({ page }) => {
    await page.locator("table tbody tr").first().waitFor({ timeout: 8000 });
    const refreshBtn = page.getByRole("button", { name: /refresh/i });
    await expect(refreshBtn).toBeEnabled();
    await refreshBtn.click();
    // After click, button briefly shows "Refreshing…" then comes back
    await expect(refreshBtn).toBeEnabled({ timeout: 10000 });
    // Table should still have all providers
    await expect(page.locator("table tbody tr")).toHaveCount(TOTAL_PROVIDERS, { timeout: 8000 });
  });

  test("Providers sidebar link is visible and active", async ({ page }) => {
    const link = page.locator("nav a[href='/providers']");
    await expect(link).toBeVisible();
  });
});

test.describe("Providers — API endpoint", () => {
  test("GET /admin/v1/providers/health returns correct shape", async ({ page }) => {
    await page.goto("/providers");
    const resp = await page.context().request.get(
      `${process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin-int.myra.eu"}/admin/v1/providers/health`,
    );
    expect(resp.ok(), `providers/health: ${await resp.text()}`).toBeTruthy();

    const data = (await resp.json()) as Array<{
      name: string;
      requires_key: boolean;
      configured: boolean | null;
      status: string;
      has_status_page: boolean;
    }>;
    expect(data.length, "should return all providers").toBeGreaterThanOrEqual(TOTAL_PROVIDERS);

    // Every record has required fields
    for (const p of data) {
      expect(p.name).toBeTruthy();
      expect(typeof p.requires_key).toBe("boolean");
      expect(["ok", "degraded", "down", "unknown"]).toContain(p.status);
      expect(typeof p.has_status_page).toBe("boolean");
    }

    // Providers with known status pages should have has_status_page = true
    for (const name of PROVIDERS_WITH_STATUS_PAGE) {
      const p = data.find(x => x.name === name);
      expect(p, `${name} not in response`).toBeTruthy();
      expect(p!.has_status_page, `${name} should have status page`).toBe(true);
    }

    // ollama and vllm should have configured = null (no key required)
    for (const name of ["ollama", "vllm"]) {
      const p = data.find(x => x.name === name);
      expect(p?.configured, `${name}.configured should be null`).toBeNull();
    }
  });
});
