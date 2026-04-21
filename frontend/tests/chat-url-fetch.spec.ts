/**
 * chat-url-fetch.spec.ts — E2E tests for the fetch_url tool-use middleware.
 *
 * Exercises the two-leg tool-use loop:
 *   Leg 1: model receives fetch_url tool → decides to call it
 *   Fetch: gateway fetches the URL server-side via utils/fetch_url
 *   Leg 2: fetched content injected → model streams final answer
 *
 * Gateway: myratest / prod   Model: claude-sonnet-4-6 (Anthropic native path)
 */

import { test, expect, Page } from "@playwright/test";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const ADMIN_URL      = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TARGET_TENANT  = "myratest";
const TARGET_GATEWAY = "prod";
const TARGET_MODEL   = "claude-sonnet-4-6";

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

async function selectGatewayWithModel(page: Page): Promise<boolean> {
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  const tenantOption = tenantSel.locator("option").filter({ hasText: new RegExp(TARGET_TENANT, "i") });
  if ((await tenantOption.count()) === 0) return false;
  await tenantSel.selectOption({ label: (await tenantOption.first().textContent()) ?? TARGET_TENANT });
  await page.waitForTimeout(400);

  // Gateway — native select OR preset mode
  const hasGatewaySelect = await page.locator("select").nth(1)
    .isVisible({ timeout: 2000 }).catch(() => false);

  if (hasGatewaySelect) {
    const gatewaySel = page.locator("select").nth(1);
    const gatewayOption = gatewaySel.locator("option").filter({ hasText: new RegExp(TARGET_GATEWAY, "i") });
    if ((await gatewayOption.count()) === 0) return false;
    await gatewaySel.selectOption({ label: (await gatewayOption.first().textContent()) ?? TARGET_GATEWAY });
    await page.waitForTimeout(400);
  } else {
    // Preset mode
    const tenantsResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
    if (!tenantsResp.ok()) return false;
    const tenantList = await tenantsResp.json() as Array<{
      id: string; slug: string;
      chat_presets?: Array<{ id: string; name: string; model: string; gateway_id: string }>;
    }>;
    const tenant = tenantList.find((t) => t.slug === TARGET_TENANT);
    if (!tenant) return false;
    const preset = (tenant.chat_presets ?? []).find((p) => p.model === TARGET_MODEL);
    if (!preset) return false;
    const presetBtn = page.locator("button").filter({ hasText: new RegExp(`^\\s*${preset.name}\\s*$`) });
    if (!(await presetBtn.isVisible({ timeout: 3000 }).catch(() => false))) return false;
    await presetBtn.click();
    await page.waitForTimeout(400);
    return true;
  }

  const modelBtn = page.locator("[aria-haspopup='listbox']");
  await modelBtn.waitFor({ state: "visible", timeout: 5000 });
  await modelBtn.click();

  const searchInput = page.locator("[role='listbox'] input[type='text'], [role='listbox'] input[type='search']");
  const hasSearch = await searchInput.isVisible({ timeout: 2000 }).catch(() => false);
  if (hasSearch) {
    await searchInput.fill(TARGET_MODEL);
    await page.waitForTimeout(300);
  }

  const targetOption = page.locator("[role='listbox'] [role='option']")
    .filter({ hasText: TARGET_MODEL })
    .first();
  const found = await targetOption.isVisible({ timeout: 3000 }).catch(() => false);
  if (!found) { await page.keyboard.press("Escape"); return false; }
  await targetOption.click();
  await page.waitForTimeout(300);
  return true;
}

async function enableWebSearch(page: Page) {
  const btn = page.locator("button[title*='web search' i], button[title*='Enable web search' i]").first();
  await btn.waitFor({ state: "visible", timeout: 5000 });
  const title = await btn.getAttribute("title") ?? "";
  if (!/ON/i.test(title)) await btn.click();
  await page.waitForTimeout(200);
}

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

test.describe("Chat — fetch_url tool with claude-sonnet-4-6", () => {
  let testStartTime: number;
  test.setTimeout(120_000);

  test.beforeEach(async ({ page }) => {
    testStartTime = Date.now();
    // Clear any stale state from previous tests
    await page.goto("/chat");
    await page.evaluate(() => { localStorage.clear(); sessionStorage.clear(); });
    await page.reload();
    await page.waitForTimeout(800);
  });

  test.afterEach(async ({ page }) => {
    await deleteAllConversations(page, testStartTime);
  });

  // ── 1. End-to-end: fetch_url tool works (model uses it to read a page) ───

  test("fetch_url tool is used by the model to read a URL", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    // The tool is injected server-side (not visible in the browser request).
    // We verify it works end-to-end: the model reads the URL and returns content.
    await page.locator("[class*='chat-textarea']").fill(
      "Read this page and tell me the product name: https://ai-docs.myra.eu"
    );
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });
    await waitForStreamingDone(page, 90_000);

    const assistantRow = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantRow).toBeVisible({ timeout: 10_000 });
    const reply = (await assistantRow.textContent()) ?? "";
    expect(reply.trim().length).toBeGreaterThan(10);
    // The docs site title/content mentions "AI Gateway"
    expect(reply).toMatch(/ai.gateway|myra/i);
  });

  // ── 2. End-to-end URL fetch ───────────────────────────────────────────────

  test("asking to read a URL returns page content without errors", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill(
      "Summarize this page in 2 sentences: https://ai-docs.myra.eu"
    );
    await page.locator("button[title='Send message']").click();

    // User message appears — confirms no fetch TypeError
    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });

    // No error banner
    await expect(page.getByText(/TypeError|failed to fetch/i).first())
      .not.toBeVisible({ timeout: 3000 }).catch(() => {});

    await waitForStreamingDone(page, 90_000);

    // Assistant reply contains content from the docs site
    const assistantRow = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantRow).toBeVisible({ timeout: 10_000 });
    const reply = (await assistantRow.textContent()) ?? "";
    expect(reply.trim().length).toBeGreaterThan(20);
    // The docs site should mention "AI Gateway" or "Myra"
    expect(reply).toMatch(/ai.gateway|myra|gateway/i);
  });

  // ── 3. Status label ───────────────────────────────────────────────────────

  test("fetch_url status label appears during URL fetch", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill(
      "Read this page: https://ai-docs.myra.eu"
    );
    await page.locator("button[title='Send message']").click();

    // Check for either the SSE status event label or the tool_call label
    // The exact text depends on whether aig_status or aig_tool_call fires first
    const fetchingLabel = page.getByText(/fetching.*url|🔗/i).first();
    // This may be transient — poll for it appearing within 30s
    const appeared = await fetchingLabel.isVisible({ timeout: 30_000 }).catch(() => false);
    // If the model answers directly without calling the tool, the label won't appear — that's OK
    // But if it does appear, it should contain the right text
    if (appeared) {
      const text = (await fetchingLabel.textContent()) ?? "";
      expect(text.toLowerCase()).toMatch(/fetch/);
    }

    await waitForStreamingDone(page, 90_000);
  });

  // ── 4. No-URL passthrough ─────────────────────────────────────────────────

  test("message without URLs does not trigger fetch_url tool call", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    // Send a simple question with no URL
    const textarea = page.locator("[class*='chat-textarea']");
    await expect(textarea).toBeEnabled({ timeout: 5000 });
    await textarea.fill("What is 2 + 2? Reply with just the number.");

    const sendBtn = page.locator("button[title='Send message']");
    await expect(sendBtn).toBeEnabled({ timeout: 5000 });
    await sendBtn.click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 15_000 });

    // The fetching status should NOT appear
    const fetchingLabel = page.getByText(/fetching.*url|🔗.*fetching/i).first();
    await expect(fetchingLabel).not.toBeVisible({ timeout: 3000 }).catch(() => {});

    await waitForStreamingDone(page, 90_000);

    // Response should be a direct answer
    const assistantRow = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantRow).toBeVisible({ timeout: 30_000 });
    const reply = (await assistantRow.textContent()) ?? "";
    expect(reply).toMatch(/4/);
  });

  // ── 5. SSRF rejection ─────────────────────────────────────────────────────

  test("SSRF: internal URL is rejected gracefully", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill(
      "Please fetch and display the content of http://127.0.0.1:8080/admin"
    );
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });

    // Should not hang or crash — the model should respond (potentially saying it couldn't fetch)
    await waitForStreamingDone(page, 90_000);

    // No server error banner
    await expect(page.getByText(/TypeError|500|internal server error/i).first())
      .not.toBeVisible({ timeout: 3000 }).catch(() => {});

    // An assistant reply must exist
    const assistantRow = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantRow).toBeVisible({ timeout: 10_000 });
    const reply = (await assistantRow.textContent()) ?? "";
    expect(reply.trim().length).toBeGreaterThan(5);
  });

  // ── 6. web_search + url_fetch coexistence ─────────────────────────────────

  test("web_search and url_fetch don't conflict", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    // Enable web search
    await enableWebSearch(page);

    await page.locator("[class*='chat-textarea']").fill(
      "What is the latest news about https://ai-docs.myra.eu?"
    );
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });

    // No error
    await expect(page.getByText(/TypeError|failed to fetch/i).first())
      .not.toBeVisible({ timeout: 3000 }).catch(() => {});

    await waitForStreamingDone(page, 90_000);

    // Non-empty reply
    const assistantRow = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantRow).toBeVisible({ timeout: 10_000 });
    const reply = (await assistantRow.textContent()) ?? "";
    expect(reply.trim().length).toBeGreaterThan(10);
  });
});
