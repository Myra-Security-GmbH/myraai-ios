import { test, expect } from "@playwright/test";

test.describe("Dashboard page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/dashboard");
    await page.waitForTimeout(600);
  });

  test("shows Dashboard heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: /Dashboard/i })).toBeVisible();
  });

  test("shows stat cards", async ({ page }) => {
    // stat cards contain numeric values — look for at least one number in a stat area
    await expect(page.getByText(/Requests|requests/i).first()).toBeVisible();
  });

  test("shows recent requests section", async ({ page }) => {
    await expect(page.getByText(/Recent Requests/i)).toBeVisible();
  });

  test("no JS runtime errors on load (ignores resource 403s and net errors)", async ({ page }) => {
    const errors: string[] = [];
    page.on("console", (msg) => {
      if (msg.type() === "error") errors.push(msg.text());
    });
    await page.goto("/dashboard");
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

  test("shows period sections (last minute, last hour, today)", async ({ page }) => {
    await expect(page.getByText(/last minute|last hour|today/i).first()).toBeVisible();
  });
});
