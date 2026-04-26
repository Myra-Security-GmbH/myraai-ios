/**
 * pii-feedback-indicator.spec.ts — AGF-16
 *
 * Verifies that when the gateway emits an `aig_status: "pii_masked"` SSE event,
 * the Chat UI shows a "PII masked" indicator chip on the assistant message.
 *
 * The inference response is intercepted via page.route() and an artificial
 * aig_status event is injected into the SSE stream to avoid needing a live
 * pii_protector sidecar in the test environment.
 */

import { test, expect } from "./base";
import type {  Page  } from "./base";
import { deleteConversations, captureConvId } from "./helpers";

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TARGET_TENANT = "myratest";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Navigate to /chat, select the myratest tenant, and select a preset.
 * Returns true if setup succeeded, false if a required element wasn't found.
 */
async function setupChat(page: Page, presetName: string): Promise<boolean> {
  await page.goto("/chat");
  await page.waitForTimeout(600);

  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  await expect(tenantSel).toContainText(TARGET_TENANT, { timeout: 10_000 });
  await tenantSel.selectOption({ label: TARGET_TENANT });
  await page.waitForTimeout(500);

  // Try to find and click the preset button
  const presetBtn = page.getByRole("button", { name: new RegExp(`^${presetName}$`) });
  const presetVisible = await presetBtn.isVisible({ timeout: 4000 }).catch(() => false);
  if (presetVisible) {
    await presetBtn.click();
    await page.waitForTimeout(300);
    return true;
  }

  // Fallback: select first available gateway from dropdown
  const gatewaySel = page.locator("select").nth(1);
  const gwVisible = await gatewaySel.isVisible({ timeout: 3000 }).catch(() => false);
  if (!gwVisible) return false;
  const gwOptions = await gatewaySel.locator("option").count();
  if (gwOptions < 2) return false;
  await gatewaySel.selectOption({ index: 1 });
  await page.waitForTimeout(300);
  return true;
}

// ---------------------------------------------------------------------------
// SSE fixture: build a synthetic SSE stream that includes a pii_masked event
// ---------------------------------------------------------------------------

function buildSseStream(piiTypes: string | null, customCount?: number | null): string {
  const chatId = "chatcmpl-test-pii";
  const model  = "test-model";

  const lines: string[] = [];

  lines.push(`data: ${JSON.stringify({
    id: chatId, object: "chat.completion.chunk", model,
    choices: [{ index: 0, delta: { role: "assistant", content: "" }, finish_reason: null }],
  })}\n\n`);
  lines.push(`data: ${JSON.stringify({
    id: chatId, object: "chat.completion.chunk", model,
    choices: [{ index: 0, delta: { content: "I can help with that." }, finish_reason: null }],
  })}\n\n`);
  lines.push(`data: ${JSON.stringify({
    id: chatId, object: "chat.completion.chunk", model,
    choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
  })}\n\n`);
  lines.push(`data: ${JSON.stringify({
    id: chatId, object: "chat.completion.chunk", model,
    usage: { prompt_tokens: 10, completion_tokens: 6, total_tokens: 16 },
  })}\n\n`);

  if (piiTypes || customCount) {
    lines.push(`data: ${JSON.stringify({
      aig_status:  "pii_masked",
      types:       piiTypes,
      custom_count: customCount ?? null,
    })}\n\n`);
  }

  lines.push("data: [DONE]\n\n");
  return lines.join("");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("AGF-16 — PII masked indicator chip", () => {
  let convIds: string[] = [];

  test.afterEach(async ({ page }) => {
    const id = captureConvId(page);
    if (id) convIds.push(id);
    await deleteConversations(page, convIds);
    convIds = [];
  });

  // ── V2: chip appears when pii_masked event fires ────────────────────────

  test("PII masked chip appears on assistant message after aig_status pii_masked event", async ({ page }) => {
    // Intercept compat inference before navigation
    await page.route("**/compat/chat/completions", (route) => {
      route.fulfill({
        status: 200,
        headers: {
          "Content-Type":      "text/event-stream",
          "Cache-Control":     "no-cache",
          "X-AIG-Provider":    "vllm",
          "X-AIG-Cache":       "MISS",
        },
        body: buildSseStream("PERSON,EMAIL_ADDRESS"),
      });
    });

    const ok = await setupChat(page, "SAFE local only");
    if (!ok) {
      test.fail(true, "Could not select a gateway — check test environment setup");
      return;
    }

    // Start a new conversation
    const newChatBtn = page.getByRole("button", { name: /new chat/i });
    if (await newChatBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
      await newChatBtn.click();
      await page.waitForTimeout(300);
    }

    const textarea = page.locator("[class*='chat-textarea']");
    await expect(textarea).toBeEnabled({ timeout: 10000 });

    await textarea.fill("My email is john@example.com and I am John Smith");
    await textarea.press("Enter");

    // Wait for the PII chip to appear on the assistant message
    await expect(page.locator("[data-cy='pii-masked-chip']")).toBeVisible({ timeout: 20000 });

    // Chip should mention entity types
    const chipText = await page.locator("[data-cy='pii-masked-chip']").innerText();
    expect(chipText).toContain("person name");
    expect(chipText).toContain("email address");

    // No error banner
    await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
  });

  // ── V3: chip is dismissed on close click ─────────────────────────────────

  test("PII masked chip is dismissed when close button is clicked", async ({ page }) => {
    await page.route("**/compat/chat/completions", (route) => {
      route.fulfill({
        status: 200,
        headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" },
        body: buildSseStream("PHONE_NUMBER"),
      });
    });

    const ok = await setupChat(page, "SAFE local only");
    if (!ok) {
      test.fail(true, "Could not select a gateway — check test environment setup");
      return;
    }

    const newChatBtn = page.getByRole("button", { name: /new chat/i });
    if (await newChatBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
      await newChatBtn.click();
      await page.waitForTimeout(300);
    }

    const textarea = page.locator("[class*='chat-textarea']");
    await expect(textarea).toBeEnabled({ timeout: 10000 });

    await textarea.fill("My phone is 555-1234");
    await textarea.press("Enter");

    const chip = page.locator("[data-cy='pii-masked-chip']");
    await expect(chip).toBeVisible({ timeout: 20000 });

    // Dismiss
    await chip.locator("button").click();
    await expect(chip).not.toBeVisible({ timeout: 3000 });

    // No error banner
    await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
  });

  // ── V4: no chip when no pii_masked event ─────────────────────────────────

  test("PII masked chip is NOT shown when no pii_masked event is emitted", async ({ page }) => {
    await page.route("**/compat/chat/completions", (route) => {
      route.fulfill({
        status: 200,
        headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" },
        body: buildSseStream(null, null),
      });
    });

    const ok = await setupChat(page, "SAFE local only");
    if (!ok) {
      test.fail(true, "Could not select a gateway — check test environment setup");
      return;
    }

    const newChatBtn = page.getByRole("button", { name: /new chat/i });
    if (await newChatBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
      await newChatBtn.click();
      await page.waitForTimeout(300);
    }

    const textarea = page.locator("[class*='chat-textarea']");
    await expect(textarea).toBeEnabled({ timeout: 10000 });

    await textarea.fill("Hello, no PII here!");
    await textarea.press("Enter");

    // Wait for the response to land (content from our stub)
    await expect(page.getByText("I can help with that.")).toBeVisible({ timeout: 20000 });

    // No PII chip
    await expect(page.locator("[data-cy='pii-masked-chip']")).not.toBeVisible();

    // No error banner
    await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
  });
});
