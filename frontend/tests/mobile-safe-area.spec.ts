/**
 * mobile-safe-area.spec.ts — verify the hamburger button and page heading do
 * not visually overlap on mobile viewports, regardless of the platform-reported
 * safe-area inset.
 *
 * Regression for the iOS/Android layout regression introduced by 8f2fd7b
 * (viewport-fit=cover + env(safe-area-inset-*) propagation): the hamburger
 * was sitting on top of the page heading on iOS, and Android grew unwanted
 * whitespace at the top of every page because Chrome WebView reported the
 * already-handled status-bar inset to the page.
 *
 * Two scenarios:
 *   1. Android-like — html.aig-android forces every safe-area var to 0;
 *      hamburger at top:12, heading starts at y=64 (12 px gap below button).
 *   2. iOS-like — --aig-safe-top is overridden to 47 px (notch device);
 *      hamburger sits at top:59, heading at y=111 (12 px gap below button).
 */

import { test, expect, Page } from "@playwright/test";

test.use({
  viewport: { width: 390, height: 844 },
  hasTouch: true,
});

async function getRect(page: Page, selector: string) {
  return page.locator(selector).first().evaluate((el) => {
    const r = (el as HTMLElement).getBoundingClientRect();
    return { top: r.top, bottom: r.bottom, left: r.left, right: r.right, height: r.height, width: r.width };
  });
}

function disjointVertically(a: { top: number; bottom: number }, b: { top: number; bottom: number }) {
  return a.bottom <= b.top || b.bottom <= a.top;
}

test.describe("mobile safe-area layout", () => {
  test("Android-like (no inset): hamburger and heading do not overlap", async ({ page }) => {
    await page.addInitScript(() => {
      document.documentElement.classList.add("aig-android");
    });
    await page.goto("/dashboard");

    // Wait for the dashboard to render (hamburger button visible)
    await expect(page.getByRole("button", { name: "Open navigation menu" })).toBeVisible();

    const ham = await getRect(page, "[aria-label='Open navigation menu']");
    const heading = await getRect(page, "h1");

    expect(ham.top).toBeCloseTo(12, 0);
    expect(ham.height).toBeCloseTo(40, 0);
    // Heading starts after page padding-top: 0 + 64 = 64 (≤ small layout drift)
    expect(heading.top).toBeGreaterThanOrEqual(64 - 1);
    expect(disjointVertically(ham, heading)).toBe(true);
  });

  test("iOS-like (47 px inset): hamburger sits below the notch and heading clears the hamburger", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page.getByRole("button", { name: "Open navigation menu" })).toBeVisible();
    await page.evaluate(() => {
      document.documentElement.style.setProperty("--aig-safe-top", "47px");
    });

    const ham = await getRect(page, "[aria-label='Open navigation menu']");
    const heading = await getRect(page, "h1");

    // Hamburger top = 47 + 12 = 59
    expect(ham.top).toBeCloseTo(59, 0);
    // Page padding-top = 47 + 64 = 111
    expect(heading.top).toBeGreaterThanOrEqual(111 - 1);
    expect(disjointVertically(ham, heading)).toBe(true);
  });

  test("iOS-like with Dynamic Island (59 px inset): geometry remains disjoint", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page.getByRole("button", { name: "Open navigation menu" })).toBeVisible();
    await page.evaluate(() => {
      document.documentElement.style.setProperty("--aig-safe-top", "59px");
    });

    const ham = await getRect(page, "[aria-label='Open navigation menu']");
    const heading = await getRect(page, "h1");

    // Hamburger top = 59 + 12 = 71; heading top = 59 + 64 = 123
    expect(ham.top).toBeCloseTo(71, 0);
    expect(heading.top).toBeGreaterThanOrEqual(123 - 1);
    expect(disjointVertically(ham, heading)).toBe(true);
  });

  test("playground page on iOS-like inset: heading does not slide under the hamburger", async ({ page }) => {
    await page.goto("/playground");
    await expect(page.getByRole("button", { name: "Open navigation menu" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Playground" })).toBeVisible();
    await page.evaluate(() => {
      document.documentElement.style.setProperty("--aig-safe-top", "47px");
    });

    const ham = await getRect(page, "[aria-label='Open navigation menu']");
    const heading = await getRect(page, "h1");

    expect(ham.top).toBeCloseTo(59, 0);
    expect(heading.top).toBeGreaterThanOrEqual(111 - 1);
    expect(disjointVertically(ham, heading)).toBe(true);
  });
});
