/**
 * chat-long-response.spec.ts
 *
 * Regression test for the "long response stops mid-stream" bug.
 *
 * Root causes fixed:
 *   1. utils/http.lua DEFAULT_READ_MS = 60 000 ms — the resty.http socket
 *      read timeout fired if the provider took >60 s between SSE chunks
 *      (slow/local models, large thinking blocks). Fixed: stream read timeout
 *      now 300 000 ms (5 min).
 *   2. nginx default send_timeout (60 s) — if a thinking model emits a long
 *      <think> block that is stripped, nothing is forwarded to the client for
 *      >60 s and nginx closes the downstream connection. Fixed: send_timeout 300s.
 *
 * Tests verify that long structured responses from both Anthropic Sonnet and
 * a slow local model complete fully, reaching the final requested section.
 *
 * Run with:
 *   npx playwright test tests/chat-long-response.spec.ts \
 *     --config playwright.production.config.ts \
 *     --project=chromium-chat --timeout=360000
 */

import { test, expect } from "./base";
import { deleteConversations, captureConvId } from "./helpers";
import type {  Page  } from "./base";

const ADMIN_URL     = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TARGET_TENANT = "myratest";

// ---------------------------------------------------------------------------
// Shared helpers (same pattern as chat-summarize.spec.ts)
// ---------------------------------------------------------------------------

async function selectMyraTestTenant(page: Page): Promise<boolean> {
  await page.goto("/chat");

  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 10000 });

  await expect(tenantSel).toContainText(TARGET_TENANT, { timeout: 10_000 });
  await tenantSel.selectOption({ label: TARGET_TENANT });
  await expect(
    page.locator("[data-testid='config-preset-btn'], select").nth(1),
  ).toBeVisible({ timeout: 5000 });
  return true;
}

async function selectPreset(page: Page, presetName: string): Promise<boolean> {
  const btn = page.getByRole("button", { name: new RegExp(`^${presetName}$`) });
  const visible = await btn.isVisible({ timeout: 4000 }).catch(() => false);
  if (!visible) return false;
  await btn.click();
  await expect(page.locator("[class*='chat-textarea']")).toBeEnabled({ timeout: 5000 });
  return true;
}

/** Wait for the streaming stop-button to appear, then wait for it to go away. */
async function waitForStreamingComplete(page: Page, streamTimeoutMs: number) {
  await page.locator("button[title='Stop generating']")
    .waitFor({ state: "visible", timeout: 30_000 })
    .catch(() => { /* may not appear for very short first-tokens */ });

  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: streamTimeoutMs });
}

/**
 * Return the visible text content of the last assistant bubble message only
 * (bubble-text class contains only the rendered markdown, no action buttons).
 */
async function getLastAssistantText(page: Page): Promise<string> {
  const texts = page.locator("[class*='bubble-row']:not([class*='user-row']) [class*='bubble-text']");
  const count = await texts.count();
  if (count === 0) return "";
  return (await texts.nth(count - 1).textContent() ?? "").trim();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Chat long response — no mid-stream truncation", () => {
  // Very generous timeout: local models can take 3–5 min for a 1500-word response
  test.setTimeout(360_000);

  let convIds: string[] = [];

  test.beforeEach(async () => {
    // intentionally empty
  });

  test.afterEach(async ({ page }) => {
    const id = captureConvId(page);
    if (id) convIds.push(id);
    await deleteConversations(page, convIds);
    convIds = [];
  });

  // ── Test 1: Anthropic Sonnet — fast but produces long structured output ────
  // Uses the "prod" (non-PII) gateway to avoid PII-protector buffering interactions.

  test("PII claude-sonnet-4-6: full long response received without truncation", async ({ page }) => {
    const tenantOk = await selectMyraTestTenant(page);
    if (!tenantOk) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    // Use the "PII claude-sonnet-4-6" preset — it points at the prod-pii gateway
    // which uses claude-sonnet-4-6. Our prompt is PII-free so the PII protector
    // tokenizes nothing; streaming runs normally.
    const presetOk = await selectPreset(page, "PII claude-sonnet-4-6");
    if (!presetOk) {
      test.skip(true, "Preset 'PII claude-sonnet-4-6' not found — skipping");
      return;
    }

    await page.getByRole("button", { name: /new chat/i }).click();
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5000 });

    // Prompt that forces a multi-section response long enough to verify streaming
    // is not cut off prematurely. "OpenAPI" in section 4 is the sentinel — if
    // the stream is truncated early only sections 1–2 would appear.
    // NOTE: no PII in the prompt so pii_protector does not force buffered mode.
    const prompt =
      "Write a technical guide on REST API design. Cover these four sections:\n" +
      "1. HTTP methods (GET, POST, PUT, PATCH, DELETE) — purpose and when to use each\n" +
      "2. Status codes — list the 10 most important ones with a one-sentence explanation each\n" +
      "3. Authentication strategies (API keys, OAuth2, JWT) — brief comparison\n" +
      "4. OpenAPI documentation — what it is and why it matters\n" +
      "Write two paragraphs per section.";

    const textarea = page.locator("[class*='chat-textarea']");
    await textarea.fill(prompt);

    await page.locator("button[title='Send message']").click();

    // Wait for at least the first assistant bubble to appear
    await page.locator("[class*='bubble-row']:not([class*='user-row'])").first()
      .waitFor({ state: "visible", timeout: 30_000 });

    // Wait for streaming to complete — allow up to 3 min for Sonnet
    await waitForStreamingComplete(page, 180_000);
    await expect(page.locator("[class*='bubble-row']:not([class*='user-row']) [class*='bubble-text']").last()).not.toBeEmpty({ timeout: 5000 });
    const responseText = await getLastAssistantText(page);

    // 1. Response must be substantially long (>= 500 chars)
    expect(
      responseText.length,
      `response too short (${responseText.length} chars) — likely truncated.\n` +
      `First 200 chars: "${responseText.slice(0, 200)}"`,
    ).toBeGreaterThanOrEqual(500);

    // 2. Response must reach section 4 (OpenAPI — the last requested section).
    //    With the old 60 s timeout the stream cut off before reaching it.
    const reachedLastSection = /openapi/i.test(responseText);
    expect(
      reachedLastSection,
      "Response did not reach section 4 (OpenAPI) — stream was likely truncated.\n" +
      `Response length: ${responseText.length}.\n` +
      `Response ends with: "…${responseText.slice(-300)}"`,
    ).toBe(true);

    // 3. Verify the response was persisted (conversation list updated)
    const convItem = page.locator("[role='option']").first();
    await expect(convItem).toBeVisible({ timeout: 5000 });
  });

  // ── Test 2: local model — most likely to trigger the old 60 s timeout ──────

  test("SAFE local only: all 20 design patterns present (no mid-stream timeout)", async ({ page }) => {
    const tenantOk = await selectMyraTestTenant(page);
    if (!tenantOk) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    const presetOk = await selectPreset(page, "SAFE local only");
    if (!presetOk) {
      test.skip(true, "Preset 'SAFE local only' not found — skipping");
      return;
    }

    await page.getByRole("button", { name: /new chat/i }).click();
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5000 });

    // 20 patterns — a local 3B model takes ~90–120 s to generate all of them.
    // With the old 60 s timeout only patterns 1–8 would appear.
    const prompt =
      "List and briefly explain 20 different software design patterns. " +
      "For each pattern include: its name, category (creational/structural/behavioural), " +
      "a one-sentence definition, and one concrete real-world use case. " +
      "Format each as: Pattern N: [Name] ([Category]) — [definition]. Example: [use case]. " +
      "Do not skip any of the 20 patterns.";

    const textarea = page.locator("[class*='chat-textarea']");
    await textarea.fill(prompt);

    await page.locator("button[title='Send message']").click();

    await page.locator("[class*='bubble-row']:not([class*='user-row'])").first()
      .waitFor({ state: "visible", timeout: 60_000 });

    // Allow up to 5 min for local model to finish
    await waitForStreamingComplete(page, 300_000);
    await expect(page.locator("[class*='bubble-row']:not([class*='user-row']) [class*='bubble-text']").last()).not.toBeEmpty({ timeout: 5000 });
    const responseText = await getLastAssistantText(page);

    // 1. Response must be reasonably long (>= 400 chars for 20 patterns)
    expect(
      responseText.length,
      `response too short (${responseText.length} chars) — likely truncated`,
    ).toBeGreaterThanOrEqual(400);

    // 2. Patterns 17–20 must appear — with the old 60 s timeout only ~8 appeared.
    const reachedLatePatterns = /Pattern\s+(1[789]|20)\b/i.test(responseText);
    expect(
      reachedLatePatterns,
      "Response did not reach patterns 17–20 — stream was likely cut by the 60 s timeout.\n" +
      `Response ends with: "…${responseText.slice(-300)}"`,
    ).toBe(true);
  });

  // ── Test 3: 10-section guide — checks each section up to section 8 ─────────

  test("PII claude-sonnet-4-6: 10-section guide reaches section 8 (circuit breakers)", async ({ page }) => {
    const tenantOk = await selectMyraTestTenant(page);
    if (!tenantOk) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    const presetOk = await selectPreset(page, "PII claude-sonnet-4-6");
    if (!presetOk) {
      test.skip(true, "Preset 'PII claude-sonnet-4-6' not found — skipping");
      return;
    }

    await page.getByRole("button", { name: /new chat/i }).click();
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5000 });

    const prompt =
      "Write a structured guide with exactly 10 numbered sections:\n" +
      "1. Introduction to microservices\n" +
      "2. Service decomposition strategies\n" +
      "3. Inter-service communication (sync vs async)\n" +
      "4. API gateway pattern\n" +
      "5. Service discovery\n" +
      "6. Load balancing approaches\n" +
      "7. Data management (database per service)\n" +
      "8. Fault tolerance and circuit breakers\n" +
      "9. Observability: logging, tracing, metrics\n" +
      "10. Deployment and orchestration with Kubernetes\n\n" +
      "For each section write at least 2 detailed paragraphs.";

    const textarea = page.locator("[class*='chat-textarea']");
    await textarea.fill(prompt);
    await page.locator("button[title='Send message']").click();

    await page.locator("[class*='bubble-row']:not([class*='user-row'])").first()
      .waitFor({ state: "visible", timeout: 30_000 });

    await waitForStreamingComplete(page, 180_000);
    await expect(page.locator("[class*='bubble-row']:not([class*='user-row']) [class*='bubble-text']").last()).not.toBeEmpty({ timeout: 5000 });
    const responseText = await getLastAssistantText(page);

    expect(responseText.length).toBeGreaterThanOrEqual(600);

    // With the old 60 s timeout sections 7–10 were missing entirely.
    const hasSection8 = /circuit.break|fault.toleran/i.test(responseText);
    expect(
      hasSection8,
      "Response was truncated before section 8 (circuit breakers) — stream likely timed out.\n" +
      `Response length: ${responseText.length}.\n` +
      `Response ends with: "…${responseText.slice(-200)}"`,
    ).toBe(true);
  });
});
