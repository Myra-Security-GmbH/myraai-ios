import { test, expect } from "./base";

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

// ── 30-Day Overview hover tooltip ────────────────────────────────────────────

test.describe("Cost Analytics — 30-Day Overview tooltip", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/analytics?timeframe=30d");
    await expect(page.getByRole("heading", { name: "Cost Analytics" })).toBeVisible({ timeout: 10000 });
  });

  test("hovering a day in the 30-day overview reveals a tooltip with date and cost", async ({ page }) => {
    const chart = page.getByLabel("30-day overview chart");
    await expect(chart).toBeVisible();
    // Hit-targets are last in z-order; pick the last one (most recent day, likely non-zero)
    const hits = chart.locator("rect[data-chart-hit]");
    await expect(hits).toHaveCount(30);
    await hits.last().hover();
    const tip = page.locator("[data-cy=overview-tooltip]");
    await expect(tip).toBeVisible({ timeout: 2000 });
    // Tooltip must contain a date (en-US format: "Mon, Apr 15") and a request count line.
    await expect(tip).toContainText(/[A-Z][a-z]{2},\s+[A-Z][a-z]{2}\s+\d{1,2}/);
    await expect(tip).toContainText(/\d+\s+requests?/);
  });

  test("clicking a day pins the tooltip; clicking outside dismisses it", async ({ page }) => {
    const chart = page.getByLabel("30-day overview chart");
    const hits = chart.locator("rect[data-chart-hit]");
    await hits.nth(15).click();
    const tip = page.locator("[data-cy=overview-tooltip]");
    await expect(tip).toBeVisible();

    // Move the mouse far away — pinned tooltip stays visible.
    await page.mouse.move(0, 0);
    await expect(tip).toBeVisible();

    // Click somewhere outside the chart — tooltip dismisses.
    await page.getByRole("heading", { name: "Cost Analytics" }).click();
    await expect(tip).toBeHidden();
  });

  test("hit-targets are keyboard-focusable and expose aria-label per day", async ({ page }) => {
    const chart = page.getByLabel("30-day overview chart");
    const hits = chart.locator("rect[data-chart-hit]");
    const first = hits.first();
    await expect(first).toHaveAttribute("tabindex", "0");
    await expect(first).toHaveAttribute("role", "img");
    const label = await first.getAttribute("aria-label");
    expect(label).toMatch(/[A-Z][a-z]{2}\s+\d{1,2}/);                        // date fragment, e.g. "Apr 15"
    expect(label).toMatch(/(\$|€|£|CHF\s)/);                                 // currency symbol
    expect(label).toMatch(/\d+\s+requests?/);                                // request count
  });
});
