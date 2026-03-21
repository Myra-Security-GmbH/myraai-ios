import { test, expect } from "@playwright/test";

test.describe("Navigation", () => {
  test("redirects / to /dashboard", async ({ page }) => {
    await page.goto("/");
    await expect(page).toHaveURL(/\/dashboard/);
  });

  test("sidebar is visible on all pages", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page.locator("nav, aside")).toBeVisible();
  });

  test("can navigate to Tenants", async ({ page }) => {
    await page.goto("/tenants");
    await expect(page.getByRole("heading", { name: "Tenants" })).toBeVisible();
  });

  test("can navigate to Gateways", async ({ page }) => {
    await page.goto("/gateways");
    await expect(page.getByRole("heading", { name: "Gateways" })).toBeVisible();
  });

  test("can navigate to Logs", async ({ page }) => {
    await page.goto("/logs");
    await expect(page.getByRole("heading", { name: /Request Logs/i })).toBeVisible();
  });

  test("can navigate to Monitor", async ({ page }) => {
    await page.goto("/monitor");
    await expect(page.getByRole("heading", { name: /Monitor/i })).toBeVisible();
  });

  test("can navigate to Model Prices", async ({ page }) => {
    await page.goto("/model-prices");
    await expect(page.getByRole("heading", { name: /Model Prices/i })).toBeVisible();
  });

  test("sidebar links work", async ({ page }) => {
    await page.goto("/dashboard");
    await page.getByRole("link", { name: /Tenants/i }).click();
    await expect(page).toHaveURL(/\/tenants/);
  });
});
