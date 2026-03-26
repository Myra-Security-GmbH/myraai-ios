import { test, expect } from "@playwright/test";

test.describe("Cost Analytics page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/analytics");
    await page.waitForTimeout(600);
  });

  test("shows Cost Analytics heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Cost Analytics" })).toBeVisible();
  });

  test("shows period selector tabs", async ({ page }) => {
    await expect(page.getByRole("button", { name: "Today" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Last 7 days" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Last 30 days" })).toBeVisible();
  });

  test("clicking Today period tab works", async ({ page }) => {
    await page.getByRole("button", { name: "Today" }).click();
    await page.waitForTimeout(400);
    // Page should still show the heading — no crash
    await expect(page.getByRole("heading", { name: "Cost Analytics" })).toBeVisible();
  });

  test("clicking Last 30 days period tab works", async ({ page }) => {
    await page.getByRole("button", { name: "Last 30 days" }).click();
    await page.waitForTimeout(400);
    await expect(page.getByRole("heading", { name: "Cost Analytics" })).toBeVisible();
  });

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
      await page.waitForTimeout(200);
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
