/**
 * chat-autotitle.spec.ts — verifies that after the first exchange in a new
 * conversation the auto-title generation fires and replaces "New conversation"
 * with something meaningful.
 *
 * The test:
 *   1. Creates a new conversation via the sidebar button
 *   2. Sends a short, identifiable message
 *   3. Waits for the assistant response to finish streaming
 *   4. Intercepts the PATCH /conversations/:id that generateTitle fires
 *   5. Asserts the title in the sidebar is no longer the default "New conversation"
 */

import { test, expect } from "./base";
import { deleteConversations, captureConvId } from "./helpers";
import type {  Page  } from "./base";

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

interface TenantRow  { id: string; slug: string; plan: string }
interface GatewayRow { id: string; slug: string; config: unknown }
interface ModelPriceRow { provider: string; model: string }

/** Returns the myratest tenant id + first gateway id for inference tests.
 *
 * Pins to myratest by slug because that tenant has real API keys.
 * e2e-tenant-{i} gateways have config:'{}' (no keys) and cannot serve inference.
 */
async function getTenantAndGatewayForInference(page: Page): Promise<{ tenantId: string; gatewayId: string }> {
  const tr = await page.request.get(`${ADMIN_URL}/admin/v1/tenants`);
  expect(tr.ok(), "GET /tenants must succeed").toBeTruthy();
  const tenants = await tr.json() as TenantRow[];
  const myratest = tenants.find((t) => t.slug === "myratest");
  expect(myratest, "myratest tenant must exist for inference tests").not.toBeUndefined();

  const gr = await page.request.get(`${ADMIN_URL}/admin/v1/tenants/${myratest!.id}/gateways`);
  expect(gr.ok(), "GET myratest gateways must succeed").toBeTruthy();
  const gws = await gr.json() as GatewayRow[];
  expect(gws.length, "myratest must have at least one gateway").toBeGreaterThan(0);
  return { tenantId: myratest!.id, gatewayId: gws[0].id };
}

/** Returns a model string suitable for chat (prefers claude-sonnet-4-6, the well-supported model). */
async function getAModel(page: Page): Promise<string | null> {
  const r = await page.request.get(`${ADMIN_URL}/admin/v1/models`);
  if (!r.ok()) return null;
  const rows = await r.json() as ModelPriceRow[];
  // Prefer claude-sonnet-4-6 — it's available on all test gateways.
  // Older models (e.g. claude-3-5-haiku) may return 404 on some gateway configs.
  const sonnet = rows.find((m) => m.provider === "anthropic" && m.model === "claude-sonnet-4-6");
  if (sonnet) return `anthropic/${sonnet.model}`;
  const claude = rows.find((m) => m.provider === "anthropic" && m.model.startsWith("claude"));
  if (claude) return `anthropic/${claude.model}`;
  if (rows.length) return `${rows[0].provider}/${rows[0].model}`;
  return null;
}

/** Seeds localStorage so the chat page starts with a gateway + model pre-selected. */
async function setChatPreferences(page: Page, gatewayId: string, model: string, tenantId: string) {
  const currentUrl = page.url();
  if (currentUrl === "about:blank" || currentUrl === "") {
    await page.goto("/dashboard");
    await page.waitForLoadState("domcontentloaded");
  }
  await page.evaluate(({ g, m, t }) => {
    localStorage.setItem("aig-chat-gateway", g);
    localStorage.setItem("aig-chat-model", m);
    localStorage.setItem("aig-chat-tenant", t);
  }, { g: gatewayId, m: model, t: tenantId });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Chat — auto-title generation", () => {
  test.describe.configure({ mode: "serial" });
  let convIds: string[] = [];
  let tenantId: string;
  let gatewayId: string;
  let model: string;

  test.beforeAll(async ({ browser }) => {
    const ctx = await browser.newContext({ storageState: "tests/.auth/docker-session.json" });
    const page = await ctx.newPage();
    await page.goto("/dashboard");

    const tg = await getTenantAndGatewayForInference(page);
    tenantId  = tg.tenantId;
    gatewayId = tg.gatewayId;

    const m = await getAModel(page);
    expect(m, "at least one model must be configured").not.toBeNull();
    model = m!;

    await ctx.close();
  });

  test.beforeEach(async ({ page }) => {
    await setChatPreferences(page, gatewayId, model, tenantId);
    await page.goto("/chat");
    await expect(page.locator("[class*='chat-textarea'], [class*='config-bar']").first()).toBeVisible({ timeout: 10000 });
  });

  test.afterEach(async ({ page }) => {
    const id = captureConvId(page);
    if (id) convIds.push(id);
    await deleteConversations(page, convIds);
    convIds = [];
  });

  test("title updates from default after the first exchange", async ({ page }) => {
    // Click "+ New Chat" to pre-create the conversation (title = backend default)
    const newChatBtn = page.getByRole("button", { name: /new chat/i });
    await newChatBtn.waitFor({ state: "visible", timeout: 5000 });
    await newChatBtn.click();
    // Confirm the sidebar shows a conversation item
    const convItem = page.locator("[role='option']").first();
    await convItem.waitFor({ state: "visible", timeout: 5000 });

    // Read the initial default title
    const titleEl = convItem.locator("[class*='conv-item-title']").first();
    const initialTitle = (await titleEl.textContent() ?? "").trim();

    // Set up a listener for the PATCH /conversations/:id that generateTitle fires
    const titlePatchPromise = page.waitForRequest(
      (req) => req.method() === "PATCH" && /\/conversations\/[^/]+$/.test(req.url()),
      { timeout: 30_000 },
    );

    // Type a short, specific message that should produce a meaningful title
    const textarea = page.locator("[class*='chat-textarea']");
    await textarea.fill("What is photosynthesis?");
    await page.locator("button[title='Send message']").click();

    // Wait for the assistant bubble to appear (streaming started)
    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    await assistantBubble.waitFor({ state: "visible", timeout: 20_000 });

    // Wait for streaming to finish: the stop button disappears
    await page.waitForSelector("button[title='Stop generation']", { state: "hidden", timeout: 60_000 });

    // Wait for the PATCH request that renames the conversation
    await titlePatchPromise;

    // Wait for the sidebar title to change to something meaningful
    await expect(titleEl).not.toHaveText(/^new conversation$/i, { timeout: 10_000 });
    const updatedTitle = (await titleEl.textContent() ?? "").trim();
    expect(updatedTitle, "title should change after first exchange").not.toBe(initialTitle);
    expect(updatedTitle.length, "title should be non-empty").toBeGreaterThan(0);
  });

  test("title updates when conversation is created inline (no pre-created conversation)", async ({ page }) => {
    test.setTimeout(90_000); // LLM response + autotitle generation can take >30 s
    // Do NOT click "+ New Chat" — let sendMessage create the conversation inline
    const titlePatchPromise = page.waitForRequest(
      (req) => req.method() === "PATCH" && /\/conversations\/[^/]+$/.test(req.url()),
      { timeout: 60_000 },
    );

    const textarea = page.locator("[class*='chat-textarea']");
    await textarea.fill("Explain what a black hole is");
    await page.locator("button[title='Send message']").click();

    // Wait for streaming to complete
    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    await assistantBubble.waitFor({ state: "visible", timeout: 20_000 });
    await page.waitForSelector("button[title='Stop generation']", { state: "hidden", timeout: 60_000 });

    // Wait for rename PATCH
    await titlePatchPromise;

    // Verify a sidebar item exists with a non-default title
    const convItem = page.locator("[role='option']").first();
    await convItem.waitFor({ state: "visible", timeout: 5000 });
    const titleEl2 = convItem.locator("[class*='conv-item-title']").first();
    await expect(titleEl2).not.toHaveText(/^new conversation$/i, { timeout: 10_000 });
    const title = (await titleEl2.textContent() ?? "").trim();

    expect(title.toLowerCase()).not.toMatch(/^new conversation$/i);
    expect(title.length).toBeGreaterThan(0);
  });

  test("button-created conversation gets fallback title immediately on first message send (Bug fix)", async ({ page }) => {
    // Click "+ New Chat" — conversation created with "New conversation" default title
    const newChatBtn = page.getByRole("button", { name: /new chat/i });
    await expect(newChatBtn).toBeVisible({ timeout: 8000 });
    await newChatBtn.click();

    // Wait for a conversation item to appear in sidebar
    await expect(page.locator("[role='option']").first()).toBeVisible({ timeout: 8000 });

    // Listen for the immediate PATCH fired by renameConversation(convId, text.slice(0, 60))
    // This fires synchronously at the start of handleSend before streaming begins.
    const immediateRenamePromise = page.waitForRequest(
      (req) => req.method() === "PATCH" && /\/conversations\/[^/]+$/.test(req.url()),
      { timeout: 15_000 },
    );

    const message = "Explain what a black hole is in simple terms";
    const textarea = page.locator("[class*='chat-textarea']");
    await expect(textarea).toBeVisible({ timeout: 8000 });
    await textarea.fill(message);
    await page.locator("button[title='Send message']").click();

    // The immediate rename PATCH should arrive before or shortly after streaming starts
    const renameReq = await immediateRenamePromise;
    const body = renameReq.postDataJSON() as Record<string, unknown>;
    expect(typeof body.title === "string" && body.title.length > 0, "immediate rename must carry a non-empty title").toBeTruthy();
    expect((body.title as string).toLowerCase(), "immediate title must not be the generic default").not.toMatch(/^new conversation$/i);
    // Title must be a prefix of the message text (up to 60 chars)
    expect(message.startsWith(body.title as string) || (body.title as string).length === 60,
      "immediate title must be a prefix of the message").toBeTruthy();
  });

  test("generateTitle is called even when streaming fails (Bug fix)", async ({ page }) => {
    // Intercept the main gateway SSE call so streaming immediately fails
    await page.route(
      (url) => url.pathname.includes("/compat/chat/completions"),
      async (route, request) => {
        const body = request.postDataJSON?.() as Record<string, unknown> | null;
        // Only block the main streaming call (stream: true), let title call through
        if (body?.stream === true) {
          await route.fulfill({ status: 500, body: JSON.stringify({ error: "simulated gateway failure" }) });
        } else {
          await route.continue();
        }
      },
    );

    await page.getByRole("button", { name: /new chat/i }).click();
    await expect(page.locator("[role='option']").first()).toBeVisible({ timeout: 8000 });

    // Listen for any PATCH to /conversations/:id — either the immediate rename or generateTitle
    const patchPromise = page.waitForRequest(
      (req) => req.method() === "PATCH" && /\/conversations\/[^/]+$/.test(req.url()),
      { timeout: 15_000 },
    );

    const textarea = page.locator("[class*='chat-textarea']");
    await expect(textarea).toBeVisible({ timeout: 8000 });
    await textarea.fill("What is relativity?");
    await page.locator("button[title='Send message']").click();

    // Even with a 500 from the gateway, the immediate renameConversation fires
    const req = await patchPromise;
    const body = req.postDataJSON() as Record<string, unknown>;
    expect(typeof body.title === "string" && body.title.length > 0,
      "conversation must be renamed even when streaming fails").toBeTruthy();
    expect((body.title as string).toLowerCase()).not.toMatch(/^new conversation$/i);
  });

  test("generateTitle failure is visible in console (warn logged, not thrown)", async ({ page }) => {
    // Intercept the title generation compat request and return 500 to simulate failure
    await page.route(
      (url) => url.pathname.includes("/compat/chat/completions"),
      async (route, request) => {
        // Only block the title-generation call (max_tokens=500, stream=false, non-streaming)
        const body = request.postDataJSON?.() as Record<string, unknown> | null;
        if (body?.max_tokens === 500 && body?.stream === false) {
          console.warn("[test] intercepting title generation request → returning 500");
          await route.fulfill({ status: 500, body: JSON.stringify({ error: "simulated failure" }) });
        } else {
          await route.continue();
        }
      },
    );

    // Collect console warnings
    const warnings: string[] = [];
    page.on("console", (msg) => {
      if (msg.type() === "warning") warnings.push(msg.text());
    });

    await page.getByRole("button", { name: /new chat/i }).click();
    await expect(page.locator("[role='option']").first()).toBeVisible({ timeout: 8000 });

    const textarea = page.locator("[class*='chat-textarea']");
    await textarea.fill("Hello test");
    await page.locator("button[title='Send message']").click();

    // Wait for streaming to complete
    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    await assistantBubble.waitFor({ state: "visible", timeout: 20_000 });
    await page.waitForSelector("button[title='Stop generation']", { state: "hidden", timeout: 60_000 });

    // Poll until generateTitle logs the warning about the 500 response
    await expect.poll(
      () => warnings.find((w) => w.includes("[generateTitle]")),
      { timeout: 10_000, message: "generateTitle should console.warn on failure" },
    ).toBeTruthy();
  });
});
