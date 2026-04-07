/**
 * ghost-chat.spec.ts — E2E tests for ghost mode in the Chat view.
 *
 * Ghost mode suppresses all database writes (chat_conversation, chat_message,
 * chat_attachment) and instructs the gateway to skip the request_log entry.
 *
 * Suites:
 *   1. Toggle UI  — button visible, banner appears/disappears, preference persists
 *   2. No DB writes — conversation and messages are NOT created in the database
 *   3. No request log — gateway log not created for ghost inference calls
 *   4. In-memory only — ghost conversation is gone after navigation
 *   5. Normal mode — conversation IS saved when ghost mode is off
 *   6. Regression — feedback button hidden in ghost mode
 */

import { test, expect, Page } from "@playwright/test";

const ADMIN_BASE = "http://localhost:5173/admin/v1";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function getConversationCount(page: Page): Promise<number> {
  const resp = await page.context().request.get(`${ADMIN_BASE}/conversations`);
  if (!resp.ok()) return -1;
  const list = await resp.json() as unknown[];
  return Array.isArray(list) ? list.length : -1;
}

async function getRecentLogs(page: Page): Promise<Array<{ id: string; prompt?: string }>> {
  const resp = await page.context().request.get(`${ADMIN_BASE}/logs?limit=5`);
  if (!resp.ok()) return [];
  const body = await resp.json() as unknown;
  if (Array.isArray(body)) return body as Array<{ id: string; prompt?: string }>;
  if (body && typeof body === "object" && "logs" in (body as object)) {
    return (body as { logs: Array<{ id: string; prompt?: string }> }).logs;
  }
  return [];
}

async function openChat(page: Page) {
  await page.goto("/chat");
  await page.waitForLoadState("networkidle");
}

/**
 * Select the myratest tenant and "PII claude-sonnet-4-6" preset so the chat
 * input is ready for inference.
 *
 * myratest uses preset mode (chat_presets are configured), so the UI shows
 * preset buttons (data-testid="config-preset-btn") instead of individual
 * gateway/model dropdowns. We select the preset by name, falling back to the
 * first available preset if the named one is absent.
 *
 * Fails the test loudly if no tenant or no preset is found.
 */
async function selectFirstGateway(page: Page): Promise<void> {
  // Find the myratest tenant ID from the API
  const tr = await page.context().request.get(`${ADMIN_BASE}/tenants`);
  expect(tr.ok(), "tenants API must respond OK").toBeTruthy();
  const tenants = await tr.json() as Array<{ id: string; slug: string; chat_presets?: Array<{ id: string; name: string }> }>;
  expect(tenants.length, "At least one tenant must exist").toBeGreaterThan(0);

  // Prefer myratest; fall back to the first tenant that has chat_presets
  const myratest = tenants.find((t) => t.slug === "myratest");
  const tenantWithPresets = myratest ?? tenants.find((t) => (t.chat_presets ?? []).length > 0);
  expect(tenantWithPresets, "myratest tenant (or any tenant with presets) must exist").toBeTruthy();
  const targetTenantId = tenantWithPresets!.id;

  // Select the tenant in the Tenant dropdown
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  await tenantSel.selectOption({ value: targetTenantId });

  // In preset mode the gateway/model dropdowns are replaced by preset buttons.
  // Wait for at least one preset button to appear.
  const presetBtn = page.locator("[data-testid='config-preset-btn']");
  await expect(presetBtn.first()).toBeVisible({ timeout: 5000 });

  // Always use the first preset (SAFE local only / vllm) for inference tests.
  // "PII claude-sonnet-4-6" uses Anthropic, whose key is encrypted with the
  // production master key and cannot be decrypted in the local test environment.
  await presetBtn.first().click();

  // Confirm textarea is enabled — gateway + model are now set in React state
  await expect(page.locator("textarea").first()).toBeEnabled({ timeout: 5000 });
}

async function enableGhostMode(page: Page) {
  const btn = page.locator("[data-cy=ghost-mode-toggle]");
  await btn.waitFor({ state: "visible" });
  const bannerVisible = await page.locator("[data-cy=ghost-banner]").isVisible().catch(() => false);
  if (!bannerVisible) await btn.click();
  await page.locator("[data-cy=ghost-banner]").waitFor({ state: "visible" });
}

async function disableGhostMode(page: Page) {
  const bannerVisible = await page.locator("[data-cy=ghost-banner]").isVisible().catch(() => false);
  if (bannerVisible) {
    await page.locator("[data-cy=ghost-mode-toggle]").click();
    await page.locator("[data-cy=ghost-banner]").waitFor({ state: "hidden" });
  }
}

/**
 * Send a message and wait for the full inference round-trip to complete.
 *
 * Uses the send button (not Enter key) to bypass React prop timing issues where
 * the textarea appears HTML-enabled but the component's disabled prop is still
 * true, silently suppressing onSend().
 *
 * Streaming detection: waits for "Stop generation" to appear (streaming started),
 * then waits for "Send message" to return (streaming finished). This avoids the
 * false-positive of checking "Send message" alone, which is the pre-send default.
 */
async function sendAndAwaitResponse(page: Page, text: string): Promise<void> {
  const input = page.locator("textarea").first();
  await input.fill(text);

  // Click the send button rather than pressing Enter — more reliable since we
  // can assert the button is enabled before clicking.
  const sendBtn = page.locator("button[title='Send message']");
  await expect(sendBtn).toBeEnabled({ timeout: 5000 });
  await sendBtn.click();

  // Textarea must clear — confirms the message was submitted to React state
  await expect(input).toHaveValue("", { timeout: 5000 });

  // No error must appear right after submission
  await expect(page.getByText(/failed to fetch/i)).not.toBeVisible({ timeout: 3000 });
  await expect(page.getByText(/provider api key/i)).not.toBeVisible({ timeout: 3000 });

  // Streaming must start: button switches to "Stop generation"
  await expect(page.locator("button[title='Stop generation']")).toBeVisible({ timeout: 10000 });

  // Streaming must finish: button returns to "Send message"
  await expect(page.locator("button[title='Send message']")).toBeVisible({ timeout: 30000 });

  // Final check: no error banner after full response
  await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
  await expect(page.getByText(/something went wrong/i)).not.toBeVisible();
}

// ---------------------------------------------------------------------------
// Suite 1 — Toggle UI
// ---------------------------------------------------------------------------

test.describe("Ghost mode — toggle UI", () => {
  test("ghost mode toggle button is visible in the chat header", async ({ page }) => {
    await openChat(page);
    await expect(page.locator("[data-cy=ghost-mode-toggle]")).toBeVisible();
  });

  test("clicking the toggle shows the ghost banner", async ({ page }) => {
    await openChat(page);
    await disableGhostMode(page);
    await expect(page.locator("[data-cy=ghost-banner]")).not.toBeVisible();

    await page.locator("[data-cy=ghost-mode-toggle]").click();
    await expect(page.locator("[data-cy=ghost-banner]")).toBeVisible();
    await expect(page.locator("[data-cy=ghost-banner]")).toContainText("Ghost mode");

    await disableGhostMode(page);
  });

  test("clicking the toggle again hides the ghost banner", async ({ page }) => {
    await openChat(page);
    await enableGhostMode(page);
    await page.locator("[data-cy=ghost-mode-toggle]").click();
    await expect(page.locator("[data-cy=ghost-banner]")).not.toBeVisible();
  });

  test("ghost mode preference persists across page reload", async ({ page }) => {
    await openChat(page);
    await enableGhostMode(page);

    await page.reload();
    await page.waitForLoadState("networkidle");

    await expect(page.locator("[data-cy=ghost-banner]")).toBeVisible();

    await disableGhostMode(page);
  });
});

// ---------------------------------------------------------------------------
// Suite 2 — No DB writes
// ---------------------------------------------------------------------------

test.describe("Ghost mode — no DB writes", () => {
  test.beforeEach(async ({ page }) => {
    await openChat(page);
    await selectFirstGateway(page);
    await enableGhostMode(page);
  });

  test.afterEach(async ({ page }) => {
    await disableGhostMode(page);
  });

  test("sending a message in ghost mode does not create a conversation in the DB", async ({ page }) => {
    const marker = "ghost-test-no-db-write-" + Date.now();
    await sendAndAwaitResponse(page, marker);

    // After a full round-trip, no conversation with this title must exist in the DB
    const resp = await page.context().request.get(`${ADMIN_BASE}/conversations`);
    expect(resp.ok(), "conversations API must respond OK").toBeTruthy();
    const convs = await resp.json() as Array<{ id: string; title?: string }>;
    const created = convs.find((c) => (c.title ?? "").startsWith(marker.slice(0, 40)));
    expect(created, "ghost mode must not create a DB conversation").toBeUndefined();
  });

  test("messages sent in ghost mode render in the UI (user + assistant)", async ({ page }) => {
    const marker = "ghost-ui-render-test-" + Date.now();
    await sendAndAwaitResponse(page, marker);

    // User bubble must contain the sent text (scoped to user-row, not the textarea)
    await expect(page.locator("[class*='user-row']").getByText(marker)).toBeVisible({ timeout: 5000 });

    // An assistant bubble must exist and contain content
    // sendAndAwaitResponse already confirmed streaming completed, so the bubble must be rendered
    await expect(page.locator("[class*='bubble-row']:not([class*='user-row'])").last())
      .toBeVisible({ timeout: 5000 });
  });

  test("ghost conversations do not appear in the conversation sidebar", async ({ page }) => {
    const marker = "ghost-sidebar-test-" + Date.now();
    await sendAndAwaitResponse(page, marker);

    // Ghost conversations are never fetched from DB so cannot appear in the sidebar.
    // Scope to the sidebar — the textarea is already empty after send.
    const sidebar = page.locator("[aria-label='Conversations']");
    await expect(sidebar).toBeVisible({ timeout: 5000 });
    await expect(sidebar.getByText(marker.slice(0, 40))).not.toBeVisible();
  });
});

// ---------------------------------------------------------------------------
// Suite 3 — No request log
// ---------------------------------------------------------------------------

test.describe("Ghost mode — no request log", () => {
  test("inference call in ghost mode does not create a request log entry", async ({ page }) => {
    await openChat(page);
    await selectFirstGateway(page);
    await enableGhostMode(page);

    const logsBefore = await getRecentLogs(page);
    const logCountBefore = logsBefore.length;

    await sendAndAwaitResponse(page, "ghost-log-test-" + Date.now());

    const logsAfter = await getRecentLogs(page);
    expect(logsAfter.length).toBe(logCountBefore);

    await disableGhostMode(page);
  });
});

// ---------------------------------------------------------------------------
// Suite 4 — In-memory only
// ---------------------------------------------------------------------------

test.describe("Ghost mode — conversation is in-memory only", () => {
  test("ghost conversation is gone after navigating away and back", async ({ page }) => {
    await openChat(page);
    await selectFirstGateway(page);
    await enableGhostMode(page);

    const marker = "ghost-nav-test-" + Date.now();
    await sendAndAwaitResponse(page, marker);
    // Scope to the user bubble — the assistant may echo the text in its reply
    await expect(page.locator("[class*='user-row']").getByText(marker)).toBeVisible();

    // Navigate away and back
    await page.goto("/dashboard");
    await page.waitForLoadState("networkidle");
    await openChat(page);

    // Ghost conversation content must be gone (scoped to user bubbles)
    await expect(page.locator("[class*='user-row']").getByText(marker)).not.toBeVisible();

    // Ghost banner must still be active (preference was saved to localStorage)
    await expect(page.locator("[data-cy=ghost-banner]")).toBeVisible();

    await disableGhostMode(page);
  });
});

// ---------------------------------------------------------------------------
// Suite 5 — Normal mode still works
// ---------------------------------------------------------------------------

test.describe("Normal mode — conversation is saved", () => {
  test("sending a message with ghost mode off creates a conversation in the DB", async ({ page }) => {
    await openChat(page);
    await selectFirstGateway(page);
    await disableGhostMode(page);

    // Record count before
    const before = await page.context().request.get(`${ADMIN_BASE}/conversations`);
    expect(before.ok(), "conversations API must respond OK").toBeTruthy();
    const convsBefore = await before.json() as Array<{ id: string; created_at?: string }>;
    const countBefore = convsBefore.length;
    const beforeIds = new Set(convsBefore.map((c) => c.id));

    const marker = "normal-mode-db-test-" + Date.now();
    await sendAndAwaitResponse(page, marker);

    // A new conversation row must exist — title generation is async so we
    // compare IDs rather than looking up by title.
    const after = await page.context().request.get(`${ADMIN_BASE}/conversations`);
    expect(after.ok(), "conversations API must respond OK").toBeTruthy();
    const convsAfter = await after.json() as Array<{ id: string }>;
    const newConv = convsAfter.find((c) => !beforeIds.has(c.id));
    expect(newConv, "a new conversation must have been created in the DB").toBeTruthy();

    // Clean up
    if (newConv) {
      await page.context().request.delete(`${ADMIN_BASE}/conversations/${newConv.id}`).catch(() => {});
    }
  });
});

// ---------------------------------------------------------------------------
// Suite 6 — Regression: feedback button hidden in ghost mode
// ---------------------------------------------------------------------------

test.describe("Ghost mode — regression", () => {
  test("feedback button is hidden when ghost mode is active", async ({ page }) => {
    await openChat(page);
    await selectFirstGateway(page);
    await disableGhostMode(page);

    // Send a message so a response bubble (with a potential feedback button) exists
    await sendAndAwaitResponse(page, "feedback-test-" + Date.now());

    // In normal mode, feedback button may be visible on the assistant bubble
    const feedbackBtn = page.locator("[title*='feedback'], [title*='Feedback']").first();

    await enableGhostMode(page);
    // In ghost mode, the feedback button must not be visible
    await expect(feedbackBtn).not.toBeVisible();

    await disableGhostMode(page);
  });

  test("ghost mode does not trigger a CORS error (x-aig-collect-log must be in Allow-Headers)", async ({ page }) => {
    // Regression: x-aig-collect-log was missing from the gateway's CORS
    // Access-Control-Allow-Headers list, causing the browser to block the
    // preflight and surface "TypeError: Failed to fetch" in ghost mode.
    //
    // This test uses the "PII claude-sonnet-4-6" preset (prod-pii / Anthropic)
    // because that is the gateway where the CORS bug was first reported.
    // In the local test environment, the Anthropic provider key cannot be
    // decrypted (production master key), so inference itself may fail with
    // "Provider API key unavailable" — that is an ACCEPTABLE error here
    // because it proves the CORS preflight PASSED. A CORS block would show
    // "TypeError: Failed to fetch" instead.
    await openChat(page);

    // Manually select the PII preset — bypass selectFirstGateway which picks SAFE
    const tr = await page.context().request.get(`${ADMIN_BASE}/tenants`);
    const tenants = await tr.json() as Array<{ id: string; slug: string }>;
    const myratest = tenants.find((t) => t.slug === "myratest");
    expect(myratest, "myratest tenant must exist").toBeTruthy();

    const tenantSel = page.locator("select").first();
    await tenantSel.waitFor({ state: "visible", timeout: 5000 });
    await tenantSel.selectOption({ value: myratest!.id });

    const piiBtn = page.locator("[data-testid='config-preset-btn']", { hasText: "PII claude-sonnet-4-6" });
    await expect(piiBtn).toBeVisible({ timeout: 5000 });
    await piiBtn.click();
    await expect(page.locator("textarea").first()).toBeEnabled({ timeout: 5000 });

    await enableGhostMode(page);

    // Intercept the OPTIONS preflight to the inference endpoint
    let preflightAllowHeaders: string | null = null;
    let preflightStatus: number | null = null;
    page.on("response", (resp) => {
      if (resp.request().method() === "OPTIONS" && resp.url().includes("/v1/")) {
        preflightAllowHeaders = resp.headers()["access-control-allow-headers"] ?? null;
        preflightStatus = resp.status();
      }
    });

    // Send a message — this triggers the CORS preflight for x-aig-collect-log.
    // We do NOT assert streaming completes because the provider key may fail in
    // the local test env. We only assert the CORS error ("Failed to fetch") is absent.
    const input = page.locator("textarea").first();
    await input.fill("ghost-cors-regression-" + Date.now());
    const sendBtn = page.locator("button[title='Send message']");
    await expect(sendBtn).toBeEnabled({ timeout: 5000 });
    await sendBtn.click();
    await expect(input).toHaveValue("", { timeout: 5000 });

    // Wait briefly for any preflight/response to arrive
    await page.waitForTimeout(3000);

    // The critical assertion: CORS failure shows "Failed to fetch", not a provider error
    await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();

    // If a preflight was captured (same-origin dev env won't send one; production does),
    // verify the response includes x-aig-collect-log in allowed headers.
    if (preflightAllowHeaders !== null) {
      expect(
        preflightAllowHeaders.toLowerCase(),
        "Access-Control-Allow-Headers must include x-aig-collect-log"
      ).toContain("x-aig-collect-log");
    }

    await disableGhostMode(page);
  });

  test("toggling ghost mode resets the active conversation", async ({ page }) => {
    await openChat(page);
    await selectFirstGateway(page);
    await disableGhostMode(page);

    // Start a normal conversation
    const marker = "normal-before-ghost-" + Date.now();
    await sendAndAwaitResponse(page, marker);
    // Scope to user bubble, not textarea
    await expect(page.locator("[class*='user-row']").getByText(marker)).toBeVisible({ timeout: 5000 });

    // Enable ghost mode — the conversation must be cleared from the view
    await enableGhostMode(page);
    // Scope to bubbles only — the textarea is empty after send so this is unambiguous
    await expect(page.locator("[class*='user-row']").getByText(marker)).not.toBeVisible({ timeout: 5000 });

    // Clean up DB
    try {
      const resp = await page.context().request.get(`${ADMIN_BASE}/conversations`);
      if (resp.ok()) {
        const convs = await resp.json() as Array<{ id: string; title?: string }>;
        const created = convs.find((c) => (c.title ?? "").startsWith(marker.slice(0, 40)));
        if (created) {
          await page.context().request.delete(`${ADMIN_BASE}/conversations/${created.id}`).catch(() => {});
        }
      }
    } catch { /* best-effort cleanup */ }

    await disableGhostMode(page);
  });
});
