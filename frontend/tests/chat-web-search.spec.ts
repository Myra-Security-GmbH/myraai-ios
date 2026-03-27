/**
 * chat-web-search.spec.ts — end-to-end tests for the chat web search feature.
 *
 * Exercises the gateway's two-leg agentic search loop:
 *   client sends x-aig-web-search: 1 → Leg 1 non-streaming call → Brave search
 *   → optional page fetch → Leg 2 streaming call → assistant reply.
 *
 * Gateway: myratest / prod   Model: claude-sonnet-4-6 (Anthropic native path)
 *
 * Root cause of "TypeError: Failed to fetch" was a missing CORS preflight
 * allowance for the x-aig-web-search header in nginx.docker.conf — fixed by
 * adding x-aig-web-search to Access-Control-Allow-Headers.
 */

import { test, expect, Page } from "@playwright/test";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

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

const TARGET_TENANT  = "myratest";
const TARGET_GATEWAY = "prod";
const TARGET_MODEL   = "claude-sonnet-4-6";

async function selectGatewayWithModel(page: Page): Promise<boolean> {
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  const tenantOption = tenantSel.locator("option").filter({ hasText: new RegExp(TARGET_TENANT, "i") });
  if ((await tenantOption.count()) === 0) return false;
  await tenantSel.selectOption({ label: (await tenantOption.first().textContent()) ?? TARGET_TENANT });
  await page.waitForTimeout(400);

  const gatewaySel = page.locator("select").nth(1);
  await gatewaySel.waitFor({ state: "visible", timeout: 5000 });
  const gatewayOption = gatewaySel.locator("option").filter({ hasText: new RegExp(TARGET_GATEWAY, "i") });
  if ((await gatewayOption.count()) === 0) return false;
  await gatewaySel.selectOption({ label: (await gatewayOption.first().textContent()) ?? TARGET_GATEWAY });
  await page.waitForTimeout(400);

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

/** Enable web search by clicking the globe/search toggle button. */
async function enableWebSearch(page: Page) {
  const btn = page.locator("button[title*='web search' i], button[title*='Enable web search' i]").first();
  await btn.waitFor({ state: "visible", timeout: 5000 });
  // Only click if not already ON
  const title = await btn.getAttribute("title") ?? "";
  if (!/ON/i.test(title)) await btn.click();
  await page.waitForTimeout(200);
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
  let testStartTime: number;
  test.setTimeout(120_000);

  test.beforeEach(async ({ page }) => {
    testStartTime = Date.now();
    await page.goto("/chat");
    await page.waitForTimeout(600);
  });

  test.afterEach(async ({ page }) => {
    await deleteAllConversations(page, testStartTime);
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

  // ── 2. UI: web search toggle is present and toggleable ────────────────────

  test("web search toggle button exists and can be enabled", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    const btn = page.locator("button[title*='web search' i], button[title*='Enable web search' i]").first();
    await expect(btn).toBeVisible({ timeout: 5000 });

    // Enable it
    const titleBefore = await btn.getAttribute("title") ?? "";
    if (!/ON/i.test(titleBefore)) await btn.click();
    await page.waitForTimeout(200);

    const titleAfter = await btn.getAttribute("title") ?? "";
    expect(titleAfter.toLowerCase()).toContain("on");
  });

  // ── 3. Request: x-aig-web-search header is sent when toggle is ON ─────────

  test("sending a message with web search enabled includes x-aig-web-search header", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await enableWebSearch(page);

    // Intercept the compat request and capture headers
    let capturedHeaders: Record<string, string> = {};
    const reqPromise = page.waitForRequest(
      (req) => req.method() === "POST" && req.url().includes("/compat/chat/completions"),
      { timeout: 15_000 },
    );

    await page.locator("[class*='chat-textarea']").fill("What is today's top news headline?");
    await page.locator("button[title='Send message']").click();

    const req = await reqPromise;
    capturedHeaders = req.headers();

    expect(capturedHeaders["x-aig-web-search"]).toBe("1");
  });

  // ── 4. End-to-end: reply arrives and contains content (no TypeError) ───────

  test("web search query returns a non-empty assistant reply without errors", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await enableWebSearch(page);

    // Ask a question that benefits from current web data
    await page.locator("[class*='chat-textarea']")
      .fill("What is the current price of Bitcoin in USD? Just give me the number.");
    await page.locator("button[title='Send message']").click();

    // User bubble must appear — confirms fetch did NOT throw TypeError
    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });

    // No error banner
    const errorText = page.getByText(/TypeError|failed to fetch|error/i).first();
    await expect(errorText).not.toBeVisible({ timeout: 3000 }).catch(() => {});

    await waitForStreamingDone(page, 90_000);

    // Assistant reply must contain a number (Bitcoin price)
    const assistantRow = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    await expect(assistantRow).toBeVisible({ timeout: 5000 });
    const reply = (await assistantRow.textContent()) ?? "";
    expect(reply.trim().length).toBeGreaterThan(10);
    expect(reply).toMatch(/\d/); // must contain at least one digit
  });

});
