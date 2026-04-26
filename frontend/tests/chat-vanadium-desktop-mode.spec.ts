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

import { test, expect, type Page } from "./base";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Navigate to /chat and wait until at least one <select> is attached.
 *  The meta viewport tag is written synchronously in <head> before React runs,
 *  so by the time any JS renders the fix has already fired (or not). */
async function openChat(page: Page) {
  await page.goto("/chat");
  await page.locator('[data-testid="config-bar"]').waitFor({ state: "attached", timeout: 10_000 });
  // If preset buttons are shown (preset mode), click the first one to enable the chat input.
  const firstPreset = page.locator('[data-testid="config-preset-btn"]').first();
  if (await firstPreset.isVisible({ timeout: 2000 }).catch(() => false)) {
    await firstPreset.click();
  }
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

    // At 980 px touch (pointer:coarse) the native config-bar selects are hidden
    // and replaced by the model chip.  Use the chip locator instead of "select".
    const modelChip = page.locator('[data-cy="model-chip"]');
    await expect(modelChip).toBeVisible({ timeout: 5_000 });
    const box = await modelChip.boundingBox();
    expect(box, "model chip must have a bounding box").not.toBeNull();

    const hamburgerRight = hambBox!.x + hambBox!.width;
    expect(box!.x, "model chip must clear the hamburger").toBeGreaterThanOrEqual(hamburgerRight - 4);
    expect(box!.x + box!.width, "model chip right edge must fit within 980 px").toBeLessThanOrEqual(984);
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

// ---------------------------------------------------------------------------
// Suite 6 — Virtual keyboard regression (Vanadium desktop mode)
//
//   Symptom: when the user taps the chat input, the browser opens the virtual
//   keyboard.  Vanadium uses the default "resizes-visual-viewport" mode:
//   window.innerHeight does NOT shrink, but visualViewport.height DOES.
//
//   Bug: the visualViewport.resize listener computes --real-height as
//   Math.round(window.innerHeight / z).  Because window.innerHeight is
//   unchanged, --real-height stays at the full-screen value.  .chat-page
//   remains taller than the visible area, the browser scroll-to-focused-input
//   kicks in, and the entire layout shoots upward — input visible in the
//   centre, everything else clipped.
//
//   Fix: the listener must use vv.height (which reflects keyboard state)
//   instead of window.innerHeight.
//
//   Test strategy:
//     1. Simulate desktop mode: innerWidth=980, outerWidth=427 → zoom ≈ 2.295
//        and --real-height is set on page load.
//     2. After load, override visualViewport.height to a keyboard-shrunken
//        value and dispatch "resize" on visualViewport.
//     3. Assert --real-height updated to Math.round(vv.height / zoom).
//        With the bug present --real-height stays at the pre-keyboard value.
// ---------------------------------------------------------------------------

test.describe("viewport-fix script — virtual keyboard shrinks --real-height (Vanadium desktop mode)", () => {
  test.use({ viewport: { width: 980, height: 2100 }, hasTouch: true });

  test("--real-height tracks visualViewport.height when keyboard opens", async ({ page }) => {
    await page.addInitScript(() => {
      Object.defineProperty(window, "outerWidth", { get: () => 427, configurable: true });
    });
    await openChat(page);

    // Confirm desktop-mode fix fired: zoom should be ~2.295
    const zoom = await page.evaluate(() =>
      parseFloat(document.documentElement.style.zoom || "1")
    );
    expect(zoom, "zoom must be applied before keyboard test runs").toBeGreaterThan(2.1);

    // Confirm initial --real-height was set correctly (≈ innerHeight / zoom)
    const initialRealHeight = await page.evaluate(() => {
      const v = getComputedStyle(document.documentElement)
        .getPropertyValue("--real-height").trim();
      return parseInt(v, 10);
    });
    const expectedInitial = Math.round(2100 / zoom);
    expect(initialRealHeight,
      `initial --real-height (${initialRealHeight}) should equal Math.round(innerHeight/zoom) (${expectedInitial})`
    ).toBeCloseTo(expectedInitial, -1); // within ±10 px

    // Simulate keyboard opening: override visualViewport.height to simulate
    // 600 layout-px being taken by the keyboard (window.innerHeight unchanged).
    const fakeVvHeight = 2100 - 600;
    await page.evaluate((h) => {
      // Override height on the prototype so our listener reads the fake value.
      Object.defineProperty(VisualViewport.prototype, "height", {
        get() { return h; },
        configurable: true,
      });
      // Fire the resize event that the index.html listener is attached to.
      window.visualViewport!.dispatchEvent(new Event("resize"));
    }, fakeVvHeight);

    // --real-height must now reflect the keyboard-shrunken visual viewport.
    const updatedRealHeight = await page.evaluate(() => {
      const v = getComputedStyle(document.documentElement)
        .getPropertyValue("--real-height").trim();
      return parseInt(v, 10);
    });
    const expectedUpdated = Math.round(fakeVvHeight / zoom);
    expect(updatedRealHeight,
      `after keyboard open, --real-height (${updatedRealHeight}) should be ` +
      `Math.round(vv.height/zoom) = ${expectedUpdated}, not the pre-keyboard ` +
      `${initialRealHeight} (which would mean window.innerHeight was used instead)`
    ).toBeCloseTo(expectedUpdated, -1);

    // Sanity: the updated value must be meaningfully smaller than the initial.
    expect(updatedRealHeight,
      "--real-height must shrink when keyboard opens"
    ).toBeLessThan(initialRealHeight - 100);
  });

  test("chat page height matches --real-height after keyboard simulation", async ({ page }) => {
    await page.addInitScript(() => {
      Object.defineProperty(window, "outerWidth", { get: () => 427, configurable: true });
    });
    await openChat(page);

    const zoom = await page.evaluate(() =>
      parseFloat(document.documentElement.style.zoom || "1")
    );
    expect(zoom).toBeGreaterThan(2.1);

    const fakeVvHeight = 2100 - 600;
    await page.evaluate((h) => {
      Object.defineProperty(VisualViewport.prototype, "height", {
        get() { return h; },
        configurable: true,
      });
      window.visualViewport!.dispatchEvent(new Event("resize"));
    }, fakeVvHeight);

    // The .chat-page element must be no taller than --real-height.
    // If it overflows, the browser scrolls the input into view (the bug).
    //
    // Coordinate note: getBoundingClientRect() returns layout-viewport CSS px
    // (pre-ICB-division), while --real-height is in ICB px (post-division).
    // We normalise by dividing chatPageHeight by zoom before comparing.
    const { chatPageHeightPx, realHeight, appliedZoom } = await page.evaluate(() => {
      const chatPage = document.querySelector<HTMLElement>(".chat-page, [class*='chat-page']");
      const rh = getComputedStyle(document.documentElement)
        .getPropertyValue("--real-height").trim();
      const z = parseFloat(document.documentElement.style.zoom || "1");
      return {
        chatPageHeightPx: chatPage ? chatPage.getBoundingClientRect().height : -1,
        realHeight: parseInt(rh, 10),
        appliedZoom: z,
      };
    });

    expect(chatPageHeightPx,
      "chat page must have a measurable height"
    ).toBeGreaterThan(0);

    // chatPageHeightPx is in layout-viewport px; divide by zoom → ICB px
    const chatPageHeightIcb = chatPageHeightPx / appliedZoom;
    expect(chatPageHeightIcb,
      `chat page height in ICB px (${chatPageHeightPx} / ${appliedZoom} = ${chatPageHeightIcb.toFixed(1)}) ` +
      `must not exceed --real-height (${realHeight}px) ` +
      `— overflow causes the browser to scroll the input into view`
    ).toBeLessThanOrEqual(realHeight + 2); // 2 px rounding tolerance
  });
});

// ---------------------------------------------------------------------------
// Suite 7 — Message submission does not scroll the page (Vanadium desktop mode)
//
//   Symptom: the first tap into the input is now fixed (Suite 6), but
//   pressing Enter/Send causes the same jump again.  Root causes:
//
//   A. ChatInput auto-resize: el.style.height = "auto" → brief layout
//      collapse while the textarea is focused.  The browser interprets the
//      focused element as no longer fully visible and issues a document-
//      level scroll to bring it back into view.
//
//   B. MessageThread.scrollIntoView({ behavior: "smooth" }) fires on every
//      new message.  With html.style.zoom > 1, Chrome's scrollIntoView
//      escapes the nearest scrollable ancestor (.thread) and scrolls the
//      document instead, lifting the entire page.
//
//   Both effects produce the same visible result: the layout jumps upward,
//   the input appears in the centre of the screen, and nothing else is
//   visible.
//
//   These tests verify that after a message is submitted:
//     1. document.documentElement.scrollTop remains 0
//     2. --real-height is not changed (keyboard-adjusted value is preserved)
//     3. The chat-page top edge stays at y=0 (layout not lifted)
// ---------------------------------------------------------------------------

test.describe("viewport-fix — message submission must not scroll the page (Vanadium desktop mode)", () => {
  test.use({ viewport: { width: 980, height: 2100 }, hasTouch: true });

  /** Simulate the desktop-mode + keyboard-open state and return the applied zoom.
   *
   *  To make scrollIntoView and focus-scroll actually trigger (so failures are
   *  detectable), we both:
   *    a) override visualViewport.height so our listener sets --real-height, AND
   *    b) actually resize the Playwright viewport to match — so the browser truly
   *       believes the available height is only vv.height layout-px tall.
   *
   *  Without (b) the browser viewport stays at 2100px, elements are always in
   *  view, and scrollIntoView is a no-op even when --real-height is wrong.
   */
  async function setupDesktopModeWithKeyboard(page: Page): Promise<{ zoom: number; keyboardRealHeight: number }> {
    await page.addInitScript(() => {
      Object.defineProperty(window, "outerWidth", { get: () => 427, configurable: true });
    });
    await openChat(page);

    // At this viewport (980px touch, outerWidth=427) the viewport-fix fires and
    // the layout becomes 427px mobile.  The model chip replaces the selects.
    // Select the first available option so the textarea becomes enabled.
    // css-zoom on html (≈2.3×) makes selectOption() fail actionability checks,
    // so drive the select directly via the native value setter + change event.
    const modelChip = page.locator('[data-cy="model-chip"]');
    await expect(modelChip.locator("option").first()).toBeAttached({ timeout: 10_000 });
    await page.evaluate(() => {
      const chip = document.querySelector('[data-cy="model-chip"]') as HTMLSelectElement;
      if (!chip || chip.options.length === 0) return;
      const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!;
      setter.call(chip, chip.options[0].value);
      chip.dispatchEvent(new Event("change", { bubbles: true }));
    });

    const zoom = await page.evaluate(() =>
      parseFloat(document.documentElement.style.zoom || "1")
    );
    expect(zoom, "desktop-mode zoom must be applied").toBeGreaterThan(2.1);

    // Keyboard takes 600 layout-viewport CSS px
    const KEYBOARD_PX = 600;
    const fakeVvHeight = 2100 - KEYBOARD_PX;

    // (a) override vv.height so our resize listener updates --real-height
    await page.evaluate((h) => {
      Object.defineProperty(VisualViewport.prototype, "height", {
        get() { return h; },
        configurable: true,
      });
      window.visualViewport!.dispatchEvent(new Event("resize"));
    }, fakeVvHeight);

    // (b) actually shrink the Playwright viewport to match — browser now truly
    //     sees only fakeVvHeight px of height, making scroll effects realistic
    await page.setViewportSize({ width: 980, height: fakeVvHeight });

    const keyboardRealHeight = await page.evaluate(() =>
      parseInt(getComputedStyle(document.documentElement).getPropertyValue("--real-height"), 10)
    );
    expect(keyboardRealHeight, "--real-height must shrink after keyboard open")
      .toBeLessThan(Math.round(2100 / zoom) - 100);

    return { zoom, keyboardRealHeight };
  }

  test("document does not scroll when a message is submitted", async ({ page }) => {
    const { keyboardRealHeight } = await setupDesktopModeWithKeyboard(page);

    // Wait for the input to be enabled (preset + model loaded)
    const textarea = page.locator("textarea").first();
    await expect(textarea).not.toBeDisabled({ timeout: 10_000 });

    // Type and submit
    const marker = `test-submit-${Date.now()}`;
    await textarea.fill(marker);
    await textarea.press("Enter");

    // Wait for the optimistic user message bubble to appear in the thread
    // (added synchronously in onSend before any API call)
    await expect(page.getByText(marker)).toBeVisible({ timeout: 5000 });

    // Assertion A: document root must not have scrolled
    const scrollTop = await page.evaluate(() => document.documentElement.scrollTop);
    expect(scrollTop,
      `document.documentElement.scrollTop must be 0 after submission — ` +
      `non-zero means scrollIntoView or focus-scroll lifted the layout`
    ).toBe(0);

    // Assertion B: --real-height must be unchanged (keyboard still open)
    const realHeightAfter = await page.evaluate(() =>
      parseInt(getComputedStyle(document.documentElement).getPropertyValue("--real-height"), 10)
    );
    expect(realHeightAfter,
      `--real-height (${realHeightAfter}) must equal pre-submission value (${keyboardRealHeight}) ` +
      `— a change means the layout expanded and contracted, causing the jump`
    ).toBeCloseTo(keyboardRealHeight, -1);

    // Assertion C: .chat-page top edge must still be at y=0
    const chatPageTop = await page.evaluate(() => {
      const el = document.querySelector<HTMLElement>("[class*='chat-page']");
      return el ? el.getBoundingClientRect().top : -1;
    });
    expect(chatPageTop,
      `chat-page top (${chatPageTop}px) must be 0 — non-zero means the page was lifted by scroll`
    ).toBeCloseTo(0, 0);

    // Assertion D: visual viewport must not have scrolled within layout viewport.
    // In Vanadium the symptom is visualViewport.offsetTop > 0 (not document.scrollTop > 0).
    const vvOffsetTop = await page.evaluate(() => window.visualViewport?.offsetTop ?? 0);
    expect(vvOffsetTop,
      `visualViewport.offsetTop must be 0 — non-zero means the browser scrolled the ` +
      `visual viewport to keep the focused element in view, lifting the layout`
    ).toBe(0);
  });

  test("send button submission does not scroll the page", async ({ page }) => {
    const { keyboardRealHeight } = await setupDesktopModeWithKeyboard(page);

    const textarea = page.locator("textarea").first();
    await expect(textarea).not.toBeDisabled({ timeout: 10_000 });

    const marker = `test-sendbtn-${Date.now()}`;
    await textarea.fill(marker);

    // Click the send button instead of pressing Enter
    const sendBtn = page.locator("[data-cy='send-btn'], [class*='send-btn']").last();
    await sendBtn.click();

    await expect(page.getByText(marker)).toBeVisible({ timeout: 5000 });

    const scrollTop = await page.evaluate(() => document.documentElement.scrollTop);
    expect(scrollTop,
      "document must not scroll after clicking Send button"
    ).toBe(0);

    const realHeightAfter = await page.evaluate(() =>
      parseInt(getComputedStyle(document.documentElement).getPropertyValue("--real-height"), 10)
    );
    expect(realHeightAfter).toBeCloseTo(keyboardRealHeight, -1);

    const vvOffsetTop = await page.evaluate(() => window.visualViewport?.offsetTop ?? 0);
    expect(vvOffsetTop,
      "visualViewport.offsetTop must be 0 after Send button click"
    ).toBe(0);
  });

  test("auto-resize height:auto does not trigger scroll when textarea is focused", async ({ page }) => {
    // This specifically targets the ChatInput auto-resize side effect:
    // el.style.height = "auto" fires while the textarea is focused.
    // In desktop-mode with zoom, this can trigger the browser's focus-scroll.
    const { keyboardRealHeight } = await setupDesktopModeWithKeyboard(page);

    const textarea = page.locator("textarea").first();
    await textarea.focus();

    // Directly trigger the auto-resize by setting and clearing value via evaluate,
    // which mimics what happens when setInputValue("") runs after submission.
    await page.evaluate(() => {
      const ta = document.querySelector("textarea")!;
      // Simulate the auto-resize sequence: height=auto then height=44px
      ta.style.height = "auto";
      ta.style.height = "44px";
      // Force a layout reflow while focused
      void ta.offsetHeight;
    });

    // Give the browser a frame to react
    await page.evaluate(() => new Promise(r => requestAnimationFrame(r)));

    const scrollTop = await page.evaluate(() => document.documentElement.scrollTop);
    expect(scrollTop,
      "setting textarea height:auto while focused must not scroll the document"
    ).toBe(0);

    const realHeightAfter = await page.evaluate(() =>
      parseInt(getComputedStyle(document.documentElement).getPropertyValue("--real-height"), 10)
    );
    expect(realHeightAfter).toBeCloseTo(keyboardRealHeight, -1);
  });
});
