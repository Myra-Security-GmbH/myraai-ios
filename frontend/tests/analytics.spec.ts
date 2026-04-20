import { test, expect } from "@playwright/test";

test.describe("Cost Analytics page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/analytics");
    await expect(page.getByRole("heading", { name: "Cost Analytics" })).toBeVisible({ timeout: 10000 });
  });

  test("shows Cost Analytics heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Cost Analytics" })).toBeVisible();
  });

  test("shows period selector tabs", async ({ page }) => {
    await expect(page.getByRole("button", { name: "Today" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Last 7 days" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Last 30 days" })).toBeVisible();
  });

  test("Last 7 days tab is active by default (no URL param)", async ({ page }) => {
    await expect(page.getByRole("button", { name: "Last 7 days" })).toHaveClass(/tab--active/);
    await expect(page.getByRole("button", { name: "Today" })).not.toHaveClass(/tab--active/);
    await expect(page.getByRole("button", { name: "Last 30 days" })).not.toHaveClass(/tab--active/);
  });

  // ── URL persistence ──────────────────────────────────────────────────────

  test("clicking Today updates URL to ?timeframe=today", async ({ page }) => {
    await page.getByRole("button", { name: "Today" }).click();
    await expect(page).toHaveURL(/[?&]timeframe=today/);
    await expect(page.getByRole("button", { name: "Today" })).toHaveClass(/tab--active/);
  });

  test("clicking Last 30 days updates URL to ?timeframe=30d", async ({ page }) => {
    await page.getByRole("button", { name: "Last 30 days" }).click();
    await expect(page).toHaveURL(/[?&]timeframe=30d/);
    await expect(page.getByRole("button", { name: "Last 30 days" })).toHaveClass(/tab--active/);
  });

  test("clicking Last 7 days updates URL to ?timeframe=7d", async ({ page }) => {
    await page.goto("/analytics?timeframe=today");
    await expect(page.getByRole("heading", { name: "Cost Analytics" })).toBeVisible();
    await page.getByRole("button", { name: "Last 7 days" }).click();
    await expect(page).toHaveURL(/[?&]timeframe=7d/);
    await expect(page.getByRole("button", { name: "Last 7 days" })).toHaveClass(/tab--active/);
  });

  test("reloading with ?timeframe=today pre-selects Today tab", async ({ page }) => {
    await page.goto("/analytics?timeframe=today");
    await expect(page.getByRole("heading", { name: "Cost Analytics" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Today" })).toHaveClass(/tab--active/);
    await expect(page.getByRole("button", { name: "Last 7 days" })).not.toHaveClass(/tab--active/);
  });

  test("reloading with ?timeframe=30d pre-selects Last 30 days tab", async ({ page }) => {
    await page.goto("/analytics?timeframe=30d");
    await expect(page.getByRole("heading", { name: "Cost Analytics" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Last 30 days" })).toHaveClass(/tab--active/);
    await expect(page.getByRole("button", { name: "Last 7 days" })).not.toHaveClass(/tab--active/);
  });

  test("invalid ?timeframe= value falls back to Last 7 days", async ({ page }) => {
    await page.goto("/analytics?timeframe=bogus");
    await expect(page.getByRole("heading", { name: "Cost Analytics" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Last 7 days" })).toHaveClass(/tab--active/);
  });

  // ── Layout ───────────────────────────────────────────────────────────────

  test("shows breakdown tab bar", async ({ page }) => {
    await expect(page.getByRole("button", { name: "By Tenant" })).toBeVisible();
    await expect(page.getByRole("button", { name: "By Gateway" })).toBeVisible();
    await expect(page.getByRole("button", { name: "By Provider" })).toBeVisible();
    await expect(page.getByRole("button", { name: "By Model" })).toBeVisible();
    await expect(page.getByRole("button", { name: "By User" })).toBeVisible();
  });

  test("switching breakdown tabs does not crash", async ({ page }) => {
    for (const tab of ["By Gateway", "By Provider", "By Model", "By User", "By Tenant"]) {
      await page.getByRole("button", { name: tab }).click();
    }
    await expect(page.getByRole("heading", { name: "Cost Analytics" })).toBeVisible();
  });

  test("shows hero summary cards", async ({ page }) => {
    await expect(page.getByText("Total Spend")).toBeVisible();
    await expect(page.getByText("Total Requests")).toBeVisible();
    await expect(page.getByText("Cache Savings")).toBeVisible();
    await expect(page.getByText("Error Rate")).toBeVisible();
  });

  test("filter input is present", async ({ page }) => {
    await expect(page.getByLabel("Filter rows")).toBeVisible();
  });
});
