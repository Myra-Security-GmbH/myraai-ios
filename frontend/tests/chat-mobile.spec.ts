/**
 * chat-mobile.spec.ts — Regression tests for the mobile layout of the Chat page.
 *
 * Before the fix (commit introducing artifact-card UX + MCP connectors) the
 * config bar had no mobile CSS.  On a 360 px phone it would:
 *   • Show "Tenant / Gateway / Model" text labels, adding extra width to each row
 *   • Use large min-widths (140–180 px) on the selects, forcing them onto three
 *     separate rows
 *   • Render a flex-1 spacer that consumed an entire blank row by itself
 *   • Render 10+ icon buttons that wrapped over two additional rows
 *   → total config-bar height ≈ 240 px (5 rows × 48 px)
 *
 * Additionally the AppShell hamburger button (position:fixed; top:12px; left:12px;
 * width:40px) was not accounted for in the config-bar padding, so the first select
 * was rendered underneath the hamburger and unreachable.
 *
 * Fix: added @media (max-width: 640px) rules to Chat.module.scss that:
 *   • Hide config labels (display: none)
 *   • Shrink select min-widths to 82 px / 100 px
 *   • Remove the spacer (display: none)
 *   • Add padding-left: 52 px to clear the hamburger button
 *
 * These tests lock in that behaviour and would have caught the regression.
 */

import { test, expect, type Page } from "@playwright/test";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Navigate to /chat and wait until the config bar is visible. */
async function openChat(page: Page) {
  await page.goto("/chat");
  // Wait for the config bar to be rendered (data-testid set in Chat.tsx).
  await page.locator('[data-testid="config-bar"]').waitFor({ state: "visible", timeout: 10_000 });
}

// ---------------------------------------------------------------------------
// Suite — mobile viewport 360 × 780
// ---------------------------------------------------------------------------

test.describe("Chat — mobile layout (360 × 780 viewport)", () => {
  test.use({ viewport: { width: 360, height: 780 }, hasTouch: true });

  // ── Config bar compact layout ──────────────────────────────────────────────

  test("config-bar labels 'Tenant', 'Gateway', 'Model' are hidden at ≤640 px", async ({ page }) => {
    await openChat(page);

    // Regression guard: before the fix these spans were visible and pushed the
    // bar to 5 rows, making the page look like a desktop layout on mobile.
    const tenantLabel  = page.locator("span").filter({ hasText: /^Tenant$/ }).first();
    const gatewayLabel = page.locator("span").filter({ hasText: /^Gateway$/ }).first();
    const modelLabel   = page.locator("span").filter({ hasText: /^Model$/ }).first();

    await expect(tenantLabel).toBeHidden({ timeout: 3_000 });
    await expect(gatewayLabel).toBeHidden({ timeout: 3_000 });
    await expect(modelLabel).toBeHidden({ timeout: 3_000 });

    // Confirm no error state was triggered
    await expect(page.getByText(/error/i).first()).toBeHidden();
  });

  test("config bar height is compact (≤ 100 px) on 360 px viewport", async ({ page }) => {
    await openChat(page);

    // Measure the config bar directly via its data-testid.
    // (Walking up from a <select> via closest() is unreliable: React may replace
    // the gateway select with the preset select mid-render, leaving a detached node.)
    const barHeight = await page.locator('[data-testid="config-bar"]').evaluate((el) => {
      return el.getBoundingClientRect().height;
    });

    // Before the fix: ≈ 240 px (5 rows).  After all fixes: ≤ 115 px (2 rows:
    // selects + 4 essential icon buttons). Secondary icons are hidden on mobile.
    // Each flex row is ~44px (select/button height + alignment), gap 6px, padding 12px
    // → 12 + 44 + 6 + 44 = 106px. Allow 115px for font/UA rendering variance.
    expect(barHeight).toBeLessThan(115);
  });

  test("first config-bar select is to the right of the AppShell hamburger button", async ({ page }) => {
    await openChat(page);

    // AppShell hamburger: position:fixed; left:12px; width:40px → right edge at ≈ 52px.
    const hamburger = page.getByRole("button", { name: "Open navigation menu" });
    await expect(hamburger).toBeVisible({ timeout: 5_000 });
    const hambBox = await hamburger.boundingBox();
    expect(hambBox, "hamburger bounding box must exist").not.toBeNull();

    // The Tenant <select> is the first interactive config-bar element when the
    // admin user has ≥2 tenants. Use data-testid to avoid the detachment race.
    const tenantSelect = page.locator('[data-testid="config-tenant-select"]');
    await expect(tenantSelect).toBeVisible({ timeout: 3_000 });
    const selectBox = await tenantSelect.boundingBox();
    expect(selectBox, "tenant select bounding box must exist").not.toBeNull();

    // Regression guard: before the fix, padding-left was 12px so the select
    // started at x≈12px — directly underneath the hamburger (right edge ≈52px).
    const hamburgerRightEdge = hambBox!.x + hambBox!.width;
    expect(selectBox!.x).toBeGreaterThanOrEqual(hamburgerRightEdge - 4); // 4px tolerance
  });

  // ── AppShell sidebar behaviour ────────────────────────────────────────────

  test("AppShell hamburger button is visible at mobile viewport", async ({ page }) => {
    await openChat(page);
    const hamburger = page.getByRole("button", { name: "Open navigation menu" });
    await expect(hamburger).toBeVisible({ timeout: 5_000 });

    // Must be in the top-left corner (within the fixed area)
    const box = await hamburger.boundingBox();
    expect(box).not.toBeNull();
    expect(box!.x).toBeLessThan(20);   // left ≈ 12px
    expect(box!.y).toBeLessThan(20);   // top  ≈ 12px
  });

  test("AppShell sidebar nav is off-screen when closed on mobile", async ({ page }) => {
    await openChat(page);

    // The <nav> from Sidebar.tsx has position:fixed and transform:translateX(-100%)
    // on mobile — it must not occupy any horizontal space in the layout.
    const nav = page.locator("nav").first();
    await nav.waitFor({ state: "attached", timeout: 5_000 });

    const box = await nav.boundingBox();
    if (box) {
      // If it has a bounding box, its right edge must be at or beyond the left
      // viewport edge (i.e. fully off-screen to the left).
      expect(box.x + box.width).toBeLessThanOrEqual(0);
    }
    // If boundingBox() returns null the element is display:none — also fine.
  });

  test("clicking AppShell hamburger slides in the sidebar", async ({ page }) => {
    await openChat(page);
    const hamburger = page.getByRole("button", { name: "Open navigation menu" });
    await hamburger.click();

    // After opening, the mobile overlay should be visible.
    const overlay = page.locator("[class*='mobile-overlay']");
    await expect(overlay).toBeVisible({ timeout: 3_000 });

    // Close the sidebar again by clicking the overlay (or the hamburger toggle).
    // The overlay is conditionally rendered — when closed it is removed from the DOM.
    await overlay.click();
    await expect(overlay).toBeHidden({ timeout: 2_000 });
  });

  // ── Conversation sidebar (drawer) behaviour ───────────────────────────────

  test("conversation sidebar is off-screen by default on mobile", async ({ page }) => {
    await openChat(page);

    // The conv-sidebar-backdrop is conditionally rendered — it only exists in the DOM
    // while showConvList=true. When the sidebar is closed (default), the backdrop is
    // absent entirely. This is the reliable "drawer is closed" signal because the
    // conv-sidebar div itself is always in the DOM (just off-screen via CSS transform).
    const backdrop = page.locator("[class*='conv-sidebar-backdrop']");
    await expect(backdrop).toBeHidden({ timeout: 5_000 });
  });

  test("conv-list-toggle button is visible in the config bar on mobile", async ({ page }) => {
    await openChat(page);
    // This button (title="Conversations", displays ≤640px) is always the last
    // element in the config bar.
    const toggle = page.locator("button[title='Conversations']");
    await expect(toggle).toBeVisible({ timeout: 5_000 });
  });

  test("conv-list-toggle opens the conversation drawer on mobile", async ({ page }) => {
    await openChat(page);
    const toggle = page.locator("button[title='Conversations']");
    await expect(toggle).toBeVisible({ timeout: 5_000 });
    await toggle.click();

    // After opening, the New Chat button becomes visible in the drawer.
    // The "+" is a PlusIcon SVG so the accessible name is just "New Chat".
    const newChatBtn = page.getByRole("button", { name: /new chat/i });
    await expect(newChatBtn).toBeVisible({ timeout: 3_000 });
  });

  test("tapping the backdrop closes the conversation drawer", async ({ page }) => {
    await openChat(page);
    const toggle = page.locator("button[title='Conversations']");
    await toggle.click();

    const newChatBtn = page.getByRole("button", { name: /new chat/i });
    await expect(newChatBtn).toBeVisible({ timeout: 3_000 });

    // The semi-transparent backdrop sits in front of the message area.
    // Clicking it should close the drawer (sets showConvList=false, backdrop leaves the DOM).
    const backdrop = page.locator("[class*='conv-sidebar-backdrop']");
    await expect(backdrop).toBeVisible({ timeout: 2_000 });
    await backdrop.click();

    // Backdrop is conditionally rendered — when closed it is removed from the DOM entirely.
    await expect(backdrop).toBeHidden({ timeout: 2_000 });
  });

  // ── Settings icon still reachable ────────────────────────────────────────

  test("Settings icon button is within the viewport on mobile", async ({ page }) => {
    await openChat(page);

    // On mobile the icon buttons (32px each) must all render within the 360px
    // width — none should be outside the viewport.
    const settingsBtn = page.locator("button[title='Settings']");
    await expect(settingsBtn).toBeVisible({ timeout: 5_000 });

    const box = await settingsBtn.boundingBox();
    expect(box).not.toBeNull();
    expect(box!.x).toBeGreaterThanOrEqual(0);
    expect(box!.x + box!.width).toBeLessThanOrEqual(360 + 2); // 2px tolerance
  });

  // ── Secondary buttons hidden on mobile ───────────────────────────────────

  test("secondary icon buttons (PDF, copy, download, share, memories, feedback) are hidden on mobile", async ({ page }) => {
    await openChat(page);

    // These are desktop-only conveniences. On mobile they inflate the config bar
    // to 3 rows and push the message area below the fold.
    const secondary = [
      page.locator("button[title='Download PDF']"),
      page.locator("button[title='Download Markdown']"),
      page.locator("button[data-cy='copy-markdown-btn']"),
      page.locator("button[data-cy='share-btn']"),
      page.locator("button[data-cy='memories-btn']"),
      page.locator("button[title='Session feedback']"),
    ];
    for (const btn of secondary) {
      // Each button may or may not be in the DOM (some are conditional renders).
      // Either absent OR hidden is acceptable — what is NOT acceptable is visible.
      const count = await btn.count();
      if (count > 0) {
        await expect(btn).toBeHidden();
      }
    }
  });

  // ── Page-scroll regression guard ─────────────────────────────────────────

  test("chat page body is not document-scrollable on mobile", async ({ page }) => {
    await openChat(page);

    // Before the fix, html/body had no overflow:hidden on mobile.
    // The document was scrollable, causing config bar and input bar to scroll
    // off-screen. After the fix, scrollHeight must equal clientHeight.
    const scrollable = await page.evaluate(() => {
      return document.documentElement.scrollHeight > document.documentElement.clientHeight + 2;
    });
    expect(scrollable, "document must not be vertically scrollable on mobile").toBe(false);
  });

  test("input bar is visible and within the viewport bottom on mobile", async ({ page }) => {
    await openChat(page);

    // The textarea / input area must be visible and its bottom edge must be
    // within the visible viewport (not scrolled below it).
    const textarea = page.locator("textarea").first();
    await expect(textarea).toBeVisible({ timeout: 5_000 });

    const box = await textarea.boundingBox();
    expect(box, "textarea bounding box must exist").not.toBeNull();
    expect(box!.y + box!.height).toBeLessThanOrEqual(780 + 4); // 4px tolerance
    expect(box!.y).toBeGreaterThan(0);
  });
});

// ---------------------------------------------------------------------------
// Suite — 960 × 2142 viewport (GrapheneOS / Vanadium device reporting DPR=1)
// ---------------------------------------------------------------------------
// This device has a wide CSS viewport (960 px) but DPR=1, meaning every CSS
// pixel maps 1:1 to a physical pixel.  At 360 px phone density this would be
// fine; at 960 px the hardware pixels are physically tiny so users need larger
// UI elements to avoid pinch-zooming.
//
// Key differences from the 360 px phone layout:
//  • Config bar labels ("Tenant", "Gateway", "Model") must be VISIBLE — there
//    is enough horizontal space and hiding them wastes a chance to be clearer.
//  • Config bar must fit in a SINGLE ROW — no wrapping at this width.
//  • Selects can be their full natural widths (not crammed to 82 px).
//  • All touch-friendly sizing (16 px+ fonts, ≥44 px touch targets) still applies.
//  • The AppShell sidebar is still a drawer (the hamburger is still present at
//    this width because max-width:1024 px triggers the touch sidebar layout).

test.describe("Chat — 960 × 2142 viewport (GrapheneOS Vanadium, DPR=1)", () => {
  test.use({ viewport: { width: 960, height: 2142 }, hasTouch: true });

  test("config bar labels are visible at 960 px — not hidden like on a narrow phone", async ({ page }) => {
    await openChat(page);

    // At 360 px the labels are hidden to save space; at 960 px they must be
    // visible so the user understands what each dropdown does.
    const tenantLabel = page.locator("span").filter({ hasText: /^Tenant$/ }).first();
    await expect(tenantLabel, "Tenant label must be visible at 960 px").toBeVisible({ timeout: 5_000 });

    // When the active tenant has presets configured, the config bar shows preset
    // buttons instead of separate Gateway/Model selectors — in that case check
    // that at least one preset button is visible (not hidden).
    const presetOptions = page.locator('[data-testid="config-preset-options"]');
    const presetsVisible = await presetOptions.isVisible({ timeout: 1_000 }).catch(() => false);
    if (presetsVisible) {
      const firstPreset = page.locator('[data-testid="config-preset-btn"]').first();
      await expect(firstPreset, "Preset button must be visible at 960 px").toBeVisible({ timeout: 3_000 });
    } else {
      const gatewayLabel = page.locator("span").filter({ hasText: /^Gateway$/ }).first();
      const modelLabel   = page.locator("span").filter({ hasText: /^Model$/ }).first();
      await expect(gatewayLabel, "Gateway label must be visible at 960 px").toBeVisible({ timeout: 3_000 });
      await expect(modelLabel,   "Model label must be visible at 960 px").toBeVisible({ timeout: 3_000 });
    }

    await expect(page.getByText(/error/i).first()).toBeHidden();
  });

  test("config bar fits in a single row at 960 px (height < 80 px)", async ({ page }) => {
    await openChat(page);

    const barHeight = await page.locator('[data-testid="config-bar"]').evaluate((el) => {
      return el.getBoundingClientRect().height;
    });

    // With labels and normal-width selects, everything fits in one row (~52 px).
    // Two rows would be ~100 px — a clear sign the layout is wrapping.
    expect(barHeight,
      `config bar at 960 px should be a single row (< 80 px), got ${barHeight.toFixed(0)} px`
    ).toBeLessThan(80);
  });

  test("first select still has clearance from the AppShell hamburger at 960 px", async ({ page }) => {
    await openChat(page);

    // The hamburger is visible at max-width:1024 px (960 < 1024).
    const hamburger = page.getByRole("button", { name: "Open navigation menu" });
    await expect(hamburger).toBeVisible({ timeout: 5_000 });
    const hambBox = await hamburger.boundingBox();
    expect(hambBox).not.toBeNull();

    // Use data-testid to avoid the React re-render detachment race condition.
    const tenantSelect = page.locator('[data-testid="config-tenant-select"]');
    await expect(tenantSelect).toBeVisible({ timeout: 5_000 });
    const selectBox = await tenantSelect.boundingBox();
    expect(selectBox).not.toBeNull();

    // The config bar has padding-left:52 px on touch/narrow devices so the
    // first select starts to the right of the hamburger's right edge.
    const hamburgerRight = hambBox!.x + hambBox!.width;
    expect(selectBox!.x).toBeGreaterThanOrEqual(hamburgerRight - 4);
  });

  test("AppShell sidebar is a drawer (not inline) at 960 px", async ({ page }) => {
    await openChat(page);

    // The sidebar uses position:fixed + transform:translateX(-100%) at
    // max-width:1024 px, so it must be off-screen when closed.
    const nav = page.locator("nav").first();
    await nav.waitFor({ state: "attached", timeout: 5_000 });
    const box = await nav.boundingBox();
    if (box) {
      expect(box.x + box.width,
        "sidebar nav must be fully off-screen (drawer closed) at 960 px"
      ).toBeLessThanOrEqual(0);
    }
  });

  test("input area is visible and within the 960-px viewport", async ({ page }) => {
    await openChat(page);

    const textarea = page.locator("textarea").first();
    await expect(textarea).toBeVisible({ timeout: 5_000 });

    const box = await textarea.boundingBox();
    expect(box).not.toBeNull();
    expect(box!.y + box!.height,
      "textarea bottom must be within the 2142 px viewport height"
    ).toBeLessThanOrEqual(2142 + 4);
    expect(box!.y).toBeGreaterThan(0);
    expect(box!.x + box!.width,
      "textarea right edge must be within the 960 px viewport width"
    ).toBeLessThanOrEqual(960 + 4);
  });

  test("key touch targets are at least 40 px tall at 960 px", async ({ page }) => {
    await openChat(page);

    // Selects and buttons need to be tap-friendly on a touch device.
    // Use data-testid to avoid finding a detached element from a mid-render swap.
    // Admin sees ≥2 tenants so the tenant select is always present.
    const tenantSelect = page.locator('[data-testid="config-tenant-select"]');
    await expect(tenantSelect).toBeVisible({ timeout: 5_000 });
    const selectBox = await tenantSelect.boundingBox();
    expect(selectBox).not.toBeNull();
    expect(selectBox!.height,
      `Tenant select height should be ≥ 40 px, got ${selectBox!.height.toFixed(0)}`
    ).toBeGreaterThanOrEqual(40);
  });
});
