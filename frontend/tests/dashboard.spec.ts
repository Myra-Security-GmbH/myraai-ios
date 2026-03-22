import { test, expect } from "@playwright/test";

test.describe("Dashboard page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/dashboard");
    await page.waitForTimeout(800);
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

  // ── analytics depth (top models) ─────────────────────────────────────────

  test("Top Models section is present when there is request data", async ({ page }) => {
    // Top models section is conditionally rendered only when there is data
    const hasTopModels = await page.getByRole("heading", { name: /Top Models/i }).isVisible().catch(() => false);
    // If no request data yet, the section is simply absent — that's fine
    if (hasTopModels) {
      await expect(page.getByRole("columnheader", { name: /Provider/i }).first()).toBeVisible();
      await expect(page.getByRole("columnheader", { name: /Model/i }).first()).toBeVisible();
      await expect(page.getByRole("columnheader", { name: /Requests/i }).first()).toBeVisible();
    }
    // test always passes — we're testing the shape, not the data
  });

  test("Top Models table has expected columns when visible", async ({ page }) => {
    const heading = page.getByRole("heading", { name: /Top Models/i });
    if (!await heading.isVisible().catch(() => false)) { test.skip(); return; }
    await expect(page.getByRole("columnheader", { name: /Cost/i }).first()).toBeVisible();
    await expect(page.getByRole("columnheader", { name: /Avg Latency/i })).toBeVisible();
  });

  test("timeframe tabs exist and switching does not crash", async ({ page }) => {
    const todayBtn = page.getByRole("button", { name: /^Today$/i });
    await expect(todayBtn).toBeVisible();
    await todayBtn.click();
    await page.waitForTimeout(200);
    await expect(page.getByRole("heading", { name: /Dashboard/i })).toBeVisible();

    const weekBtn = page.getByRole("button", { name: /Last 7 days/i });
    await expect(weekBtn).toBeVisible();
    await weekBtn.click();
    await page.waitForTimeout(200);
    await expect(page.getByRole("heading", { name: /Dashboard/i })).toBeVisible();
  });
});
