/**
 * chat-autotitle-presets.spec.ts — verifies that auto-title generation produces
 * a meaningful summary (not just the user's prompt) when using named presets.
 *
 * Tenant:  myratest
 * Presets: "SAFE local only", "PII claude-sonnet-4-6"
 * Prompt:  "tell me how qwen3-30b-a3b works compared to other qwen3 llm"
 *
 * Pass condition: after the first exchange the sidebar title must be non-empty
 * AND must not equal (or start with) the verbatim prompt text.
 */

import { test, expect } from "./base";
import { deleteConversations, captureConvId } from "./helpers";
import type {  Page  } from "./base";

const ADMIN_URL     = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TARGET_TENANT = "myratest";
const PROMPT        = "tell me how qwen3-30b-a3b works compared to other qwen3 llm";

const PRESETS = [
  "SAFE local only",
  "PII claude-sonnet-4-6",
] as const;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Select the myratest tenant and click the named preset button.
 * Returns false if the tenant or preset cannot be found (test should skip).
 */
async function selectPreset(page: Page, presetName: string): Promise<boolean> {
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });

  await expect(tenantSel).toContainText(TARGET_TENANT, { timeout: 10_000 });
  await tenantSel.selectOption({ label: TARGET_TENANT });
  await page.waitForTimeout(500);

  // The tenant has presets — expect a preset button to appear
  const presetBtn = page.getByRole("button", { name: presetName });
  const visible = await presetBtn.isVisible({ timeout: 5000 }).catch(() => false);
  if (!visible) return false;

  await presetBtn.click();
  await page.waitForTimeout(400);
  return true;
}

/** Wait for streaming to finish: stop button appears then the send button returns. */
async function waitForStreamingDone(page: Page, timeoutMs = 240_000) {
  await page.locator("button[title='Stop generating']")
    .waitFor({ state: "visible", timeout: 20_000 })
    .catch(() => {});
  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: timeoutMs });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

for (const presetName of PRESETS) {
  test.describe(`Auto-title via preset "${presetName}" (${TARGET_TENANT})`, () => {
    test.setTimeout(300_000);

    let convIds: string[] = [];

    test.beforeEach(async ({ page }) => {
      await page.goto("/chat");
      await page.waitForTimeout(600);
    });

    test.afterEach(async ({ page }) => {
      const id = captureConvId(page);
      if (id) convIds.push(id);
      await deleteConversations(page, convIds);
      convIds = [];
    });

    test(`title is meaningful — not the verbatim prompt`, async ({ page }) => {
      const ok = await selectPreset(page, presetName);
      if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

      // Start a fresh conversation so isFirstMessage = true
      const newChatBtn = page.getByRole("button", { name: /new chat/i });
      await newChatBtn.waitFor({ state: "visible", timeout: 5000 });
      await newChatBtn.click();
      await page.waitForTimeout(400);

      // Type the prompt and send
      const textarea = page.locator("[class*='chat-textarea']");
      await textarea.fill(PROMPT);
      await page.locator("button[title='Send message']").click();

      // Wait for the assistant to start and finish streaming
      await page.locator("[class*='bubble-row']:not([class*='user-row'])")
        .first()
        .waitFor({ state: "visible", timeout: 20_000 });
      await waitForStreamingDone(page);

      // After streaming, generateTitle fires async — poll until the sidebar title
      // is neither the generic default nor the verbatim prompt text
      const convItem = page.locator("[role='option']").first();
      await convItem.waitFor({ state: "visible", timeout: 5000 });
      const titleEl = convItem.locator("[class*='conv-item-title']").first();

      const promptPrefix = PROMPT.slice(0, 40).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      await expect(titleEl).not.toHaveText(
        new RegExp(`^(new conversation|${promptPrefix})`, "i"),
        { timeout: 120_000 },
      );

      const title = (await titleEl.textContent() ?? "").trim();

      // Must be non-empty
      expect(title.length, "title should be non-empty").toBeGreaterThan(0);

      // Must not be (or start with) the verbatim prompt
      expect(
        title.toLowerCase(),
        `title should be a summary, not the raw prompt — got: "${title}"`,
      ).not.toContain(PROMPT.toLowerCase().slice(0, 40));
    });
  });
}
