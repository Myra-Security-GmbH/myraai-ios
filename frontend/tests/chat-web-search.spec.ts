/**
 * chat-web-search.spec.ts — end-to-end tests for the chat web search feature.
 *
 * Exercises the gateway's two-leg agentic search loop:
 *   client always sends x-aig-web-search: 1 → Leg 1 non-streaming call → Brave search
 *   → optional page fetch → Leg 2 streaming call → assistant reply.
 *
 * Web search is always enabled — there is no toggle button.
 *
 * Covers two provider paths:
 *   - Anthropic native path  (claude-sonnet-4-6 via "UNSAFE claude-sonnet-4-6" preset)
 *   - vLLM / OpenAI-compat   (qwen3.6-35b-a3b  via "SAFE local only" preset)
 */

import { test, expect } from "./base";
import type {  Page  } from "./base";
import { deleteConversations, captureConvId } from "./helpers";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

const TARGET_TENANT  = "myratest";
const TARGET_GATEWAY = "prod";
const TARGET_PRESET  = "UNSAFE claude-sonnet-4-6";
const VLLM_PRESET    = "SAFE local only";

async function selectGatewayWithModel(page: Page): Promise<boolean> {
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  await expect(tenantSel).toContainText(TARGET_TENANT, { timeout: 10_000 });
  await tenantSel.selectOption({ label: TARGET_TENANT });
  const presetBtn = page.locator("button").filter({ hasText: new RegExp(TARGET_PRESET.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), "i") });
  if (!(await presetBtn.isVisible({ timeout: 5000 }).catch(() => false))) return false;
  await presetBtn.click();
  await expect(page.locator("[class*='chat-textarea']")).toBeEnabled({ timeout: 5000 });
  return true;
}

/** Wait for streaming to finish: stop button disappears, send button reappears. */
async function waitForStreamingDone(page: Page, timeoutMs = 90_000) {
  await page.locator("button[title='Stop generating']")
    .waitFor({ state: "visible", timeout: 20_000 })
    .catch(() => {});
  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: timeoutMs });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Chat — web search with claude-sonnet-4-6", () => {
  let convIds: string[] = [];
  test.setTimeout(120_000);

  test.beforeEach(async ({ page }) => {
    await page.goto("/chat");
    await page.evaluate(() => { localStorage.clear(); sessionStorage.clear(); });
    await page.reload();
    await page.locator("select").first().waitFor({ state: "visible", timeout: 10_000 });
  });

  test.afterEach(async ({ page }) => {
    const id = captureConvId(page);
    if (id) convIds.push(id);
    await deleteConversations(page, convIds);
    convIds = [];
  });

  // ── 1. CORS: x-aig-web-search header is allowed by preflight ─────────────

  test("CORS preflight allows x-aig-web-search header", async ({ page }) => {
    const gatewayBase = "https://ai-api.myra.eu";
    const resp = await page.request.fetch(
      `${gatewayBase}/v1/${TARGET_TENANT}/${TARGET_GATEWAY}/compat/chat/completions`,
      {
        method: "OPTIONS",
        headers: {
          "Origin": "https://ai.myra.eu",
          "Access-Control-Request-Method": "POST",
          "Access-Control-Request-Headers": "content-type,authorization,x-aig-web-search",
        },
      },
    );
    expect(resp.status()).toBe(204);
    const allowedHeaders = resp.headers()["access-control-allow-headers"] ?? "";
    expect(allowedHeaders.toLowerCase()).toContain("x-aig-web-search");
  });

  // ── 2. Request: x-aig-web-search: 1 is always sent ───────────────────────

  test("every message includes x-aig-web-search: 1 header", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5000 });

    const reqPromise = page.waitForRequest(
      (req) => req.method() === "POST" && req.url().includes("/compat/chat/completions"),
      { timeout: 15_000 },
    );

    await page.locator("[class*='chat-textarea']").fill("What is today's top news headline?");
    await page.locator("button[title='Send message']").click();

    const req = await reqPromise;
    expect(req.headers()["x-aig-web-search"]).toBe("1");
  });

  // ── 3. End-to-end: reply arrives and contains content (no TypeError) ───────

  test("web search query returns a non-empty assistant reply without errors", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5000 });

    await page.locator("[class*='chat-textarea']")
      .fill("What is the current price of Bitcoin in USD? Just give me the number.");
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });

    await expect(page.getByText(/TypeError|failed to fetch|error/i).first())
      .not.toBeVisible({ timeout: 3000 }).catch(() => {});

    await waitForStreamingDone(page, 90_000);

    const assistantRow = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    await expect(assistantRow).toBeVisible({ timeout: 5000 });
    const reply = (await assistantRow.textContent()) ?? "";
    expect(reply.trim().length).toBeGreaterThan(10);
    expect(reply).toMatch(/\d/);
  });

});

// ---------------------------------------------------------------------------
// vLLM / OpenAI-compat path (qwen3.6-35b-a3b)
// Regression guard: vllm was missing from OPENAI_FORMAT_PROVIDERS in
// web_search.lua — the two-leg loop silently skipped for all vllm models.
// ---------------------------------------------------------------------------

test.describe("Chat — web search with qwen3.6-35b-a3b (vllm)", () => {
  let convIds: string[] = [];
  test.setTimeout(120_000);

  test.beforeEach(async ({ page }) => {
    await page.goto("/chat");
    await page.evaluate(() => { localStorage.clear(); sessionStorage.clear(); });
    await page.reload();
    await page.locator("select").first().waitFor({ state: "visible", timeout: 10_000 });
  });

  test.afterEach(async ({ page }) => {
    const id = captureConvId(page);
    if (id) convIds.push(id);
    await deleteConversations(page, convIds);
    convIds = [];
  });

  // ── 1. x-aig-web-search: 1 is sent for vllm models ──────────────────────

  test("vllm: every message includes x-aig-web-search: 1 header", async ({ page }) => {
    const tenantSel = page.locator("select").first();
    await expect(tenantSel).toContainText(TARGET_TENANT, { timeout: 10_000 });
    await tenantSel.selectOption({ label: TARGET_TENANT });
    const presetBtn = page.locator("button").filter({ hasText: new RegExp(VLLM_PRESET.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), "i") });
    if (!(await presetBtn.isVisible({ timeout: 5000 }).catch(() => false))) {
      throw new Error(`Preset "${VLLM_PRESET}" not found — vllm not configured for this environment`);
    }
    await presetBtn.click();
    await expect(page.locator("[class*='chat-textarea']")).toBeEnabled({ timeout: 5000 });

    const reqPromise = page.waitForRequest(
      (req) => req.method() === "POST" && req.url().includes("/compat/chat/completions"),
      { timeout: 15_000 },
    );

    await page.locator("[class*='chat-textarea']").fill("What is today's date?");
    await page.locator("button[title='Send message']").click();

    const req = await reqPromise;
    expect(req.headers()["x-aig-web-search"]).toBe("1");
  });

  // ── 2. Two-leg loop runs end-to-end via vllm ─────────────────────────────

  test("vllm: web search query returns a non-empty assistant reply without errors", async ({ page }) => {
    const tenantSel = page.locator("select").first();
    await expect(tenantSel).toContainText(TARGET_TENANT, { timeout: 10_000 });
    await tenantSel.selectOption({ label: TARGET_TENANT });
    const presetBtn = page.locator("button").filter({ hasText: new RegExp(VLLM_PRESET.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), "i") });
    if (!(await presetBtn.isVisible({ timeout: 5000 }).catch(() => false))) {
      throw new Error(`Preset "${VLLM_PRESET}" not found — vllm not configured for this environment`);
    }
    await presetBtn.click();
    await expect(page.locator("[class*='chat-textarea']")).toBeEnabled({ timeout: 5000 });

    await page.locator("[class*='chat-textarea']")
      .fill("What is the current price of Bitcoin in USD? Just give me the number.");
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });

    await expect(page.getByText(/TypeError|failed to fetch|error/i).first())
      .not.toBeVisible({ timeout: 3000 }).catch(() => {});

    await page.locator("button[title='Stop generating']")
      .waitFor({ state: "visible", timeout: 20_000 })
      .catch(() => {});
    await page.locator("button[title='Send message']")
      .waitFor({ state: "visible", timeout: 90_000 });

    const assistantRow = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    await expect(assistantRow).toBeVisible({ timeout: 5000 });
    const reply = (await assistantRow.textContent()) ?? "";
    expect(reply.trim().length).toBeGreaterThan(10);
    expect(reply).toMatch(/\d/);

    await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
    await expect(page.getByText(/error/i).first()).not.toBeVisible();
  });

});
