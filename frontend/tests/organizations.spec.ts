import { test, expect } from "@playwright/test";

test.describe("Organizations page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/organizations");
    await page.waitForTimeout(400);
  });

  test("shows Organizations heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Organizations" })).toBeVisible();
  });

  test("shows org list or empty state", async ({ page }) => {
    const hasTable = await page.locator("table").isVisible().catch(() => false);
    const hasEmpty = await page.getByText(/No organizations yet/).isVisible().catch(() => false);
    expect(hasTable || hasEmpty).toBe(true);
  });

  test("table shows Name, Slug, Created columns", async ({ page }) => {
    if (!await page.locator("table").isVisible().catch(() => false)) { test.skip(); return; }
    const headers = page.locator("thead th");
    await expect(headers.filter({ hasText: "Name" })).toBeVisible();
    await expect(headers.filter({ hasText: "Slug" })).toBeVisible();
    await expect(headers.filter({ hasText: "Created" })).toBeVisible();
  });

  test("admin user sees + New Organization button", async ({ page }) => {
    await expect(page.getByRole("button", { name: /New Organization/i })).toBeVisible();
  });

  test("New Organization modal opens", async ({ page }) => {
    await page.getByRole("button", { name: /New Organization/i }).click();
    await expect(page.getByRole("heading", { name: "New Organization" })).toBeVisible();
  });

  test("modal has Name and Slug fields", async ({ page }) => {
    await page.getByRole("button", { name: /New Organization/i }).click();
    await expect(page.getByLabel("Name *")).toBeVisible();
    await expect(page.getByLabel("Slug *")).toBeVisible();
  });

  test("slug field strips invalid chars", async ({ page }) => {
    await page.getByRole("button", { name: /New Organization/i }).click();
    const slugInput = page.getByLabel("Slug *");
    await slugInput.fill("Acme Corp!");
    // onChange lowercases and strips non-alphanumeric-or-hyphen chars (spaces removed, not converted)
    await expect(slugInput).toHaveValue("acmecorp");
  });

  test("Cancel closes modal", async ({ page }) => {
    await page.getByRole("button", { name: /New Organization/i }).click();
    await page.getByRole("button", { name: "Cancel" }).click();
    await expect(page.getByRole("heading", { name: "New Organization" })).not.toBeVisible();
  });

  test("Edit button opens edit modal", async ({ page }) => {
    if (!await page.locator("table").isVisible().catch(() => false)) { test.skip(); return; }
    await page.locator('[title="Edit"]').first().click();
    await expect(page.getByRole("heading", { name: /Edit:/i })).toBeVisible();
  });

  test("Delete button opens confirmation dialog", async ({ page }) => {
    if (!await page.locator("table").isVisible().catch(() => false)) { test.skip(); return; }
    await page.locator('[title="Delete"]').first().click();
    await expect(page.getByRole("heading", { name: "Delete Organization" })).toBeVisible();
    // Cancel to avoid actually deleting anything
    await page.getByRole("button", { name: "Cancel" }).click();
  });
});
