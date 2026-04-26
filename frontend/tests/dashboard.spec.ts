import { test, expect, type Page, type Request } from "./base";

const ADMIN_BASE = process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173/admin/v1";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Wait for the dashboard page to finish its initial data load. */
async function waitForDashboardReady(page: Page) {
  // The hero cards are always rendered once stats load; wait for "Requests" label.
  await expect(page.getByText("Requests").first()).toBeVisible({ timeout: 10000 });
}

/**
 * Collect all /stats/analytics requests fired while `action` runs.
 * Returns the array of captured Request objects.
 */
async function captureAnalyticsRequests(
  page: Page,
  action: () => Promise<void>,
): Promise<Request[]> {
  const captured: Request[] = [];
  const listener = (req: Request) => {
    if (req.url().includes("/stats/analytics")) captured.push(req);
  };
  page.on("request", listener);
  await action();
  await page.waitForLoadState("networkidle", { timeout: 5000 }).catch(() => {});
  page.off("request", listener);
  return captured;
}

// ---------------------------------------------------------------------------
// Basic page rendering
// ---------------------------------------------------------------------------

test.describe("Dashboard – rendering", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/dashboard");
    await waitForDashboardReady(page);
  });

  test("shows Dashboard heading and subtitle", async ({ page }) => {
    await expect(page.getByRole("heading", { name: /Dashboard/i })).toBeVisible();
    await expect(page.getByText(/Real-time AI Gateway metrics/i)).toBeVisible();
  });

  test("hero cards show Requests, Cost, and Guardrail Hits", async ({ page }) => {
    await expect(page.getByText("Requests").first()).toBeVisible();
    await expect(page.getByText("Cost").first()).toBeVisible();
    await expect(page.getByText("Guardrail Hits").first()).toBeVisible();
  });

  test("Recent Requests section is visible", async ({ page }) => {
    await expect(page.getByRole("heading", { name: /Recent Requests/i })).toBeVisible();
  });

  test("Recent Requests table has expected column headers", async ({ page }) => {
    // Table is only rendered when there are rows — skip if empty state is shown
    const tableExists = await page.locator("table").filter({
      has: page.locator("th", { hasText: "Flags" }),
    }).isVisible().catch(() => false);
    if (!tableExists) return;

    // "Flags" header is unique to the Recent Requests table
    const recentTable = page.locator("table").filter({
      has: page.locator("th", { hasText: "Flags" }),
    });
    await expect(recentTable.getByRole("columnheader", { name: /^Time$/i })).toBeVisible();
    await expect(recentTable.getByRole("columnheader", { name: /^Gateway$/i })).toBeVisible();
    await expect(recentTable.getByRole("columnheader", { name: /^Provider$/i })).toBeVisible();
    await expect(recentTable.getByRole("columnheader", { name: /^Status$/i })).toBeVisible();
    await expect(recentTable.getByRole("columnheader", { name: /^Cost$/i })).toBeVisible();
    await expect(recentTable.getByRole("columnheader", { name: /^Latency$/i })).toBeVisible();
    await expect(recentTable.getByRole("columnheader", { name: /^Flags$/i })).toBeVisible();
  });

  test("no JS runtime errors on load", async ({ page }) => {
    const errors: string[] = [];
    page.on("pageerror", (err) => errors.push(err.message));
    page.on("console", (msg) => {
      if (msg.type() === "error" &&
          !msg.text().includes("favicon") &&
          !msg.text().includes("net::ERR") &&
          !msg.text().includes("Failed to load resource") &&
          !msg.text().includes("CORS policy") &&
          !msg.text().includes("Access-Control")) {
        errors.push(msg.text());
      }
    });
    await page.goto("/dashboard");
    await waitForDashboardReady(page);
    expect(errors).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// Timeframe tabs — UI state
// ---------------------------------------------------------------------------

test.describe("Dashboard – timeframe tab UI", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/dashboard");
    await waitForDashboardReady(page);
  });

  test("all five timeframe tabs are rendered", async ({ page }) => {
    await expect(page.getByRole("button", { name: /^Today$/i })).toBeVisible();
    await expect(page.getByRole("button", { name: /^Yesterday$/i })).toBeVisible();
    await expect(page.getByRole("button", { name: /^Last 7 days$/i })).toBeVisible();
    await expect(page.getByRole("button", { name: /^Last hour$/i })).toBeVisible();
    await expect(page.getByRole("button", { name: /^Last minute$/i })).toBeVisible();
  });

  test("Today tab is active by default (no URL param)", async ({ page }) => {
    // "Today" button should carry the active modifier class
    const todayBtn = page.getByRole("button", { name: /^Today$/i });
    await expect(todayBtn).toHaveClass(/timeframe-tab--active/);
    // Other tabs must NOT be active
    await expect(page.getByRole("button", { name: /^Yesterday$/i })).not.toHaveClass(/timeframe-tab--active/);
    await expect(page.getByRole("button", { name: /^Last 7 days$/i })).not.toHaveClass(/timeframe-tab--active/);
  });
});

// ---------------------------------------------------------------------------
// Timeframe tabs — URL persistence
// ---------------------------------------------------------------------------

test.describe("Dashboard – URL persistence", () => {
  test("clicking Last 7 days updates URL to ?timeframe=last_7d", async ({ page }) => {
    await page.goto("/dashboard");
    await waitForDashboardReady(page);
    await page.getByRole("button", { name: /^Last 7 days$/i }).click();
    await expect(page).toHaveURL(/[?&]timeframe=last_7d/);
  });

  test("clicking Yesterday updates URL to ?timeframe=yesterday", async ({ page }) => {
    await page.goto("/dashboard");
    await waitForDashboardReady(page);
    await page.getByRole("button", { name: /^Yesterday$/i }).click();
    await expect(page).toHaveURL(/[?&]timeframe=yesterday/);
  });

  test("clicking Last hour updates URL to ?timeframe=hour", async ({ page }) => {
    await page.goto("/dashboard");
    await waitForDashboardReady(page);
    await page.getByRole("button", { name: /^Last hour$/i }).click();
    await expect(page).toHaveURL(/[?&]timeframe=hour/);
  });

  test("clicking Last minute updates URL to ?timeframe=last_min", async ({ page }) => {
    await page.goto("/dashboard");
    await waitForDashboardReady(page);
    await page.getByRole("button", { name: /^Last minute$/i }).click();
    await expect(page).toHaveURL(/[?&]timeframe=last_min/);
  });

  test("clicking Today updates URL to ?timeframe=today", async ({ page }) => {
    await page.goto("/dashboard?timeframe=last_7d");
    await waitForDashboardReady(page);
    await page.getByRole("button", { name: /^Today$/i }).click();
    await expect(page).toHaveURL(/[?&]timeframe=today/);
  });

  test("reloading with ?timeframe=last_7d pre-selects Last 7 days tab", async ({ page }) => {
    await page.goto("/dashboard?timeframe=last_7d");
    await waitForDashboardReady(page);
    await expect(page.getByRole("button", { name: /^Last 7 days$/i })).toHaveClass(/timeframe-tab--active/);
    await expect(page.getByRole("button", { name: /^Today$/i })).not.toHaveClass(/timeframe-tab--active/);
  });

  test("reloading with ?timeframe=yesterday pre-selects Yesterday tab", async ({ page }) => {
    await page.goto("/dashboard?timeframe=yesterday");
    await waitForDashboardReady(page);
    await expect(page.getByRole("button", { name: /^Yesterday$/i })).toHaveClass(/timeframe-tab--active/);
    await expect(page.getByRole("button", { name: /^Today$/i })).not.toHaveClass(/timeframe-tab--active/);
  });

  test("invalid ?timeframe= value falls back to Today tab", async ({ page }) => {
    await page.goto("/dashboard?timeframe=bogus_value");
    await waitForDashboardReady(page);
    await expect(page.getByRole("button", { name: /^Today$/i })).toHaveClass(/timeframe-tab--active/);
  });

  test("back button after clicking tabs returns to previous page, not previous tab", async ({ page }) => {
    await page.goto("/monitor");
    await page.goto("/dashboard");
    await waitForDashboardReady(page);
    await page.getByRole("button", { name: /^Last 7 days$/i }).click();
    await expect(page).toHaveURL(/[?&]timeframe=last_7d/);
    await page.goBack();
    // Back should land on /monitor, not a prior dashboard URL
    await expect(page).toHaveURL(/\/monitor/);
  });
});

// ---------------------------------------------------------------------------
// Timeframe tabs — analytics API re-fetch
// ---------------------------------------------------------------------------

test.describe("Dashboard – analytics API re-fetch on tab change", () => {
  test("switching from Today to Last 7 days fires a new analytics request with earlier 'since'", async ({ page }) => {
    await page.goto("/dashboard?timeframe=today");
    await waitForDashboardReady(page);

    // Record the 'since' value from the initial Today request
    let todaySince: number | null = null;
    await page.waitForRequest((req) => {
      if (req.url().includes("/stats/analytics")) {
        const url = new URL(req.url());
        todaySince = Number(url.searchParams.get("since"));
        return true;
      }
      return false;
    }, { timeout: 5000 }).catch(() => null);

    // Click "Last 7 days" and capture the subsequent analytics request
    const requests = await captureAnalyticsRequests(page, async () => {
      await page.getByRole("button", { name: /^Last 7 days$/i }).click();
    });

    // A new analytics request MUST have been fired
    expect(
      requests.length,
      "Expected a new /stats/analytics request after switching to Last 7 days — none was fired",
    ).toBeGreaterThan(0);

    const newSince = Number(new URL(requests[0].url()).searchParams.get("since"));
    // 'last_7d' goes 7 days back — its 'since' must be earlier than 'today'
    if (todaySince !== null) {
      expect(
        newSince,
        `Expected 'since' for last_7d (${newSince}) to be earlier than 'since' for today (${todaySince})`,
      ).toBeLessThan(todaySince);
    }
  });

  test("switching from Today to Yesterday fires a new analytics request with earlier 'since'", async ({ page }) => {
    await page.goto("/dashboard?timeframe=today");
    await waitForDashboardReady(page);

    let todaySince: number | null = null;
    await page.waitForRequest((req) => {
      if (req.url().includes("/stats/analytics")) {
        const url = new URL(req.url());
        todaySince = Number(url.searchParams.get("since"));
        return true;
      }
      return false;
    }, { timeout: 5000 }).catch(() => null);

    const requests = await captureAnalyticsRequests(page, async () => {
      await page.getByRole("button", { name: /^Yesterday$/i }).click();
    });

    expect(
      requests.length,
      "Expected a new /stats/analytics request after switching to Yesterday — none was fired",
    ).toBeGreaterThan(0);

    const newSince = Number(new URL(requests[0].url()).searchParams.get("since"));
    if (todaySince !== null) {
      expect(newSince).toBeLessThan(todaySince);
    }
  });

  test("switching from Last 7 days to Last hour fires a new analytics request with later 'since'", async ({ page }) => {
    await page.goto("/dashboard?timeframe=last_7d");
    await waitForDashboardReady(page);

    let sevenDaySince: number | null = null;
    await page.waitForRequest((req) => {
      if (req.url().includes("/stats/analytics")) {
        const url = new URL(req.url());
        sevenDaySince = Number(url.searchParams.get("since"));
        return true;
      }
      return false;
    }, { timeout: 5000 }).catch(() => null);

    const requests = await captureAnalyticsRequests(page, async () => {
      await page.getByRole("button", { name: /^Last hour$/i }).click();
    });

    expect(
      requests.length,
      "Expected a new /stats/analytics request after switching to Last hour — none was fired",
    ).toBeGreaterThan(0);

    const newSince = Number(new URL(requests[0].url()).searchParams.get("since"));
    if (sevenDaySince !== null) {
      expect(
        newSince,
        `Expected 'since' for last hour (${newSince}) to be later than 'since' for last_7d (${sevenDaySince})`,
      ).toBeGreaterThan(sevenDaySince);
    }
  });

  test("each of the five tabs fires a distinct analytics request", async ({ page }) => {
    await page.goto("/dashboard");
    await waitForDashboardReady(page);

    const sinceValues: number[] = [];

    for (const { name, key } of [
      { name: "Yesterday",    key: "yesterday" },
      { name: "Last 7 days",  key: "last_7d"   },
      { name: "Last hour",    key: "hour"       },
      { name: "Last minute",  key: "last_min"   },
      { name: "Today",        key: "today"      },
    ]) {
      const reqs = await captureAnalyticsRequests(page, async () => {
        await page.getByRole("button", { name: new RegExp(`^${name}$`, "i") }).click();
      });

      expect(
        reqs.length,
        `Expected a /stats/analytics request when switching to "${name}" (${key}) — none was fired`,
      ).toBeGreaterThan(0);

      sinceValues.push(Number(new URL(reqs[0].url()).searchParams.get("since")));
    }

    // All five 'since' timestamps must be distinct — same value means data was not re-fetched
    const unique = new Set(sinceValues);
    expect(
      unique.size,
      `Expected 5 distinct 'since' values across tab switches, got ${unique.size}: [${[...unique].join(", ")}]`,
    ).toBe(5);
  });
});

// ---------------------------------------------------------------------------
// Timeframe tabs — "Top Models" heading reflects selected period
// ---------------------------------------------------------------------------

test.describe("Dashboard – Top Models heading reflects timeframe", () => {
  /**
   * Ensure that, when top_models data is present, the heading text updates to
   * match the selected timeframe label.  If there is no top-models data in the
   * system the tests are skipped (data-dependent, not a code bug).
   */

  async function topModelsHeading(page: Page) {
    const h = page.getByRole("heading", { name: /Top Models/i });
    const visible = await h.isVisible().catch(() => false);
    return visible ? h : null;
  }

  test("Top Models heading says 'Today' when Today tab is selected", async ({ page }) => {
    await page.goto("/dashboard?timeframe=today");
    await waitForDashboardReady(page);
    await page.waitForLoadState("networkidle", { timeout: 5000 }).catch(() => {});
    const heading = await topModelsHeading(page);
    if (!heading) return; // no data — skip
    await expect(heading).toContainText("Today");
  });

  test("Top Models heading updates to 'Last 7 days' after switching tab", async ({ page }) => {
    await page.goto("/dashboard?timeframe=today");
    await waitForDashboardReady(page);
    await page.waitForLoadState("networkidle", { timeout: 5000 }).catch(() => {});

    const headingBefore = await topModelsHeading(page);
    if (!headingBefore) return; // no data — skip

    // Switch to "Last 7 days" and wait for the analytics re-fetch
    await page.getByRole("button", { name: /^Last 7 days$/i }).click();

    // The heading must update — it should no longer say "Today"
    await expect(
      page.getByRole("heading", { name: /Top Models/i }),
      "Top Models heading did not update after switching to Last 7 days",
    ).toContainText("Last 7 days", { timeout: 8000 });
  });

  test("Top Models heading updates to 'Yesterday' after switching tab", async ({ page }) => {
    await page.goto("/dashboard?timeframe=today");
    await waitForDashboardReady(page);
    await page.waitForLoadState("networkidle", { timeout: 5000 }).catch(() => {});

    const headingBefore = await topModelsHeading(page);
    if (!headingBefore) return; // no data — skip

    await page.getByRole("button", { name: /^Yesterday$/i }).click();

    await expect(
      page.getByRole("heading", { name: /Top Models/i }),
    ).toContainText("Yesterday", { timeout: 8000 });
  });

  test("Top Models table columns are correct when section is visible", async ({ page }) => {
    await page.goto("/dashboard");
    await waitForDashboardReady(page);
    await page.waitForLoadState("networkidle", { timeout: 5000 }).catch(() => {});
    const heading = await topModelsHeading(page);
    if (!heading) return;
    const table = page.locator("table").filter({
      has: page.locator("th", { hasText: "Avg Latency" }),
    });
    await expect(table.getByRole("columnheader", { name: /^Provider$/i })).toBeVisible();
    await expect(table.getByRole("columnheader", { name: /^Model$/i })).toBeVisible();
    await expect(table.getByRole("columnheader", { name: /^Requests$/i })).toBeVisible();
    await expect(table.getByRole("columnheader", { name: /^Cost$/i })).toBeVisible();
    await expect(table.getByRole("columnheader", { name: /Avg Latency/i })).toBeVisible();
  });
});

// ---------------------------------------------------------------------------
// Timeframe tabs — no silent test.skip guards on preconditions
// ---------------------------------------------------------------------------

test.describe("Dashboard – regression guards", () => {
  test("active tab class is applied on initial load (not just after interaction)", async ({ page }) => {
    await page.goto("/dashboard");
    await waitForDashboardReady(page);
    // Without any user interaction, one tab must be visually active
    const allTabButtons = page.getByRole("button").filter({ hasText: /Today|Yesterday|Last 7 days|Last hour|Last minute/ });
    const count = await allTabButtons.count();
    let activeCount = 0;
    for (let i = 0; i < count; i++) {
      const cls = await allTabButtons.nth(i).getAttribute("class") ?? "";
      if (cls.includes("timeframe-tab--active")) activeCount++;
    }
    expect(activeCount, "Expected exactly one timeframe tab to be active on initial load").toBe(1);
  });

  test("active tab matches URL param after navigating to ?timeframe=hour", async ({ page }) => {
    await page.goto("/dashboard?timeframe=hour");
    await waitForDashboardReady(page);
    const hourBtn = page.getByRole("button", { name: /^Last hour$/i });
    await expect(hourBtn).toHaveClass(/timeframe-tab--active/);
    // All other tabs must be inactive
    for (const name of ["Today", "Yesterday", "Last 7 days", "Last minute"]) {
      await expect(
        page.getByRole("button", { name: new RegExp(`^${name}$`, "i") }),
      ).not.toHaveClass(/timeframe-tab--active/);
    }
  });

  test("analytics API 'since' param for last_7d is approximately 7 days ago", async ({ page }) => {
    const captured: Request[] = [];
    page.on("request", (req) => {
      if (req.url().includes("/stats/analytics")) captured.push(req);
    });
    await page.goto("/dashboard?timeframe=last_7d");
    await waitForDashboardReady(page);
    // Wait for analytics request
    await expect.poll(() => captured.length, { timeout: 8000 }).toBeGreaterThan(0);

    const url = new URL(captured[captured.length - 1].url());
    const since = Number(url.searchParams.get("since"));
    const now = Date.now();
    const sevenDaysMs = 7 * 24 * 3600 * 1000;
    // 'since' should be within ±2 days of (now − 7d), allowing for timezone/rounding
    const diff = Math.abs(now - sevenDaysMs - since);
    expect(
      diff,
      `'since' param (${since}) is not close to 7 days ago. now=${now}, diff=${diff}ms`,
    ).toBeLessThan(2 * 24 * 3600 * 1000);
  });
});
