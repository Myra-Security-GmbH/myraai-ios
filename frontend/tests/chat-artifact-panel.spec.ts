/**
 * chat-artifact-panel.spec.ts — E2E tests for:
 *   • Model badge per assistant message (Feature 2)
 *   • Reason-annotated regeneration dropdown (Feature 3)
 *   • Multi-artifact panel: multiple tabs + version navigation (Feature 4)
 *
 * All inference calls are intercepted with fake SSE — no real model keys needed.
 * Gateway: myratest / UNSAFE claude-sonnet-4-6
 */

import { test, expect, type Page } from "./base";
import { deleteConversations, captureConvId } from "./helpers";

const ADMIN_URL    = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TARGET_TENANT = "myratest";
const TARGET_PRESET = "UNSAFE claude-sonnet-4-6";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function goToChatFresh(page: Page) {
  await page.goto("/chat");
  await page.evaluate(() => { localStorage.clear(); sessionStorage.clear(); });
  await page.reload();
  // Wait for the tenant options to be populated (not just the select to be visible)
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 10_000 });
  await expect(tenantSel).toContainText(TARGET_TENANT, { timeout: 10_000 });
}

async function selectPreset(page: Page): Promise<boolean> {
  const sel = page.locator("select").first();
  await sel.waitFor({ state: "visible", timeout: 5_000 });
  await expect(sel).toContainText(TARGET_TENANT, { timeout: 10_000 });
  await sel.selectOption({ label: TARGET_TENANT });
  const esc = TARGET_PRESET.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const btn = page.locator("button").filter({ hasText: new RegExp(esc, "i") });
  if (!(await btn.isVisible({ timeout: 5_000 }).catch(() => false))) return false;
  await btn.click();
  await expect(page.locator("[class*='chat-textarea']")).toBeEnabled({ timeout: 5_000 });
  return true;
}

async function waitForStreamDone(page: Page, timeoutMs = 30_000) {
  await page.locator("button[title='Send message']").waitFor({ state: "visible", timeout: timeoutMs });
}

/** Intercept next compat inference call with fake SSE. */
async function interceptWithContent(page: Page, content: string) {
  await page.route(
    (url) => url.href.includes("/compat/chat/completions"),
    async (route) => {
      const chunks = [
        JSON.stringify({ id: "t", object: "chat.completion.chunk", model: "claude-sonnet-4-6", choices: [{ index: 0, delta: { role: "assistant", content: "" }, finish_reason: null }] }),
        JSON.stringify({ id: "t", object: "chat.completion.chunk", model: "claude-sonnet-4-6", choices: [{ index: 0, delta: { content }, finish_reason: null }] }),
        JSON.stringify({ id: "t", object: "chat.completion.chunk", model: "claude-sonnet-4-6", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] }),
        JSON.stringify({ id: "t", object: "chat.completion.chunk", model: "claude-sonnet-4-6", usage: { prompt_tokens: 10, completion_tokens: 20, total_tokens: 30 } }),
      ];
      await route.fulfill({
        status: 200,
        headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" },
        body: chunks.map(c => `data: ${c}`).join("\n\n") + "\n\ndata: [DONE]\n\n",
      });
    }
  );
}

async function sendMessage(page: Page, text: string) {
  await page.getByRole("button", { name: /new.*chat/i }).click();
  await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5_000 });
  await page.locator("[class*='chat-textarea']").fill(text);
  // Wait for conversation creation to complete (creating=false) so sendMessage doesn't block
  await expect(page.locator("button[title='Send message']")).toBeEnabled({ timeout: 10_000 });
  // Press Enter — more reliable than clicking the button which can race with disabled state
  await page.locator("[class*='chat-textarea']").press("Enter");
  await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });
}

// HTML artifact block that triggers an ArtifactCard
function htmlArtifact(filename: string, content: string): string {
  return (
    "Here is your page:\n\n" +
    "```html\n" +
    `<!-- ${filename} -->\n` +
    `<!DOCTYPE html><html><body>${content}</body></html>\n` +
    "```"
  );
}

// Named Python block (non-preview — renders as ArtifactCard only)
function pyArtifact(filename: string, content: string): string {
  return (
    "Here is the script:\n\n" +
    "```python\n" +
    `# ${filename}\n` +
    `${content}\n` +
    "```"
  );
}

// ---------------------------------------------------------------------------
// Group 1: Model badge per message (Feature 2)
// ---------------------------------------------------------------------------

test.describe("Chat — model badge per message", () => {
  let convIds: string[] = [];
  test.setTimeout(60_000);

  test.beforeEach(async ({ page }) => {
    await goToChatFresh(page);
  });

  test.afterEach(async ({ page }) => {
    const id = captureConvId(page);
    if (id) convIds.push(id);
    await deleteConversations(page, convIds);
    convIds = [];
  });

  test("assistant message shows model name in meta row", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Could not select preset "${TARGET_PRESET}"`).toBeTruthy();

    await interceptWithContent(page, "Hello, I am Claude.");
    await sendMessage(page, "Say hello.");
    await waitForStreamDone(page);

    const bubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(bubble).toBeVisible({ timeout: 10_000 });

    // Model badge must appear — the intercepted response includes model: "claude-sonnet-4-6"
    const badge = bubble.locator("[class*='bubble-meta-model']");
    await expect(badge).toBeVisible({ timeout: 5_000 });
    const text = (await badge.textContent()) ?? "";
    expect(text.trim().length, "model badge must have non-empty content").toBeGreaterThan(0);
  });

  test("user messages do not show a model badge", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Could not select preset "${TARGET_PRESET}"`).toBeTruthy();

    await interceptWithContent(page, "Hello!");
    await sendMessage(page, "Hi there.");
    await waitForStreamDone(page);

    const userBubble = page.locator("[class*='user-row']").last();
    await expect(userBubble).toBeVisible({ timeout: 5_000 });
    const badge = userBubble.locator("[class*='bubble-meta-model']");
    await expect(badge).not.toBeVisible();
  });
});

// ---------------------------------------------------------------------------
// Group 2: Reason-annotated regeneration (Feature 3)
// ---------------------------------------------------------------------------

test.describe("Chat — reason-annotated regeneration", () => {
  let convIds: string[] = [];
  test.setTimeout(60_000);

  test.beforeEach(async ({ page }) => {
    await goToChatFresh(page);
  });

  test.afterEach(async ({ page }) => {
    const id = captureConvId(page);
    if (id) convIds.push(id);
    await deleteConversations(page, convIds);
    convIds = [];
  });

  test("regenerate dropdown appears on last assistant message", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Could not select preset "${TARGET_PRESET}"`).toBeTruthy();

    await interceptWithContent(page, "First response.");
    await sendMessage(page, "Give me a response.");
    await waitForStreamDone(page);

    const bubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(bubble).toBeVisible({ timeout: 10_000 });

    // Hover to reveal action buttons
    await bubble.hover();

    // The dropdown chevron ▾ button must be visible
    const chevron = bubble.locator("button[aria-haspopup='true']");
    await expect(chevron, "dropdown chevron must appear on the regenerate split-button").toBeVisible({ timeout: 5_000 });
  });

  test("clicking dropdown chevron shows reason options", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Could not select preset "${TARGET_PRESET}"`).toBeTruthy();

    await interceptWithContent(page, "First response.");
    await sendMessage(page, "Give me a response.");
    await waitForStreamDone(page);

    const bubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(bubble).toBeVisible({ timeout: 10_000 });
    await bubble.hover();

    const chevron = bubble.locator("button[aria-haspopup='true']");
    await chevron.click();

    // Dropdown must list reason options
    await expect(page.getByText("Too long")).toBeVisible({ timeout: 3_000 });
    await expect(page.getByText("Too short")).toBeVisible({ timeout: 2_000 });
    await expect(page.getByText("Too formal")).toBeVisible({ timeout: 2_000 });
    await expect(page.getByText("Try again")).toBeVisible({ timeout: 2_000 });
  });

  test("selecting 'Too long' regenerates with reason injected as user message", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Could not select preset "${TARGET_PRESET}"`).toBeTruthy();

    // First response
    await interceptWithContent(page, "This is a long verbose response.");
    await sendMessage(page, "Explain something.");
    await waitForStreamDone(page);

    // Second response (after regenerate)
    await interceptWithContent(page, "Short response.");

    const bubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await bubble.hover();
    const chevron = bubble.locator("button[aria-haspopup='true']");
    await chevron.click();

    // Small wait for dropdown to settle before clicking a reason option
    await page.waitForTimeout(150);
    await page.getByRole("button", { name: "Too long" }).click({ force: true, timeout: 5_000 });

    // A new inference was triggered — wait for the new assistant response
    // (the reason message, if any, appears as a user bubble before the assistant reply)
    await waitForStreamDone(page, 30_000);

    // The regenerated response must appear (confirms onRegenerate fired)
    const lastBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(lastBubble).toBeVisible({ timeout: 10_000 });

    // No error banner
    await expect(page.getByText(/TypeError|failed to fetch/i).first()).not.toBeVisible({ timeout: 2_000 }).catch(() => {});
  });

  test("'Try again' regenerates without adding a reason message", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Could not select preset "${TARGET_PRESET}"`).toBeTruthy();

    await interceptWithContent(page, "First attempt.");
    await sendMessage(page, "Give me an answer.");
    await waitForStreamDone(page);

    // Wait for assistant bubble to render before counting
    await expect(page.locator("[class*='bubble-row']:not([class*='user-row'])").last()).toBeVisible({ timeout: 5_000 });
    const msgsBefore = await page.locator("[class*='bubble-row']").count();

    // Second intercept for regenerated response
    await interceptWithContent(page, "Second attempt.");

    const bubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await bubble.hover();
    const chevron = bubble.locator("button[aria-haspopup='true']");
    await chevron.click();
    await page.waitForTimeout(150);
    await page.getByRole("button", { name: "Try again" }).click({ force: true, timeout: 5_000 });

    await waitForStreamDone(page, 30_000);

    // Message count should be same or less (assistant replaced, no extra user message)
    const msgsAfter = await page.locator("[class*='bubble-row']").count();
    expect(msgsAfter, "Try again should not add extra messages").toBeLessThanOrEqual(msgsBefore);
  });
});

// ---------------------------------------------------------------------------
// Group 3: Multi-artifact panel + versioning (Feature 4)
// ---------------------------------------------------------------------------

test.describe("Chat — multi-artifact panel and versioning", () => {
  let convIds: string[] = [];
  test.setTimeout(120_000);

  test.beforeEach(async ({ page }) => {
    await goToChatFresh(page);
  });

  test.afterEach(async ({ page }) => {
    const id = captureConvId(page);
    if (id) convIds.push(id);
    await deleteConversations(page, convIds);
    convIds = [];
  });

  test("clicking an artifact card opens the artifact panel", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Could not select preset "${TARGET_PRESET}"`).toBeTruthy();

    await interceptWithContent(page, htmlArtifact("index.html", "<h1>Hello</h1>"));
    await sendMessage(page, "Create a simple HTML page.");
    await waitForStreamDone(page);

    // ArtifactCard must appear in the message
    const card = page.locator("[data-cy='artifact-card']").first();
    await expect(card).toBeVisible({ timeout: 10_000 });

    // Click it — panel must open
    await card.click();
    await expect(page.locator("[data-cy='artifact-panel']")).toBeVisible({ timeout: 5_000 });

    // Panel shows code
    const editor = page.locator("[data-cy='panel-editor']");
    await expect(editor).toBeVisible({ timeout: 3_000 });
    const code = await editor.inputValue();
    expect(code).toContain("<h1>Hello</h1>");
  });

  test("two different artifacts open as separate tabs", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Could not select preset "${TARGET_PRESET}"`).toBeTruthy();

    // Message 1: index.html
    await interceptWithContent(page, htmlArtifact("index.html", "<h1>Page 1</h1>"));
    await sendMessage(page, "Create index.html");
    await waitForStreamDone(page);

    const card1 = page.locator("[data-cy='artifact-card']").first();
    await expect(card1).toBeVisible({ timeout: 10_000 });
    await card1.click();
    await expect(page.locator("[data-cy='artifact-panel']")).toBeVisible({ timeout: 5_000 });

    // Message 2: utils.py — use fill+Enter same as sendMessage helper
    await interceptWithContent(page, pyArtifact("utils.py", "def hello(): return 'hi'"));
    await page.locator("[class*='chat-textarea']").fill("Now create utils.py");
    await expect(page.locator("button[title='Send message']")).toBeEnabled({ timeout: 5_000 });
    await page.locator("[class*='chat-textarea']").press("Enter");
    await expect(page.locator("[class*='user-row']").last()).toBeVisible({ timeout: 10_000 });
    await waitForStreamDone(page);

    const cards = page.locator("[data-cy='artifact-card']");
    await expect(cards).toHaveCount(2, { timeout: 10_000 });
    await cards.last().click();

    // Tab bar must now show 2 tabs
    const tabBar = page.locator("[data-cy='artifact-tab-bar']");
    await expect(tabBar).toBeVisible({ timeout: 5_000 });
    const tabs = tabBar.locator("[data-cy='artifact-tab']");
    await expect(tabs).toHaveCount(2, { timeout: 3_000 });
  });

  test("same-filename artifact creates a second version with navigation controls", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Could not select preset "${TARGET_PRESET}"`).toBeTruthy();

    // V1
    await interceptWithContent(page, htmlArtifact("page.html", "<h1>Version 1</h1>"));
    await sendMessage(page, "Create page.html v1");
    await waitForStreamDone(page);

    const card1 = page.locator("[data-cy='artifact-card']").first();
    await expect(card1).toBeVisible({ timeout: 10_000 });
    await card1.click();
    await expect(page.locator("[data-cy='artifact-panel']")).toBeVisible({ timeout: 5_000 });

    // No version nav yet (only 1 version)
    await expect(page.locator("[data-cy='version-nav']")).not.toBeVisible();

    // V2 — same filename, different content
    await interceptWithContent(page, htmlArtifact("page.html", "<h1>Version 2</h1>"));
    await page.locator("[class*='chat-textarea']").fill("Update page.html to v2");
    await expect(page.locator("button[title='Send message']")).toBeEnabled({ timeout: 5_000 });
    await page.locator("[class*='chat-textarea']").press("Enter");
    await expect(page.locator("[class*='user-row']").last()).toBeVisible({ timeout: 10_000 });
    await waitForStreamDone(page);

    // Click the new artifact card (wait for it to render after stream done)
    const cards = page.locator("[data-cy='artifact-card']");
    await expect(cards).toHaveCount(2, { timeout: 10_000 });
    await cards.last().click();

    // Version nav must now appear
    const versionNav = page.locator("[data-cy='version-nav']");
    await expect(versionNav).toBeVisible({ timeout: 5_000 });

    // Label shows v2/2
    const label = page.locator("[data-cy='version-label']");
    await expect(label).toContainText("v2/2", { timeout: 3_000 });

    // Current version shows "Version 2"
    const editor = page.locator("[data-cy='panel-editor']");
    const v2Code = await editor.inputValue();
    expect(v2Code).toContain("Version 2");

    // Navigate back to v1
    await page.locator("[data-cy='version-prev']").click();
    await expect(label).toContainText("v1/2", { timeout: 3_000 });

    const v1Code = await editor.inputValue();
    expect(v1Code).toContain("Version 1");

    // Forward button disabled check (we're at v1; prev should be disabled)
    await expect(page.locator("[data-cy='version-prev']")).toBeDisabled();
    await expect(page.locator("[data-cy='version-next']")).not.toBeDisabled();
  });

  test("closing a tab removes it; closing last tab hides the panel", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Could not select preset "${TARGET_PRESET}"`).toBeTruthy();

    // Open two artifacts
    await interceptWithContent(page, htmlArtifact("a.html", "<p>A</p>"));
    await sendMessage(page, "Create a.html");
    await waitForStreamDone(page);

    await page.locator("[data-cy='artifact-card']").first().click();
    await expect(page.locator("[data-cy='artifact-panel']")).toBeVisible({ timeout: 5_000 });

    await interceptWithContent(page, pyArtifact("b.py", "print('B')"));
    await page.locator("[class*='chat-textarea']").fill("Create b.py");
    await expect(page.locator("button[title='Send message']")).toBeEnabled({ timeout: 5_000 });
    await page.locator("[class*='chat-textarea']").press("Enter");
    await expect(page.locator("[class*='user-row']").last()).toBeVisible({ timeout: 10_000 });
    await waitForStreamDone(page);
    // Wait for b.py artifact card to render before clicking it
    await expect(page.locator("[data-cy='artifact-card']")).toHaveCount(2, { timeout: 10_000 });
    await page.locator("[data-cy='artifact-card']").last().click();

    const tabBar = page.locator("[data-cy='artifact-tab-bar']");
    await expect(tabBar).toBeVisible({ timeout: 5_000 });
    await expect(tabBar.locator("[data-cy='artifact-tab']")).toHaveCount(2, { timeout: 3_000 });

    // Close one tab — the header close button closes the active tab when multiple exist
    await page.locator("[data-cy='panel-close-btn']").click();

    // Tab bar hides when only 1 tab remains (correct: no tab bar needed for single artifact)
    await expect(tabBar).not.toBeVisible({ timeout: 3_000 });

    // Panel itself still visible (the remaining artifact is shown)
    await expect(page.locator("[data-cy='artifact-panel']")).toBeVisible({ timeout: 3_000 });

    // Close the last remaining artifact
    await page.locator("[data-cy='panel-close-btn']").click();

    // Panel must disappear
    await expect(page.locator("[data-cy='artifact-panel']")).not.toBeVisible({ timeout: 5_000 });
  });

  test("panel download button triggers a download", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Could not select preset "${TARGET_PRESET}"`).toBeTruthy();

    await interceptWithContent(page, pyArtifact("script.py", "print('hello')"));
    await sendMessage(page, "Create script.py");
    await waitForStreamDone(page);

    await page.locator("[data-cy='artifact-card']").first().click();
    await expect(page.locator("[data-cy='artifact-panel']")).toBeVisible({ timeout: 5_000 });

    // Click download and verify download event
    const [download] = await Promise.all([
      page.waitForEvent("download", { timeout: 5_000 }),
      page.locator("[data-cy='panel-download-btn']").click(),
    ]);
    expect(download.suggestedFilename()).toBe("script.py");
  });

  test("copy button copies artifact code to clipboard", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Could not select preset "${TARGET_PRESET}"`).toBeTruthy();

    await interceptWithContent(page, pyArtifact("hello.py", "print('hello world')"));
    await sendMessage(page, "Create hello.py");
    await waitForStreamDone(page);

    await page.locator("[data-cy='artifact-card']").first().click();
    await expect(page.locator("[data-cy='artifact-panel']")).toBeVisible({ timeout: 5_000 });

    // Grant clipboard write permission
    await page.context().grantPermissions(["clipboard-read", "clipboard-write"]);
    await page.locator("[data-cy='panel-copy-btn']").click();

    // Button should show "Copied!" briefly
    await expect(page.locator("[data-cy='panel-copy-btn']")).toContainText("Copied!", { timeout: 3_000 });
  });
});
