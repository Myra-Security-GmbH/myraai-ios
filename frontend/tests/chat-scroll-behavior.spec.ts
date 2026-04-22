/**
 * chat-scroll-behavior.spec.ts
 *
 * Regression test for AGF-2-83501: "Falsches Scrollen beim Empfangen von Antworten"
 *
 * Bug: after a long response finished streaming the view was scrolled to the
 * very END of the response.  The user had to manually scroll back up to see
 * their own question and the beginning of the answer.
 *
 * Fix (MessageThread.tsx): when streaming transitions to done, scroll so the
 * last user message is near the top of the viewport instead of scrolling to
 * scrollHeight.
 *
 * Tests:
 *   1. After a long response the user's question row is visible (not scrolled
 *      out of the viewport above).
 *   2. During streaming the viewport follows the bottom (live content visible).
 *   3. If the user manually scrolls up during streaming, the post-completion
 *      re-scroll is suppressed (user intent respected).
 */

import { test, expect, Page } from "@playwright/test";

const ADMIN_URL     = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TARGET_TENANT = "myratest";
const TARGET_PRESET = "PII claude-sonnet-4-6";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function deleteAllConversations(page: Page, createdAfter?: number) {
  try {
    const resp = await page.context().request.get(`${ADMIN_URL}/admin/v1/conversations`);
    if (!resp.ok()) return;
    const convs = (await resp.json()) as Array<{ id: string; created_at?: string }>;
    for (const conv of convs) {
      if (createdAfter && conv.created_at && new Date(conv.created_at).getTime() < createdAfter) continue;
      await page.context().request.delete(`${ADMIN_URL}/admin/v1/conversations/${conv.id}`).catch(() => {});
    }
  } catch { /* best-effort */ }
}

async function selectPreset(page: Page): Promise<boolean> {
  await page.goto("/chat");
  await page.waitForTimeout(600);

  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  const tenantOpt = tenantSel.locator("option").filter({ hasText: new RegExp(TARGET_TENANT, "i") });
  if ((await tenantOpt.count()) === 0) return false;
  await tenantSel.selectOption({ label: (await tenantOpt.first().textContent()) ?? TARGET_TENANT });
  await page.waitForTimeout(600);

  const presetBtn = page.locator("button").filter({
    hasText: new RegExp(TARGET_PRESET.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i"),
  });
  if (!(await presetBtn.isVisible({ timeout: 5000 }).catch(() => false))) return false;
  await presetBtn.click();
  await page.waitForTimeout(400);
  return true;
}

async function waitForStreamingComplete(page: Page, timeoutMs = 120_000) {
  await page.locator("button[title='Stop generating']")
    .waitFor({ state: "visible", timeout: 30_000 }).catch(() => {});
  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: timeoutMs });
  // Let React commit the final state
  await page.waitForTimeout(800);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Chat — scroll-to-question after streaming (AGF-2-83501)", () => {
  test.setTimeout(180_000);
  let testStartTime: number;

  test.beforeEach(async () => {
    testStartTime = Date.now();
  });

  test.afterEach(async ({ page }) => {
    await deleteAllConversations(page, testStartTime);
  });

  /**
   * Core regression: after a multi-paragraph response completes, the user's
   * question bubble must be visible (not scrolled above the viewport).
   */
  test("user question is visible after long response completes", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Preset "${TARGET_PRESET}" not found — check myratest tenant config`).toBeTruthy();

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    // Prompt that forces a long multi-section response
    const prompt =
      "Write a detailed technical explanation of how HTTPS/TLS works. " +
      "Cover: the TLS handshake, certificate chains, symmetric vs asymmetric encryption, " +
      "HSTS, certificate pinning, and common vulnerabilities. " +
      "Write at least two paragraphs per topic.";

    await page.locator("[class*='chat-textarea']").fill(prompt);
    await page.locator("button[title='Send message']").click();

    // Wait for the user bubble to appear
    const userRow = page.locator("[class*='user-row']").last();
    await expect(userRow).toBeVisible({ timeout: 15_000 });

    // Wait for streaming to complete
    await waitForStreamingComplete(page);

    // After completion, the user row must be within the visible scroll area.
    // We check that its bounding box top is >= 0 (not scrolled above viewport)
    // and that it's not off-screen below either.
    const threadEl = page.locator("[class*='thread']").first();
    const { threadTop, threadBottom, rowTop, rowBottom } = await page.evaluate(() => {
      const thread = document.querySelector("[class*='thread']") as HTMLElement | null;
      const userRows = thread?.querySelectorAll("[class*='user-row']");
      const lastRow = userRows && userRows.length > 0
        ? userRows[userRows.length - 1] as HTMLElement
        : null;

      if (!thread || !lastRow) return { threadTop: 0, threadBottom: 0, rowTop: -1, rowBottom: -1 };

      const tr = thread.getBoundingClientRect();
      const rr = lastRow.getBoundingClientRect();
      return {
        threadTop:    tr.top,
        threadBottom: tr.bottom,
        rowTop:       rr.top,
        rowBottom:    rr.bottom,
      };
    });

    expect(rowTop, "Could not find last user-row element").toBeGreaterThanOrEqual(0);

    // The user row's top edge must be within the thread viewport (not above it)
    expect(
      rowTop,
      `User question is above the visible thread area after streaming completed.\n` +
      `rowTop=${rowTop}, threadTop=${threadTop}\n` +
      `Fix: MessageThread.tsx must scroll to show the user question, not scrollHeight.`,
    ).toBeGreaterThanOrEqual(threadTop - 5); // 5 px tolerance

    // The user row must not be fully below the viewport either
    expect(
      rowTop,
      "User question is completely below the visible thread area (unexpected)",
    ).toBeLessThan(threadBottom);
  });

  /**
   * During streaming the live content must be visible (scroll follows the bottom).
   * We send a request and immediately check that streaming content is visible
   * before it completes.
   */
  test("live content is visible during streaming (bottom-follow)", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Preset "${TARGET_PRESET}" not found`).toBeTruthy();

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill(
      "List and briefly describe 15 different sorting algorithms. Include time complexity for each."
    );
    await page.locator("button[title='Send message']").click();

    // Wait for first assistant bubble to appear
    const assistantRow = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    await expect(assistantRow).toBeVisible({ timeout: 30_000 });

    // During streaming, check that the streaming cursor OR the stop button is
    // visible and that the thread is scrolled near the bottom.
    await page.locator("button[title='Stop generating']")
      .waitFor({ state: "visible", timeout: 15_000 });

    const isNearBottom = await page.evaluate(() => {
      const thread = document.querySelector("[class*='thread']") as HTMLElement | null;
      if (!thread) return false;
      const distFromBottom = thread.scrollHeight - thread.scrollTop - thread.clientHeight;
      return distFromBottom < 200; // within 200 px of bottom during streaming
    });

    expect(
      isNearBottom,
      "Thread is not scrolled near the bottom during streaming — live content may not be visible",
    ).toBe(true);

    await waitForStreamingComplete(page);
  });

  /**
   * If the user manually scrolls up during streaming, the post-completion
   * re-scroll must be suppressed (respect user intent).
   */
  test("post-completion re-scroll is suppressed when user scrolled up during streaming", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Preset "${TARGET_PRESET}" not found`).toBeTruthy();

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill(
      "List and briefly describe 20 different design patterns. Include a one-sentence example for each."
    );
    await page.locator("button[title='Send message']").click();

    // Wait for streaming to start
    await page.locator("button[title='Stop generating']")
      .waitFor({ state: "visible", timeout: 20_000 });

    // Simulate user scrolling up by 300px while streaming
    await page.evaluate(() => {
      const thread = document.querySelector("[class*='thread']") as HTMLElement | null;
      if (thread) thread.scrollTop = Math.max(0, thread.scrollTop - 300);
      // Fire a scroll event so the component detects it as user-initiated
      thread?.dispatchEvent(new Event("scroll"));
    });

    // Record position immediately after manual scroll
    const posAfterManualScroll = await page.evaluate(() => {
      const thread = document.querySelector("[class*='thread']") as HTMLElement | null;
      return thread ? thread.scrollTop : 0;
    });

    await waitForStreamingComplete(page);

    // Position after completion should be close to where user manually placed it
    // (within 200px), not jumped back to bottom or user-question position.
    const posAfterCompletion = await page.evaluate(() => {
      const thread = document.querySelector("[class*='thread']") as HTMLElement | null;
      return thread ? thread.scrollTop : 0;
    });

    expect(
      Math.abs(posAfterCompletion - posAfterManualScroll),
      `Scroll position changed by ${Math.abs(posAfterCompletion - posAfterManualScroll)}px after completion, ` +
      `but user had manually scrolled — position should be preserved.\n` +
      `Before: ${posAfterManualScroll}, After: ${posAfterCompletion}`,
    ).toBeLessThanOrEqual(200);
  });
});
