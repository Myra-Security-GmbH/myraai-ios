/**
 * chat-vanadium-desktop-mode.spec.ts — Tests for the viewport-fix script in index.html.
 *
 * Vanadium (Android browser) in "Request Desktop Site" mode sets window.innerWidth to
 * ~980 px while window.outerWidth stays at the real CSS pixel width (~427 px on the
 * device).  The browser then scales the 980 px layout down to ~43.5 % to fit the screen,
 * making the page unusable.
 *
 * The inline JS fix in index.html detects this mismatch and resets the meta viewport
 * tag to `width=<outerWidth>` before React renders, so the browser lays out at the
 * correct device width.
 *
 * Simulation technique:
 *   - Playwright sets window.innerWidth via CDP (Emulation.setDeviceMetricsOverride).
 *   - page.addInitScript() runs before any <script> tag in <head>, including our inline
 *     fix.  We use it to override window.outerWidth via Object.defineProperty.
 *   - Result: innerWidth=980 (CDP), outerWidth=427 (override) — exact Vanadium condition.
 *
 * These tests verify:
 *   1. The JS fix fires correctly when the desktop-mode condition is met.
 *   2. The JS fix does NOT fire on a real desktop browser (ratio = 1, no false positive).
 *   3. The JS fix does NOT fire on a narrow viewport where ratio = 1 but width < 600 px.
 *   4. Mobile CSS (@media pointer:coarse, no max-width) fires at 980 px touch — both
 *      sidebars become drawers, freeing the full 980 px for content.
 */

import { test, expect, type Page } from "@playwright/test";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Navigate to /chat and wait until at least one <select> is attached.
 *  The meta viewport tag is written synchronously in <head> before React runs,
 *  so by the time any JS renders the fix has already fired (or not). */
async function openChat(page: Page) {
  await page.goto("/chat");
  await page.locator("select").first().waitFor({ state: "attached", timeout: 10_000 });
}

/** Read the current `content` attribute of <meta name="viewport">. */
async function getViewportMeta(page: Page): Promise<string> {
  return page.evaluate(() => {
    const meta = document.querySelector('meta[name="viewport"]');
    return meta ? (meta.getAttribute("content") ?? "") : "";
  });
}

// ---------------------------------------------------------------------------
// Suite 1 — Vanadium "Request Desktop Site" simulation
//
//   Playwright viewport : 980 × 2100  (desktop-mode layout viewport)
//   hasTouch            : true         (device is still a touch screen)
//   outerWidth override : 427          (real CSS pixel width of the phone)
//
//   Fix condition: iw (980) > ow (427) × 1.5 (640.5) ✓  AND  ow (427) < 600 ✓
// ---------------------------------------------------------------------------

test.describe("viewport-fix script — desktop-mode simulation (innerWidth=980, outerWidth=427)", () => {
  test.use({ viewport: { width: 980, height: 2100 }, hasTouch: true });

  test("outerWidth override is effective — addInitScript runs before page scripts", async ({ page }) => {
    await page.addInitScript(() => {
      Object.defineProperty(window, "outerWidth", { get: () => 427, configurable: true });
    });
    await openChat(page);

    // Verify the override itself worked — if this fails, addInitScript ordering is broken
    const outerWidth = await page.evaluate(() => window.outerWidth);
    expect(outerWidth).toBe(427);

    // Sanity: Playwright still controls innerWidth via CDP
    const innerWidth = await page.evaluate(() => window.innerWidth);
    expect(innerWidth).toBe(980);
  });

  test("fix fires — meta viewport tag is corrected to the real device width", async ({ page }) => {
    await page.addInitScript(() => {
      Object.defineProperty(window, "outerWidth", { get: () => 427, configurable: true });
    });
    await openChat(page);

    const content = await getViewportMeta(page);
    // The inline fix script must have set: width=427,initial-scale=1.0
    expect(content).toBe("width=427,initial-scale=1.0");
  });

  test("chat page loads without JS errors in simulated desktop-mode", async ({ page }) => {
    const errors: string[] = [];
    page.on("pageerror", (err) => errors.push(err.message));

    await page.addInitScript(() => {
      Object.defineProperty(window, "outerWidth", { get: () => 427, configurable: true });
    });
    await openChat(page);

    expect(errors, `unexpected JS errors: ${errors.join("; ")}`).toHaveLength(0);
    await expect(page.locator("select").first()).toBeAttached();
  });

  test("CSS zoom is applied to <html> to compensate for desktop-mode scale", async ({ page }) => {
    await page.addInitScript(() => {
      Object.defineProperty(window, "outerWidth", { get: () => 427, configurable: true });
    });
    await openChat(page);

    // The fix script sets html.style.zoom = innerWidth/outerWidth = 980/427 ≈ 2.295.
    // Per CSS Zoom spec (Chrome 128+) this divides the ICB by the zoom value so the
    // page lays out in a ~427 px coordinate space, counteracting the browser's scale.
    const zoom = await page.evaluate(() =>
      parseFloat(document.documentElement.style.zoom || "1")
    );
    expect(zoom).toBeGreaterThan(2.1);   // 980/427 ≈ 2.295
    expect(zoom).toBeLessThan(2.5);
  });
});

// ---------------------------------------------------------------------------
// Suite 2 — 980 px touch: mobile CSS must fire (Vanadium desktop-mode regression guard)
//
//   Vanadium in "Request Desktop Site" mode: innerWidth=980, pointer:coarse=true,
//   vvScale=0.435.  The CSS condition is now @media (pointer: coarse) with no
//   max-width clause — ALL touch devices get mobile layout regardless of viewport
//   width.  This is the correct policy: a touch device is a mobile context even
//   when the browser synthesises a wide layout viewport.
//
//   With mobile CSS firing at 980px:
//     • Both sidebars become drawers (off-screen) → full 980 px for content
//     • After 43.5 % scale: ~426 px effective width → mobile layout is correct
//
//   Guard: if this test starts failing, someone added a max-width guard to the
//   pointer:coarse rules again — Vanadium desktop mode will break immediately.
// ---------------------------------------------------------------------------

test.describe("Chat — 980 px touch CSS layout (Vanadium desktop mode)", () => {
  test.use({ viewport: { width: 980, height: 2100 }, hasTouch: true });

  test("hamburger IS shown at 980 px touch — pointer:coarse triggers mobile layout", async ({ page }) => {
    await openChat(page);

    // @media (pointer: coarse) fires → AppShell sidebar becomes a fixed drawer
    // and the hamburger button appears.  This frees the full 980 px for content.
    const hamburger = page.getByRole("button", { name: "Open navigation menu" });
    await expect(hamburger).toBeVisible({ timeout: 5_000 });
  });

  test("AppShell sidebar is a drawer (off-screen) at 980 px touch", async ({ page }) => {
    await openChat(page);

    const nav = page.locator("nav").first();
    await nav.waitFor({ state: "attached", timeout: 5_000 });
    const box = await nav.boundingBox();
    if (box) {
      expect(box.x + box.width,
        "sidebar nav must be fully off-screen (drawer closed) at 980 px touch"
      ).toBeLessThanOrEqual(0);
    }
  });

  test("config-bar first select clears the hamburger button at 980 px touch", async ({ page }) => {
    await openChat(page);

    const hamburger = page.getByRole("button", { name: "Open navigation menu" });
    await expect(hamburger).toBeVisible({ timeout: 5_000 });
    const hambBox = await hamburger.boundingBox();
    expect(hambBox).not.toBeNull();

    const firstSelect = page.locator("select").first();
    await expect(firstSelect).toBeVisible({ timeout: 5_000 });
    const box = await firstSelect.boundingBox();
    expect(box, "first config-bar select must have a bounding box").not.toBeNull();

    const hamburgerRight = hambBox!.x + hambBox!.width;
    expect(box!.x, "first select must clear the hamburger").toBeGreaterThanOrEqual(hamburgerRight - 4);
    expect(box!.x + box!.width, "first select right edge must fit within 980 px").toBeLessThanOrEqual(984);
  });
});

// ---------------------------------------------------------------------------
// Suite 4 — No false positive on a real desktop browser
//
//   Playwright viewport : 980 × 900, no touch, no addInitScript
//   outerWidth = innerWidth = 980
//
//   Fix condition: 980 > 980 × 1.5 (1470) → FALSE → fix must NOT fire
// ---------------------------------------------------------------------------

test.describe("viewport-fix script — no false positive on desktop (innerWidth=outerWidth=980)", () => {
  test.use({ viewport: { width: 980, height: 900 } });

  test("meta tag is unchanged — fix does not fire when outerWidth equals innerWidth", async ({ page }) => {
    // No addInitScript — outerWidth stays at Playwright's controlled 980
    await openChat(page);

    const content = await getViewportMeta(page);
    expect(content).toBe("width=device-width, initial-scale=1.0");
  });

  test("CSS zoom is not applied on real desktop", async ({ page }) => {
    await openChat(page);
    const zoom = await page.evaluate(() =>
      parseFloat(document.documentElement.style.zoom || "1")
    );
    expect(zoom).toBe(1);
  });
});

// ---------------------------------------------------------------------------
// Suite 5 — No false positive on a narrow-but-non-mobile viewport
//
//   Playwright viewport : 500 × 900, no touch, no addInitScript
//   outerWidth = innerWidth = 500  (satisfies ow < 600 but ratio = 1.0)
//
//   Fix condition: 500 > 500 × 1.5 (750) → FALSE → fix must NOT fire
// ---------------------------------------------------------------------------

test.describe("viewport-fix script — no false positive on narrow desktop (innerWidth=outerWidth=500)", () => {
  test.use({ viewport: { width: 500, height: 900 } });

  test("meta tag is unchanged — fix does not fire when ratio is 1 even if viewport < 600 px", async ({ page }) => {
    // No addInitScript — outerWidth stays at 500 (same as innerWidth)
    await openChat(page);

    const content = await getViewportMeta(page);
    expect(content).toBe("width=device-width, initial-scale=1.0");
  });

  test("CSS zoom is not applied on narrow desktop", async ({ page }) => {
    await openChat(page);
    const zoom = await page.evaluate(() =>
      parseFloat(document.documentElement.style.zoom || "1")
    );
    expect(zoom).toBe(1);
  });
});
