import { test, expect } from "./base";

const ADMIN_BASE = (process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173") + "/admin/v1";

async function apiDeletePrice(page: import("@playwright/test").Page, provider: string, model: string) {
  await page.context().request.delete(`${ADMIN_BASE}/model-prices/${provider}/${model}`).catch(() => {});
}

test.describe("Model Prices page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/model-prices");
    await page.waitForLoadState("networkidle");
  });

  test("shows model prices table with data", async ({ page }) => {
    await expect(page.getByRole("heading", { name: /Model Prices/i })).toBeVisible();
    await expect(page.locator("table")).toBeVisible();
    const rows = await page.locator("tbody tr").count();
    expect(rows).toBeGreaterThan(0);
  });

  test("shows provider filter buttons", async ({ page }) => {
    await expect(page.getByRole("button", { name: /^All$/i })).toBeVisible();
    await expect(page.getByRole("button", { name: /^anthropic$/i })).toBeVisible();
    await expect(page.getByRole("button", { name: /^openai$/i })).toBeVisible();
    await expect(page.getByRole("button", { name: /^gemini$/i })).toBeVisible();
  });

  test("filtering by provider narrows results", async ({ page }) => {
    const allRows = await page.locator("tbody tr").count();
    await page.getByRole("button", { name: /^anthropic$/i }).click();
    const filteredRows = await page.locator("tbody tr").count();
    expect(filteredRows).toBeLessThanOrEqual(allRows);
    // All visible rows should show anthropic
    const cells = page.locator("tbody tr td:first-child");
    for (let i = 0; i < await cells.count(); i++) {
      await expect(cells.nth(i)).toContainText("anthropic");
    }
  });

  test("All filter restores full list", async ({ page }) => {
    await page.getByRole("button", { name: /^anthropic$/i }).click();
    const filtered = await page.locator("tbody tr").count();
    await page.getByRole("button", { name: /^All$/i }).click();
    const all = await page.locator("tbody tr").count();
    expect(all).toBeGreaterThanOrEqual(filtered);
  });

  test("Add Price modal opens with all fields including Cache Write 1h", async ({ page }) => {
    await page.getByRole("button", { name: /\+ New Price/i }).click();
    await expect(page.getByRole("heading", { name: /New Model Price/i })).toBeVisible();
    await expect(page.getByLabel("Provider")).toBeVisible();
    await expect(page.getByLabel("Model *")).toBeVisible();
    await expect(page.getByLabel(/Input \$\/1K/i)).toBeVisible();
    await expect(page.getByLabel(/Output \$\/1K/i)).toBeVisible();
    await expect(page.getByLabel(/Cache Write 5m/i)).toBeVisible();
    await expect(page.getByLabel(/Cache Write 1h/i)).toBeVisible();
    await expect(page.getByLabel(/Cache Read/i)).toBeVisible();
  });

  test("Edit button opens edit modal with provider/model disabled", async ({ page }) => {
    const editBtn = page.getByRole("button", { name: /^Edit$/i }).first();
    await editBtn.click();
    await expect(page.getByRole("heading", { name: /Edit:/i })).toBeVisible();
    await expect(page.getByLabel("Provider")).toBeDisabled();
    await expect(page.getByLabel("Model *")).toBeDisabled();
    // Price fields should be editable
    await expect(page.getByLabel(/Input \$\/1K/i)).toBeEnabled();
  });

  test("modal closes on Cancel", async ({ page }) => {
    await page.getByRole("button", { name: /\+ New Price/i }).click();
    await page.getByRole("button", { name: /Cancel/i }).click();
    await expect(page.getByRole("heading", { name: /New Model Price/i })).not.toBeVisible();
  });

  test("table has correct columns including Cache Write 1h", async ({ page }) => {
    await expect(page.getByRole("columnheader", { name: /Provider/i })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: /Model/i })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: /Input/i })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: /Output/i })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: /Cache Write 5m/i })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: /Cache Write 1h/i })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: /Cache Read/i })).toBeVisible();
  });

  test("subtitle shows entry count", async ({ page }) => {
    const subtitle = page.locator("p").filter({ hasText: /entries/i });
    await expect(subtitle).toBeVisible();
    await expect(subtitle).toContainText(/\d+ entries/);
  });

  test("anthropic entries show Cache Write 1h values in the table", async ({ page }) => {
    await page.getByRole("button", { name: /^anthropic$/i }).click();
    // claude-sonnet-4-6 should have $0.006000 in the 1h column
    const sonnetRow = page.getByRole("row", { name: /claude-sonnet-4-6/ }).first();
    await expect(sonnetRow).toBeVisible();
    // 1h column is the 6th td (Provider, Model, Input, Output, CW5m, CW1h, CR, Updated, Actions)
    const cw1hCell = sonnetRow.locator("td").nth(5);
    await expect(cw1hCell).toContainText("$0.006");
  });

  test("creates a new price entry and verifies it via API, then deletes it", async ({ page, workerSuffix }) => {
    const model = `e2e-model-${workerSuffix}`;
    try {
      await page.getByRole("button", { name: /\+ New Price/i }).click();

      await page.getByLabel("Provider").selectOption("anthropic");
      await page.getByLabel("Model *").fill(model);
      await page.getByLabel(/Input \$\/1K tokens \*/i).fill("0.001");
      await page.getByLabel(/Output \$\/1K tokens \*/i).fill("0.005");
      await page.getByLabel(/Cache Write 5m/i).fill("0.00125");
      await page.getByLabel(/Cache Write 1h/i).fill("0.002");
      await page.getByLabel(/Cache Read/i).fill("0.0001");

      await page.getByRole("button", { name: /Add Price/i }).click();
      await expect(page.getByRole("heading", { name: /New Model Price/i })).not.toBeVisible({ timeout: 5000 });

      // Row appears in table
      await expect(page.getByRole("row", { name: new RegExp(model) })).toBeVisible();

      // Verify via API
      const r = await page.context().request.get(`${ADMIN_BASE}/model-prices`);
      expect(r.ok()).toBeTruthy();
      const prices = await r.json() as Array<{ provider: string; model: string; cache_write_1h_per_1k: number | null }>;
      const saved = prices.find((p) => p.provider === "anthropic" && p.model === model);
      expect(saved).toBeTruthy();
      expect(saved?.cache_write_1h_per_1k).toBeCloseTo(0.002, 5);

      // No error banner
      await expect(page.getByText(/error/i).first()).not.toBeVisible();
    } finally {
      await apiDeletePrice(page, "anthropic", model);
    }
  });

  test("edits a price entry and verifies cache_write_1h field is saved", async ({ page, workerSuffix }) => {
    const model = `e2e-edit-price-${workerSuffix}`;
    try {
      // Create via API
      await page.context().request.put(`${ADMIN_BASE}/model-prices`, {
        data: { provider: "anthropic", model, input_per_1k: 0.001, output_per_1k: 0.005, cache_write_per_1k: 0.00125, cache_write_1h_per_1k: 0.002, cache_read_per_1k: 0.0001 },
      });

      await page.reload();
      await page.waitForLoadState("networkidle");

      const row = page.getByRole("row", { name: new RegExp(model) });
      await expect(row).toBeVisible();
      await row.getByRole("button", { name: /^Edit$/i }).click();

      await expect(page.getByRole("heading", { name: /Edit:/ })).toBeVisible();
      // 1h field should be pre-populated
      await expect(page.getByLabel(/Cache Write 1h/i)).toHaveValue("0.002");

      // Update to new value
      await page.getByLabel(/Cache Write 1h/i).fill("0.003");
      await page.getByRole("button", { name: /Save Changes/i }).click();
      await expect(page.getByRole("heading", { name: /Edit:/ })).not.toBeVisible({ timeout: 5000 });

      // Verify via API
      const r = await page.context().request.get(`${ADMIN_BASE}/model-prices`);
      const prices = await r.json() as Array<{ provider: string; model: string; cache_write_1h_per_1k: number | null }>;
      const saved = prices.find((p) => p.model === model);
      expect(saved?.cache_write_1h_per_1k).toBeCloseTo(0.003, 5);
    } finally {
      await apiDeletePrice(page, "anthropic", model);
    }
  });

  test("deletes a price entry and it disappears from the table", async ({ page, workerSuffix }) => {
    const model = `e2e-del-price-${workerSuffix}`;
    // Create via API
    await page.context().request.put(`${ADMIN_BASE}/model-prices`, {
      data: { provider: "anthropic", model, input_per_1k: 0.001, output_per_1k: 0.005 },
    });

    await page.reload();
    await page.waitForLoadState("networkidle");
    await expect(page.getByRole("row", { name: new RegExp(model) })).toBeVisible();

    page.on("dialog", (d) => d.accept());
    await page.getByRole("row", { name: new RegExp(model) })
      .getByRole("button", { name: /Delete/i }).click();

    await expect(page.getByRole("row", { name: new RegExp(model) })).not.toBeVisible({ timeout: 5000 });
  });

  test("Sync from Providers button shows a result message", async ({ page }) => {
    await page.getByRole("button", { name: /Sync from Providers/i }).click();
    // Wait for the result message — either success or error
    await expect(
      page.getByText(/Synced:|All models up to date|Sync failed/i)
    ).toBeVisible({ timeout: 30000 });
  });
});
