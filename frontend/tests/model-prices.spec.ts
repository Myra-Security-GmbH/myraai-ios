import { test, expect } from "@playwright/test";

test.describe("Model Prices page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/model-prices");
    await page.waitForTimeout(400);
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
    await page.waitForTimeout(100);
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
    await page.waitForTimeout(100);
    const all = await page.locator("tbody tr").count();
    expect(all).toBeGreaterThanOrEqual(filtered);
  });

  test("Add Price modal opens with all fields", async ({ page }) => {
    await page.getByRole("button", { name: /\+ Add Price/i }).click();
    await expect(page.getByRole("heading", { name: /Add Model Price/i })).toBeVisible();
    await expect(page.getByLabel("Provider")).toBeVisible();
    await expect(page.getByLabel("Model *")).toBeVisible();
    await expect(page.getByLabel(/Input \$\/1K/i)).toBeVisible();
    await expect(page.getByLabel(/Output \$\/1K/i)).toBeVisible();
    await expect(page.getByLabel(/Cache Write/i)).toBeVisible();
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
    await page.getByRole("button", { name: /\+ Add Price/i }).click();
    await page.getByRole("button", { name: /Cancel/i }).click();
    await expect(page.getByRole("heading", { name: /Add Model Price/i })).not.toBeVisible();
  });

  test("table has correct columns", async ({ page }) => {
    await expect(page.getByRole("columnheader", { name: /Provider/i })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: /Model/i })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: /Input/i })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: /Output/i })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: /Cache Write/i })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: /Cache Read/i })).toBeVisible();
  });

  test("subtitle shows entry count", async ({ page }) => {
    const subtitle = page.locator("p").filter({ hasText: /entries/i });
    await expect(subtitle).toBeVisible();
    await expect(subtitle).toContainText(/\d+ entries/);
  });
});
