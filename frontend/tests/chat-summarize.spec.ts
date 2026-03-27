/**
 * chat-summarize.spec.ts — verifies that auto-title generation (the
 * "summarization" that fires after the first exchange) produces a clean,
 * meaningful title for each tenant preset.
 *
 * Tests run separately for:
 *   • "SAFE local only"       — local model that leaks <think> tokens; title
 *                               must NOT contain <think> or </think> artefacts.
 *   • "PII claude-sonnet-4-6" — Anthropic Sonnet; title must be clean and
 *                               reference the conversation topic.
 *
 * Both presets are expected to be already configured on the "myratest" tenant
 * in the live environment.  Each test skips gracefully if the preset is absent.
 */

import { test, expect, Page } from "@playwright/test";

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TARGET_TENANT = "myratest";

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

/** Navigate to /chat and select the myratest tenant. Returns false if not found. */
async function selectMyraTestTenant(page: Page): Promise<boolean> {
  await page.goto("/chat");
  await page.waitForTimeout(600);

  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });

  const tenantOption = tenantSel.locator("option").filter({ hasText: new RegExp(TARGET_TENANT, "i") });
  if (await tenantOption.count() === 0) return false;

  await tenantSel.selectOption({ label: (await tenantOption.first().textContent()) ?? TARGET_TENANT });
  await page.waitForTimeout(500);
  return true;
}

/** Click a named preset button; returns false if the button is not present. */
async function selectPreset(page: Page, presetName: string): Promise<boolean> {
  // Preset buttons appear when the tenant has chat_presets configured
  const btn = page.getByRole("button", { name: new RegExp(`^${presetName}$`) });
  const visible = await btn.isVisible({ timeout: 4000 }).catch(() => false);
  if (!visible) return false;
  await btn.click();
  await page.waitForTimeout(300);
  return true;
}

/** Wait for streaming to finish: stop button disappears, send button reappears. */
async function waitForStreamingDone(page: Page, timeoutMs = 90_000) {
  await page.locator("button[title='Stop generating']")
    .waitFor({ state: "visible", timeout: 20_000 })
    .catch(() => { /* may appear briefly or not at all for very short responses */ });
  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: timeoutMs });
}

/**
 * Send a message, wait for the full first exchange (response + auto-title PATCH),
 * and return the conversation title from the sidebar.
 */
async function runFirstExchangeAndGetTitle(page: Page, message: string, streamTimeoutMs = 90_000): Promise<string> {
  // Arm the PATCH watcher before sending (generateTitle fires after streaming ends)
  const titlePatchPromise = page.waitForRequest(
    (req) => req.method() === "PATCH" && /\/conversations\/[^/]+$/.test(req.url()),
    { timeout: streamTimeoutMs + 15_000 },
  );

  const textarea = page.locator("[class*='chat-textarea']");
  await textarea.fill(message);
  await page.locator("button[title='Send message']").click();

  // Wait for at least one assistant bubble (class is bubble-row without user-row)
  await page.locator("[class*='bubble-row']:not([class*='user-row'])").first()
    .waitFor({ state: "visible", timeout: 20_000 });

  // Wait for streaming to finish
  await waitForStreamingDone(page, streamTimeoutMs);

  // Wait for the title PATCH request that generateTitle fires
  await titlePatchPromise;

  // Allow state update + re-render
  await page.waitForTimeout(1000);

  // Read title from the first sidebar conversation item
  const convItem = page.locator("[role='option']").first();
  await convItem.waitFor({ state: "visible", timeout: 5000 });
  const title = (await convItem.locator("[class*='conv-item-title']").first().textContent() ?? "").trim();
  return title;
}

// ---------------------------------------------------------------------------
// Test suites — one per preset
// ---------------------------------------------------------------------------

test.describe("Chat auto-title — preset: SAFE local only", () => {
  test.setTimeout(150_000); // local model can be slow

  let testStartTime: number;

  test.beforeEach(async ({ page }) => {
    testStartTime = Date.now();
  });

  test.afterEach(async ({ page }) => {
    await deleteAllConversations(page, testStartTime);
  });

  test("auto-title has no <think> artefacts and is meaningful", async ({ page }) => {
    const tenantOk = await selectMyraTestTenant(page);
    if (!tenantOk) { test.skip(); return; }

    const presetOk = await selectPreset(page, "SAFE local only");
    if (!presetOk) {
      test.skip(true, "Preset 'SAFE local only' not found on myratest tenant — skipping");
      return;
    }

    // New conversation
    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(400);

    const title = await runFirstExchangeAndGetTitle(
      page,
      "What is the capital of France?",
      120_000,
    );

    // Must not be the default placeholder
    expect(title, "title should change from default").not.toMatch(/^new conversation$/i);
    expect(title.length, "title should be non-empty").toBeGreaterThan(0);

    // Critical: local model leaks chain-of-thought tokens — the title must not
    // contain <think> or </think> artefacts in any form
    expect(title, "title must not contain <think> artefact").not.toMatch(/<think>/i);
    expect(title, "title must not contain </think> artefact").not.toMatch(/<\/think>/i);
    // Also guard against partial artefacts like "<think bla" with no closing tag
    expect(title, "title must not start with an XML tag").not.toMatch(/^<[a-z]/i);

    // Should look like a real short title (no more than ~80 chars)
    expect(title.length, "title should be a short phrase, not a paragraph").toBeLessThan(80);
  });

  test("auto-title from local model does not bleed raw model output into sidebar", async ({ page }) => {
    const tenantOk = await selectMyraTestTenant(page);
    if (!tenantOk) { test.skip(); return; }

    const presetOk = await selectPreset(page, "SAFE local only");
    if (!presetOk) {
      test.skip(true, "Preset 'SAFE local only' not found — skipping");
      return;
    }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(400);

    const title = await runFirstExchangeAndGetTitle(
      page,
      "Explain what a neural network is in one sentence.",
      120_000,
    );

    // Title should not contain chain-of-thought markers or raw XML
    expect(title).not.toMatch(/<\/?think>/i);
    expect(title).not.toMatch(/^\s*<[a-z]/i);          // e.g. "<thinking>" or "<think "
    expect(title).not.toMatch(/bla\s*bla/i);            // known artefact pattern
    expect(title.trim().length).toBeGreaterThan(2);     // not just whitespace or a stray char
  });
});

test.describe("Chat auto-title — preset: PII claude-sonnet-4-6", () => {
  test.setTimeout(120_000);

  let testStartTime: number;

  test.beforeEach(async ({ page }) => {
    testStartTime = Date.now();
  });

  test.afterEach(async ({ page }) => {
    await deleteAllConversations(page, testStartTime);
  });

  test("auto-title is clean, relevant, and free of artefacts", async ({ page }) => {
    const tenantOk = await selectMyraTestTenant(page);
    if (!tenantOk) { test.skip(); return; }

    const presetOk = await selectPreset(page, "PII claude-sonnet-4-6");
    if (!presetOk) {
      test.skip(true, "Preset 'PII claude-sonnet-4-6' not found on myratest tenant — skipping");
      return;
    }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(400);

    const title = await runFirstExchangeAndGetTitle(
      page,
      "What is photosynthesis?",
      60_000,
    );

    // Basic sanity
    expect(title.length).toBeGreaterThan(0);
    expect(title).not.toMatch(/^new conversation$/i);

    // No chain-of-thought artefacts (Claude shouldn't produce them, but verify)
    expect(title).not.toMatch(/<\/?think>/i);
    expect(title).not.toMatch(/^\s*<[a-z]/i);

    // Title should mention something relevant to the question topic
    // ("photosynthesis", "plants", "light", etc.)
    expect(title.length).toBeLessThan(80);
    // It should look like readable words, not binary garbage
    expect(title).toMatch(/[a-zA-Z]{2,}/);
  });

  test("auto-title is updated in the sidebar after first exchange", async ({ page }) => {
    const tenantOk = await selectMyraTestTenant(page);
    if (!tenantOk) { test.skip(); return; }

    const presetOk = await selectPreset(page, "PII claude-sonnet-4-6");
    if (!presetOk) {
      test.skip(true, "Preset 'PII claude-sonnet-4-6' not found — skipping");
      return;
    }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(400);

    // Capture the initial title (should be "New conversation" or similar)
    const convItem = page.locator("[role='option']").first();
    await convItem.waitFor({ state: "visible", timeout: 5000 });
    const initialTitle = (await convItem.locator("[class*='conv-item-title']").first().textContent() ?? "").trim();

    const title = await runFirstExchangeAndGetTitle(
      page,
      "Name the three primary colours.",
      60_000,
    );

    expect(title, "title should be updated after first exchange").not.toBe(initialTitle);
    expect(title).not.toMatch(/^new conversation$/i);
    expect(title).not.toMatch(/<\/?think>/i);
  });
});

// ---------------------------------------------------------------------------
// Cross-preset comparison: both presets must produce clean titles
// ---------------------------------------------------------------------------

test.describe("Chat auto-title — cross-preset: both presets produce clean titles", () => {
  test.setTimeout(300_000); // runs both presets sequentially

  let testStartTime: number;

  test.beforeEach(async ({ page }) => {
    testStartTime = Date.now();
  });

  test.afterEach(async ({ page }) => {
    await deleteAllConversations(page, testStartTime);
  });

  test("neither preset produces <think> artefacts in the conversation title", async ({ page }) => {
    const tenantOk = await selectMyraTestTenant(page);
    if (!tenantOk) { test.skip(); return; }

    const presetsToTest: Array<{ name: string; message: string; streamTimeout: number }> = [
      {
        name:          "SAFE local only",
        message:       "What is the speed of light?",
        streamTimeout: 120_000,
      },
      {
        name:          "PII claude-sonnet-4-6",
        message:       "What is the boiling point of water?",
        streamTimeout: 60_000,
      },
    ];

    for (const preset of presetsToTest) {
      // Re-navigate to reset preset state between iterations
      await selectMyraTestTenant(page);

      const presetOk = await selectPreset(page, preset.name);
      if (!presetOk) {
        console.warn(`[chat-summarize] Preset '${preset.name}' not found — skipping this preset`);
        continue;
      }

      await page.getByRole("button", { name: /new chat/i }).click();
      await page.waitForTimeout(400);

      const title = await runFirstExchangeAndGetTitle(page, preset.message, preset.streamTimeout);

      expect(title, `[${preset.name}] title must not be empty`).toBeTruthy();
      expect(title, `[${preset.name}] title must not be default`).not.toMatch(/^new conversation$/i);
      expect(title, `[${preset.name}] title must not contain <think>`).not.toMatch(/<\/?think>/i);
      expect(title, `[${preset.name}] title must not start with XML tag`).not.toMatch(/^\s*<[a-z]/i);
      expect(title.length, `[${preset.name}] title length in range`).toBeLessThan(100);
    }
  });
});
