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

import { test, expect, Page } from "@playwright/test";

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

// ---------------------------------------------------------------------------
// Helpers (shared with chat.spec.ts)
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

async function selectFirstGateway(page: Page): Promise<boolean> {
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  if (await tenantSel.locator("option").count() <= 1) return false;
  await tenantSel.selectOption({ index: 1 });
  await page.waitForTimeout(400);

  const gatewaySel = page.locator("select").nth(1);
  await gatewaySel.waitFor({ state: "visible", timeout: 5000 });
  if (await gatewaySel.locator("option").count() <= 1) return false;
  await gatewaySel.selectOption({ index: 1 });
  await page.waitForTimeout(400);

  const modelPickerBtn = page.locator("[aria-haspopup='listbox']");
  await modelPickerBtn.waitFor({ state: "visible", timeout: 5000 });
  await modelPickerBtn.click();
  const firstOption = page.locator("[role='listbox'] [role='option']").first();
  const hasOptions = await firstOption.isVisible({ timeout: 3000 }).catch(() => false);
  if (!hasOptions) { await page.keyboard.press("Escape"); return false; }
  await firstOption.click();
  await page.waitForTimeout(300);
  return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Chat — auto-title generation", () => {
  let testStartTime: number;
  test.beforeEach(async ({ page }) => {
    testStartTime = Date.now();
    await page.goto("/chat");
    await page.waitForTimeout(600);
  });

  test.afterEach(async ({ page }) => {
    await deleteAllConversations(page, testStartTime);
  });

  test("title updates from default after the first exchange", async ({ page }) => {
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    // Click "+ New Chat" to pre-create the conversation (title = backend default)
    const newChatBtn = page.getByRole("button", { name: /new chat/i });
    await newChatBtn.waitFor({ state: "visible", timeout: 5000 });
    await newChatBtn.click();
    await page.waitForTimeout(400);

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
    const assistantBubble = page.locator("[class*='assistant-row']").first();
    await assistantBubble.waitFor({ state: "visible", timeout: 20_000 });

    // Wait for streaming to finish: the stop button disappears
    await page.waitForSelector("button[title='Stop generating']", { state: "hidden", timeout: 60_000 });
    await page.waitForTimeout(500);

    // Wait for the PATCH request that renames the conversation
    await titlePatchPromise;

    // Allow state update + re-render
    await page.waitForTimeout(800);

    // Title in the sidebar should have changed to something meaningful
    const updatedTitle = (await titleEl.textContent() ?? "").trim();
    expect(updatedTitle, "title should change after first exchange").not.toBe(initialTitle);
    expect(updatedTitle.length, "title should be non-empty").toBeGreaterThan(0);
    expect(updatedTitle.toLowerCase(), "title should not be the generic default").not.toMatch(/^new conversation$/i);
  });

  test("title updates when conversation is created inline (no pre-created conversation)", async ({ page }) => {
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    // Do NOT click "+ New Chat" — let sendMessage create the conversation inline
    const titlePatchPromise = page.waitForRequest(
      (req) => req.method() === "PATCH" && /\/conversations\/[^/]+$/.test(req.url()),
      { timeout: 30_000 },
    );

    const textarea = page.locator("[class*='chat-textarea']");
    await textarea.fill("Explain what a black hole is");
    await page.locator("button[title='Send message']").click();

    // Wait for streaming to complete
    const assistantBubble = page.locator("[class*='assistant-row']").first();
    await assistantBubble.waitFor({ state: "visible", timeout: 20_000 });
    await page.waitForSelector("button[title='Stop generating']", { state: "hidden", timeout: 60_000 });
    await page.waitForTimeout(500);

    // Wait for rename PATCH
    await titlePatchPromise;
    await page.waitForTimeout(800);

    // Verify a sidebar item exists with a non-default title
    const convItem = page.locator("[role='option']").first();
    await convItem.waitFor({ state: "visible", timeout: 5000 });
    const title = (await convItem.locator("[class*='conv-item-title']").first().textContent() ?? "").trim();

    expect(title.toLowerCase()).not.toMatch(/^new conversation$/i);
    expect(title.length).toBeGreaterThan(0);
  });

  test("generateTitle failure is visible in console (warn logged, not thrown)", async ({ page }) => {
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    // Intercept the title generation compat request and return 500 to simulate failure
    await page.route(
      (url) => url.pathname.includes("/compat/chat/completions"),
      async (route, request) => {
        // Only block the title-generation call (max_tokens=30, stream=false, non-streaming)
        const body = request.postDataJSON?.() as Record<string, unknown> | null;
        if (body?.max_tokens === 30 && body?.stream === false) {
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
    await page.waitForTimeout(400);

    const textarea = page.locator("[class*='chat-textarea']");
    await textarea.fill("Hello test");
    await page.locator("button[title='Send message']").click();

    // Wait for streaming to complete
    const assistantBubble = page.locator("[class*='assistant-row']").first();
    await assistantBubble.waitFor({ state: "visible", timeout: 20_000 });
    await page.waitForSelector("button[title='Stop generating']", { state: "hidden", timeout: 60_000 });

    // Allow time for the title request to be intercepted and the warn to fire
    await page.waitForTimeout(3000);

    // generateTitle should have logged a warning about the 500 response
    const titleWarn = warnings.find((w) => w.includes("[generateTitle]"));
    expect(titleWarn, "generateTitle should console.warn on failure").toBeTruthy();
  });
});
