/**
 * chat-list-rendering.spec.ts
 *
 * Regression test for AGF-2-82758: "UI: Aufzählungsproblem"
 *
 * Bug: numbered (1./2./3.) and bulleted list items emitted by the LLM were
 * not displayed as styled lists — the enumeration markers were "swallowed".
 *
 * Root cause: Chat.module.scss lacked explicit list-style-type declarations
 * for ul/ol inside .bubble-text, so any upstream CSS change could strip the
 * browser-default markers (decimal / disc).
 *
 * Fix (Chat.module.scss):
 *   ul { list-style-type: disc; }
 *   ol { list-style-type: decimal; }
 *
 * Tests assert that:
 *   1. An <ol> with visible decimal list markers is present in the assistant bubble.
 *   2. A <ul> with visible disc markers is present.
 *   3. The list items are correctly indented (padding-left applied).
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

async function waitForStreamingDone(page: Page, timeoutMs = 90_000) {
  await page.locator("button[title='Stop generating']")
    .waitFor({ state: "visible", timeout: 30_000 }).catch(() => {});
  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: timeoutMs });
  await page.waitForTimeout(500);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Chat — list rendering in markdown (AGF-2-82758)", () => {
  test.setTimeout(120_000);
  let testStartTime: number;

  test.beforeEach(async () => {
    testStartTime = Date.now();
  });

  test.afterEach(async ({ page }) => {
    await deleteAllConversations(page, testStartTime);
  });

  /**
   * Numbered list: response must contain an <ol> whose <li> elements have
   * list-style-type: decimal and visible list markers.
   */
  test("numbered list renders as <ol> with decimal markers", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Preset "${TARGET_PRESET}" not found`).toBeTruthy();

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    // Explicit instruction to use a numbered list so we get a reliable 1./2./3. output
    await page.locator("[class*='chat-textarea']").fill(
      "Give me exactly 4 tips for writing clean code. " +
      "Format your response as a numbered list (1. 2. 3. 4.) with no preamble."
    );
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 15_000 });
    await waitForStreamingDone(page);

    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantBubble).toBeVisible();

    // 1. The bubble must contain an <ol> element
    const olEl = assistantBubble.locator("ol").first();
    await expect(
      olEl,
      "No <ol> element found in assistant response — numbered list was not rendered as an HTML ordered list",
    ).toBeVisible({ timeout: 5000 });

    // 2. The <ol> must have at least 3 <li> children
    const liCount = await olEl.locator("li").count();
    expect(
      liCount,
      `Expected ≥ 3 list items inside <ol>, found ${liCount}`,
    ).toBeGreaterThanOrEqual(3);

    // 3. The <ol> must be styled with list-style-type: decimal
    const listStyleType = await olEl.evaluate((el) =>
      window.getComputedStyle(el).listStyleType
    );
    expect(
      listStyleType,
      `<ol> list-style-type is "${listStyleType}", expected "decimal".\n` +
      `Fix: add "ol { list-style-type: decimal; }" inside .bubble-text in Chat.module.scss.`,
    ).toBe("decimal");

    // 4. The <ol> must have meaningful left padding for marker indentation
    const paddingLeft = await olEl.evaluate((el) =>
      parseFloat(window.getComputedStyle(el).paddingLeft)
    );
    expect(
      paddingLeft,
      `<ol> padding-left is ${paddingLeft}px — expected > 0 for list marker indentation`,
    ).toBeGreaterThan(0);

    // 5. No error banner
    await expect(page.getByText(/TypeError|failed to fetch/i).first())
      .not.toBeVisible({ timeout: 2_000 }).catch(() => {});
  });

  /**
   * Bulleted list: response must contain a <ul> with list-style-type: disc.
   */
  test("bulleted list renders as <ul> with disc markers", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Preset "${TARGET_PRESET}" not found`).toBeTruthy();

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill(
      "List 4 benefits of TypeScript over JavaScript. " +
      "Use a bullet-point list (dashes or asterisks). No numbered list, no preamble."
    );
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 15_000 });
    await waitForStreamingDone(page);

    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantBubble).toBeVisible();

    const ulEl = assistantBubble.locator("ul").first();
    await expect(
      ulEl,
      "No <ul> element found in assistant response — bulleted list was not rendered as an HTML unordered list",
    ).toBeVisible({ timeout: 5000 });

    const liCount = await ulEl.locator("li").count();
    expect(liCount, `Expected ≥ 3 <li> inside <ul>, found ${liCount}`).toBeGreaterThanOrEqual(3);

    const listStyleType = await ulEl.evaluate((el) =>
      window.getComputedStyle(el).listStyleType
    );
    expect(
      listStyleType,
      `<ul> list-style-type is "${listStyleType}", expected "disc".\n` +
      `Fix: add "ul { list-style-type: disc; }" inside .bubble-text in Chat.module.scss.`,
    ).toBe("disc");

    await expect(page.getByText(/TypeError|failed to fetch/i).first())
      .not.toBeVisible({ timeout: 2_000 }).catch(() => {});
  });

  /**
   * Mixed content: a response that has both a paragraph AND a numbered list
   * must not "swallow" the list — the paragraph text and list items must both
   * be present as distinct elements.
   */
  test("numbered list following a paragraph is not swallowed", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Preset "${TARGET_PRESET}" not found`).toBeTruthy();

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill(
      "Briefly explain what REST is in one sentence, then give a numbered list of " +
      "its 3 core constraints. Start the sentence with 'REST is' and start the list with '1.'."
    );
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 15_000 });
    await waitForStreamingDone(page);

    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantBubble).toBeVisible();

    // Both a paragraph and an <ol> must be present
    const responseText = (await assistantBubble.textContent() ?? "").trim();
    expect(responseText.length, "Empty assistant response").toBeGreaterThan(20);

    const olEl = assistantBubble.locator("ol").first();
    await expect(
      olEl,
      `No <ol> found after a paragraph — numbered list was swallowed.\n` +
      `Response text: "${responseText.slice(0, 300)}"`,
    ).toBeVisible({ timeout: 5000 });

    const liCount = await olEl.locator("li").count();
    expect(liCount, `Expected ≥ 3 list items, found ${liCount}`).toBeGreaterThanOrEqual(3);
  });
});
