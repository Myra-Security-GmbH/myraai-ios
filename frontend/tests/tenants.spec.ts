import { test, expect } from "@playwright/test";

test.describe("Tenants page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/tenants");
    await page.waitForTimeout(400);
  });

  test("shows tenants list", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Tenants" })).toBeVisible();
    const hasTable = await page.locator("table").isVisible().catch(() => false);
    const hasEmpty = await page.getByText(/No tenants yet/).isVisible().catch(() => false);
    expect(hasTable || hasEmpty).toBe(true);
  });

  test("tenant rows are clickable and show detail view", async ({ page }) => {
    const rows = page.locator("tbody tr");
    if (await rows.count() === 0) { test.skip(); return; }
    await rows.first().click();
    await expect(page.getByText(/← Tenants/i)).toBeVisible();
    await expect(page.getByText(/Tenant:/i)).toBeVisible();
  });

  test("tenant detail shows config stats", async ({ page }) => {
    const rows = page.locator("tbody tr");
    if (await rows.count() === 0) { test.skip(); return; }
    await rows.first().click();
    await expect(page.getByText("Plan")).toBeVisible();
    await expect(page.getByText("Budget Limit")).toBeVisible();
  });

  test("back button returns to list", async ({ page }) => {
    const rows = page.locator("tbody tr");
    if (await rows.count() === 0) { test.skip(); return; }
    await rows.first().click();
    await page.getByText(/← Tenants/i).click();
    await expect(page.getByRole("heading", { name: "Tenants" })).toBeVisible();
  });

  test("open New Tenant modal and check fields", async ({ page }) => {
    await page.getByRole("button", { name: /New Tenant/i }).click();
    await expect(page.getByRole("heading", { name: /New Tenant/i })).toBeVisible();
    await expect(page.getByLabel("Slug *")).toBeVisible();
    await expect(page.getByLabel("Plan")).toBeVisible();
    await expect(page.getByLabel("Budget (USD)")).toBeVisible();
  });

  test("create tenant modal validates slug required", async ({ page }) => {
    await page.getByRole("button", { name: /New Tenant/i }).click();
    await page.getByRole("button", { name: /Create Tenant/i }).click();
    const slug = page.getByLabel("Slug *");
    await expect(slug).toBeFocused();
  });

  test("close modal with Cancel button", async ({ page }) => {
    await page.getByRole("button", { name: /New Tenant/i }).click();
    await page.getByRole("button", { name: /Cancel/i }).click();
    await expect(page.getByRole("heading", { name: /New Tenant/i })).not.toBeVisible();
  });

  test("close modal by clicking overlay", async ({ page }) => {
    await page.getByRole("button", { name: /New Tenant/i }).click();
    await page.mouse.click(10, 10);
    await expect(page.getByRole("heading", { name: /New Tenant/i })).not.toBeVisible();
  });

  test("tenant detail Edit button opens edit modal", async ({ page }) => {
    const rows = page.locator("tbody tr");
    if (await rows.count() === 0) { test.skip(); return; }
    await rows.first().click();
    await page.getByRole("button", { name: /^Edit$/i }).first().click();
    await expect(page.getByRole("heading", { name: /Edit:/i })).toBeVisible();
    await expect(page.getByLabel("Plan")).toBeVisible();
    await expect(page.getByLabel("Budget (USD)")).toBeVisible();
  });

  test("tenant detail shows gateway list section", async ({ page }) => {
    const rows = page.locator("tbody tr");
    if (await rows.count() === 0) { test.skip(); return; }
    await rows.first().click();
    await expect(page.getByRole("heading", { name: /Gateways/i })).toBeVisible();
  });

  test("Open → button navigates to gateway detail", async ({ page }) => {
    const openBtn = page.getByRole("button", { name: /Open →/i }).first();
    if (!await openBtn.isVisible()) { test.skip(); return; }
    await openBtn.click();
    await expect(page.getByRole("button", { name: /← Tenants/i })).toBeVisible();
  });
});
