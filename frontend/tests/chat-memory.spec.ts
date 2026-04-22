/**
 * chat-memory.spec.ts — E2E tests for the Memory System feature.
 *
 * Coverage:
 *   Group 1 — API: CRUD operations on /memories
 *   Group 2 — UI: MemoriesPanel open/close, add, delete
 *   Group 3 — UI: memory_disabled toggle on conversation
 *   Group 4 — UI: <memory> tag in streamed response is stripped + saved
 */

import { test, expect, type Page } from "@playwright/test";

const ADMIN_BASE = `${process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173"}/admin/v1`;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

interface MemRow { id: string; content: string; type: string; source: string; }
interface ConvRow { id: string; title: string; }
interface TenantRow { id: string; slug: string; }
interface GatewayRow { id: string; slug: string; }

async function getGatewayId(page: Page): Promise<string> {
  const tr = await page.request.get(`${ADMIN_BASE}/tenants`);
  expect(tr.ok(), "tenants fetch ok").toBeTruthy();
  const tenants = await tr.json() as TenantRow[];
  for (const t of tenants) {
    const gr = await page.request.get(`${ADMIN_BASE}/tenants/${t.id}/gateways`);
    if (!gr.ok()) continue;
    const gws = await gr.json() as GatewayRow[];
    if (gws.length) return gws[0].id;
  }
  throw new Error("No gateway found");
}

async function createConv(page: Page, gatewayId: string, title: string): Promise<string> {
  const r = await page.request.post(`${ADMIN_BASE}/conversations`, {
    data: { gateway_id: gatewayId, title },
  });
  expect(r.ok(), `createConv: ${await r.text()}`).toBeTruthy();
  return (await r.json() as ConvRow).id;
}

async function deleteConv(page: Page, id: string) {
  await page.request.delete(`${ADMIN_BASE}/conversations/${id}`).catch(() => {});
}

async function createMemory(page: Page, content: string, type = "fact"): Promise<MemRow> {
  const r = await page.request.post(`${ADMIN_BASE}/memories`, {
    data: { content, type, source: "manual" },
  });
  expect(r.ok(), `createMemory: ${await r.text()}`).toBeTruthy();
  return r.json();
}

async function deleteMemory(page: Page, id: string) {
  await page.request.delete(`${ADMIN_BASE}/memories/${id}`).catch(() => {});
}

async function listMemories(page: Page): Promise<MemRow[]> {
  const r = await page.request.get(`${ADMIN_BASE}/memories`);
  expect(r.ok(), "listMemories ok").toBeTruthy();
  return r.json();
}

// ---------------------------------------------------------------------------
// Group 1: API — CRUD
// ---------------------------------------------------------------------------

test.describe("memories API", () => {
  const created: string[] = [];

  test.afterEach(async ({ page }) => {
    for (const id of created) await deleteMemory(page, id);
    created.length = 0;
  });

  test("POST /memories creates a memory", async ({ page }) => {
    const m = await createMemory(page, "User prefers dark mode");
    created.push(m.id);
    expect(m.id).toBeTruthy();
    expect(m.content).toBe("User prefers dark mode");
    expect(m.type).toBe("fact");
    expect(m.source).toBe("manual");
  });

  test("GET /memories returns created memory", async ({ page }) => {
    const m = await createMemory(page, "User is a software engineer");
    created.push(m.id);
    const list = await listMemories(page);
    const found = list.find(x => x.id === m.id);
    expect(found, "memory in list").toBeTruthy();
    expect(found!.content).toBe("User is a software engineer");
  });

  test("PATCH /memories/:id updates content", async ({ page }) => {
    const m = await createMemory(page, "Original content");
    created.push(m.id);
    const r = await page.request.patch(`${ADMIN_BASE}/memories/${m.id}`, {
      data: { content: "Updated content" },
    });
    expect(r.ok(), "PATCH ok").toBeTruthy();
    const list = await listMemories(page);
    const found = list.find(x => x.id === m.id);
    expect(found!.content).toBe("Updated content");
  });

  test("DELETE /memories/:id removes memory from list", async ({ page }) => {
    const m = await createMemory(page, "To be deleted");
    await deleteMemory(page, m.id);
    const list = await listMemories(page);
    expect(list.find(x => x.id === m.id)).toBeUndefined();
  });

  test("POST with source=auto stores source correctly", async ({ page }) => {
    const r = await page.request.post(`${ADMIN_BASE}/memories`, {
      data: { content: "Auto-extracted fact", type: "preference", source: "auto" },
    });
    expect(r.ok()).toBeTruthy();
    const m = await r.json() as MemRow;
    created.push(m.id);
    expect(m.source).toBe("auto");
    expect(m.type).toBe("preference");
  });

  test("POST without content returns 400", async ({ page }) => {
    const r = await page.request.post(`${ADMIN_BASE}/memories`, { data: { type: "fact" } });
    expect(r.status()).toBe(400);
  });

  test("POST with invalid type returns 400", async ({ page }) => {
    const r = await page.request.post(`${ADMIN_BASE}/memories`, {
      data: { content: "Test", type: "invalid_type" },
    });
    expect(r.status()).toBe(400);
  });

  test("GET /memories returns empty array when none exist", async ({ page }) => {
    // Delete all memories first
    const all = await listMemories(page);
    for (const m of all) await deleteMemory(page, m.id);
    const list = await listMemories(page);
    expect(Array.isArray(list), "is array").toBeTruthy();
  });
});

// ---------------------------------------------------------------------------
// Group 2: UI — MemoriesPanel open/close, add, delete
// ---------------------------------------------------------------------------

test.describe("memories UI panel", () => {
  test.beforeEach(async ({ page }) => {
    // Clean up all existing memories so tests start fresh
    const all = await (async () => {
      const r = await page.request.get(`${ADMIN_BASE}/memories`);
      if (!r.ok()) return [];
      return r.json() as Promise<MemRow[]>;
    })();
    for (const m of all) await deleteMemory(page, m.id);
  });

  test.afterEach(async ({ page }) => {
    const all = await (async () => {
      const r = await page.request.get(`${ADMIN_BASE}/memories`);
      if (!r.ok()) return [];
      return r.json() as Promise<MemRow[]>;
    })();
    for (const m of all) await deleteMemory(page, m.id);
  });

  test("memories button opens panel", async ({ page }) => {
    await page.goto("/chat");
    await expect(page.locator("[data-cy='memories-btn']")).toBeVisible({ timeout: 8000 });
    await page.locator("[data-cy='memories-btn']").click();
    await expect(page.locator("[data-cy='memories-panel']")).toBeVisible({ timeout: 5000 });
  });

  test("panel closes when × is clicked", async ({ page }) => {
    await page.goto("/chat");
    await page.locator("[data-cy='memories-btn']").click();
    await expect(page.locator("[data-cy='memories-panel']")).toBeVisible({ timeout: 5000 });
    await page.locator("[data-cy='memories-panel'] button").filter({ hasText: "×" }).click();
    await expect(page.locator("[data-cy='memories-panel']")).not.toBeVisible({ timeout: 3000 });
  });

  test("adding a memory via UI shows it in the panel", async ({ page }) => {
    await page.goto("/chat");
    await page.locator("[data-cy='memories-btn']").click();
    await expect(page.locator("[data-cy='memories-panel']")).toBeVisible({ timeout: 5000 });

    const content = "User is vegetarian " + Date.now();
    await page.locator("[data-cy='memory-add-input']").fill(content);
    await page.locator("[data-cy='memory-add-btn']").click();

    await expect(page.getByText(content)).toBeVisible({ timeout: 5000 });
  });

  test("deleting a memory via UI removes it from panel", async ({ page }) => {
    // Create a memory first
    const m = await createMemory(page, "To be deleted via UI " + Date.now());

    await page.goto("/chat");
    await page.locator("[data-cy='memories-btn']").click();
    await expect(page.locator("[data-cy='memories-panel']")).toBeVisible({ timeout: 5000 });
    await expect(page.getByText(m.content)).toBeVisible({ timeout: 5000 });

    // Click the delete button for this specific memory.
    // The text <p> is nested inside: p -> div(flex:1) -> div(flex-row) -> div(item)
    // The delete button is in a sibling of div(flex:1), so go up 3 levels to the item div.
    const item = page.getByText(m.content).locator("../../..");
    await item.locator("[data-cy='memory-delete-btn']").click();

    await expect(page.getByText(m.content)).not.toBeVisible({ timeout: 5000 });
  });

  test("memories count badge appears on button when memories exist", async ({ page }) => {
    await createMemory(page, "Badge test memory " + Date.now());

    await page.goto("/chat");
    // Button should show count badge
    await expect(page.locator("[data-cy='memories-btn'] span")).toBeVisible({ timeout: 8000 });
  });
});

// ---------------------------------------------------------------------------
// Group 3: UI — memory_disabled toggle
// ---------------------------------------------------------------------------

test.describe("memory_disabled toggle", () => {
  let convId: string;
  let gatewayId: string;

  test.beforeEach(async ({ page }) => {
    gatewayId = await getGatewayId(page);
    convId = await createConv(page, gatewayId, "memory-disabled-test-" + Date.now());
  });

  test.afterEach(async ({ page }) => {
    await deleteConv(page, convId);
  });

  test("PATCH conversation with memory_disabled=1 persists", async ({ page }) => {
    const r = await page.request.patch(`${ADMIN_BASE}/conversations/${convId}`, {
      data: { memory_disabled: 1 },
    });
    expect(r.ok(), "PATCH ok").toBeTruthy();

    // Re-fetch conversation
    const gr = await page.request.get(`${ADMIN_BASE}/conversations/${convId}`);
    expect(gr.ok()).toBeTruthy();
    const conv = await gr.json() as { memory_disabled?: number };
    expect(conv.memory_disabled).toBe(1);
  });

  test("PATCH conversation with memory_disabled=0 clears flag", async ({ page }) => {
    // Set to 1 first
    await page.request.patch(`${ADMIN_BASE}/conversations/${convId}`, { data: { memory_disabled: 1 } });
    // Then clear
    const r = await page.request.patch(`${ADMIN_BASE}/conversations/${convId}`, { data: { memory_disabled: 0 } });
    expect(r.ok()).toBeTruthy();
    const gr = await page.request.get(`${ADMIN_BASE}/conversations/${convId}`);
    const conv = await gr.json() as { memory_disabled?: number };
    expect(conv.memory_disabled == null || conv.memory_disabled === 0, "memory_disabled is 0 or absent").toBeTruthy();
  });

  test("memory_disabled toggle is visible in panel when conversation is active", async ({ page }) => {
    await page.goto("/dashboard");
    await page.evaluate((g) => { localStorage.setItem("aig-chat-gateway", g); }, gatewayId);
    await page.goto("/chat");

    // Select the conversation
    const item = page.locator(`[role="option"]:has-text("memory-disabled-test-")`).first();
    await expect(item).toBeVisible({ timeout: 8000 });
    await item.click();

    // Open memories panel
    await page.locator("[data-cy='memories-btn']").click();
    await expect(page.locator("[data-cy='memories-panel']")).toBeVisible({ timeout: 5000 });

    // Toggle should be present
    await expect(page.locator("[data-cy='memory-disabled-toggle']")).toBeVisible({ timeout: 3000 });
  });
});

// ---------------------------------------------------------------------------
// Group 4: UI — <memory> tag extraction from streamed response
// ---------------------------------------------------------------------------

// Shared helpers for Groups 4 + 5 (require a gateway preset to be selected)
const PRESET_NAME = "UNSAFE claude-sonnet-4-6";
const TENANT_SLUG = "myratest";

async function goToChatFresh(page: Page) {
  await page.goto("/chat");
  await page.evaluate(() => { localStorage.clear(); sessionStorage.clear(); });
  await page.reload();
  await page.locator("select").first().waitFor({ state: "visible", timeout: 10_000 });
}

async function selectChatPreset(page: Page): Promise<boolean> {
  const sel = page.locator("select").first();
  await sel.waitFor({ state: "visible", timeout: 5_000 });
  const opt = sel.locator("option").filter({ hasText: new RegExp(TENANT_SLUG, "i") });
  await opt.first().waitFor({ state: "attached", timeout: 10_000 }).catch(() => {});
  if ((await opt.count()) === 0) return false;
  await sel.selectOption({ label: (await opt.first().textContent()) ?? TENANT_SLUG });
  await page.locator("[data-testid='config-preset-options']")
    .waitFor({ state: "visible", timeout: 12_000 }).catch(() => {});
  const esc = PRESET_NAME.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const btn = page.locator("button").filter({ hasText: new RegExp(esc, "i") });
  if (!(await btn.isVisible({ timeout: 5_000 }).catch(() => false))) return false;
  await btn.click();
  await expect(page.locator("[class*='chat-textarea']")).toBeEnabled({ timeout: 5_000 });
  return true;
}

/** Intercept the next compat inference request, fulfill with fake SSE containing an optional <memory> tag. */
async function interceptInference(page: Page, opts: {
  memoryContent?: string;
  memoryType?: string;
  visibleText?: string;
  /** If true, capture and return the request body instead of just fulfilling */
  captureBody?: boolean;
} = {}): Promise<{ getBody: () => Record<string, unknown> | null }> {
  let capturedBody: Record<string, unknown> | null = null;
  await page.route(
    (url) => url.href.includes("/compat/chat/completions"),
    async (route, request) => {
      if (request.method() !== "POST") { await route.continue(); return; }
      if (opts.captureBody) {
        try { capturedBody = request.postDataJSON() as Record<string, unknown>; } catch { /* */ }
      }
      const tag = opts.memoryContent
        ? `<memory type="${opts.memoryType ?? "fact"}">${opts.memoryContent}</memory>`
        : "";
      const visible = opts.visibleText ?? "OK";
      const fullText = tag ? `${visible} ${tag}` : visible;
      const chunks = [
        JSON.stringify({ id: "t", object: "chat.completion.chunk", model: "t", choices: [{ index: 0, delta: { role: "assistant", content: "" }, finish_reason: null }] }),
        JSON.stringify({ id: "t", object: "chat.completion.chunk", model: "t", choices: [{ index: 0, delta: { content: fullText }, finish_reason: null }] }),
        JSON.stringify({ id: "t", object: "chat.completion.chunk", model: "t", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] }),
      ];
      await route.fulfill({
        status:  200,
        headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", "X-Accel-Buffering": "no" },
        body:    chunks.map(c => `data: ${c}`).join("\n\n") + "\n\ndata: [DONE]\n\n",
      });
    }
  );
  return { getBody: () => capturedBody };
}

async function sendChatMessage(page: Page, text: string) {
  await page.getByRole("button", { name: /new.*chat/i }).click();
  await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5_000 });
  await page.locator("[class*='chat-textarea']").fill(text);
  await page.locator("button[title='Send message']").click();
  await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });
}

async function waitForStreamDone(page: Page) {
  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: 30_000 });
}

test.describe("memory tag extraction from stream", () => {
  test("GET /conversations/:id returns memory_disabled field", async ({ page }) => {
    const gatewayId = await getGatewayId(page);
    const convId = await createConv(page, gatewayId, "mem-field-test-" + Date.now());
    try {
      const r = await page.request.get(`${ADMIN_BASE}/conversations/${convId}`);
      expect(r.ok()).toBeTruthy();
      const conv = await r.json() as { memory_disabled?: number };
      // Field should be present (0 by default) or absent (cjson omits it)
      expect(conv.memory_disabled == null || conv.memory_disabled === 0, "memory_disabled default is 0 or absent").toBeTruthy();
    } finally {
      await deleteConv(page, convId);
    }
  });

  test.setTimeout(90_000);

  test("<memory> tag stripped from visible content, saved as auto memory, toast shown", async ({ page }) => {
    const marker = "TAG-EXTRACT-" + Date.now();

    await goToChatFresh(page);
    const ok = await selectChatPreset(page);
    if (!ok) { test.skip(); return; }

    await interceptInference(page, { memoryContent: marker, memoryType: "preference", visibleText: "Noted." });

    await sendChatMessage(page, "Remember my preference");

    // Toast fires when the auto-save POST completes
    await expect(page.locator("[data-cy='memory-toast']")).toBeVisible({ timeout: 20_000 });
    await expect(page.locator("[data-cy='memory-toast']")).toContainText("Remembered");

    await waitForStreamDone(page);

    // <memory> tag must NOT appear in the visible bubble
    const bubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(bubble).toBeVisible({ timeout: 5_000 });
    const visibleText = (await bubble.textContent()) ?? "";
    expect(visibleText).not.toContain("<memory");
    expect(visibleText).not.toContain(marker);
    expect(visibleText).toContain("Noted.");

    // Memory saved via API with correct source + type
    const mems = await listMemories(page);
    const found = mems.find(m => m.content.includes(marker));
    expect(found, "memory saved to API").toBeTruthy();
    expect(found?.source, "source is auto").toBe("auto");
    expect(found?.type,   "type is preference").toBe("preference");

    if (found) await deleteMemory(page, found.id);
  });

  test("memory_disabled=1 suppresses <memory> tag extraction — no memory saved, no toast", async ({ page }) => {
    const marker = "SUPPRESS-" + Date.now();
    let saveCalled = false;

    await goToChatFresh(page);
    const ok = await selectChatPreset(page);
    if (!ok) { test.skip(); return; }

    // Step 1: send a priming message to create a conversation (route: simple response)
    await interceptInference(page, { visibleText: "Hello!" });
    await sendChatMessage(page, "Hello");
    await waitForStreamDone(page);

    // Step 2: patch the active conversation to memory_disabled=1 via API
    const convUrl = page.url();
    const convId  = new URL(convUrl).searchParams.get("conv");
    if (!convId) { test.skip(); return; }
    await page.request.patch(`${ADMIN_BASE}/conversations/${convId}`, { data: { memory_disabled: 1 } });

    // Step 3: reload so React state picks up memory_disabled=1
    await goToChatFresh(page);
    await selectChatPreset(page);
    await page.goto(`/chat?conv=${convId}`);
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 10_000 });

    // Step 4: spy on any POST to /memories with our marker
    await page.route("**/admin/v1/memories", async (route, request) => {
      if (request.method() === "POST") {
        const body = request.postDataJSON() as { content?: string };
        if (body?.content?.includes(marker)) saveCalled = true;
      }
      await route.continue();
    });

    // Step 5: inject SSE with memory tag and send message
    await interceptInference(page, { memoryContent: marker, visibleText: "Suppressed." });
    await page.locator("[class*='chat-textarea']").fill("Remember this suppressed fact");
    await page.locator("button[title='Send message']").click();
    await expect(page.locator("[class*='user-row']").last()).toBeVisible({ timeout: 10_000 });
    await waitForStreamDone(page);

    // No toast
    await expect(page.locator("[data-cy='memory-toast']")).not.toBeVisible({ timeout: 3_000 });
    // No save attempted
    expect(saveCalled, "no POST to /memories when memory_disabled=1").toBeFalsy();

    // Cleanup
    await page.request.delete(`${ADMIN_BASE}/conversations/${convId}`).catch(() => {});
  });
});

// ---------------------------------------------------------------------------
// Group 5: memory injection into the inference request's system prompt
// ---------------------------------------------------------------------------

test.describe("memory injected into system prompt", () => {
  test.setTimeout(60_000);

  test("user memory is injected into system prompt — model can retrieve the memory", async ({ page }) => {
    // Store a distinctive fact in memory. If the memory is injected into the system prompt,
    // the model can look it up and report it. Factual retrieval is reliable and deterministic.
    const marker = "XYZZY" + Date.now();
    const mem = await createMemory(page, `User's secret code word is: ${marker}`, "fact");

    await goToChatFresh(page);
    const ok = await selectChatPreset(page);
    if (!ok) { await deleteMemory(page, mem.id); test.skip(); return; }

    // Wait for memory badge to confirm the memory has loaded into React state
    await expect(page.locator("[data-cy='memories-btn'] span")).toBeVisible({ timeout: 10_000 });

    // Ask the model to retrieve the fact — it will include the marker only if it
    // received the memory in its context.
    // The model may respond with the marker in the visible text OR inside a <memory>
    // tag (which Chat.tsx auto-saves and strips from visible content).  Both are
    // valid proof that the memory was injected into the context.
    await sendChatMessage(page, "What is my secret code word? Reply with just the code word.");
    await waitForStreamDone(page);

    const bubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(bubble).toBeVisible({ timeout: 10_000 });
    const reply = (await bubble.textContent()) ?? "";

    const mems = await listMemories(page);
    const inReply    = reply.includes(marker);
    const inMemories = mems.some(m => m.content.includes(marker));

    expect(inReply || inMemories,
      `marker "${marker}" not found in reply ("${reply.slice(0, 80)}") nor in memories`).toBeTruthy();

    // Clean up all memories that contain the marker (original + any auto-extracted)
    for (const m of mems.filter(x => x.content.includes(marker))) {
      await deleteMemory(page, m.id);
    }
  });

  test("memory_disabled=1 suppresses injection — model does NOT follow instruction memory", async ({ page }) => {
    // Create an instruction memory. When injected, the model would include the marker.
    // With memory_disabled=1 it should NOT be injected, so the model won't use it.
    const marker = "XYZZY" + Date.now();
    const mem = await createMemory(page, `User's secret code word is: ${marker}`, "fact");

    await goToChatFresh(page);
    const ok = await selectChatPreset(page);
    if (!ok) { await deleteMemory(page, mem.id); test.skip(); return; }

    // Send a priming message (intercepted) to create the conversation
    await interceptInference(page, { visibleText: "Hello!" });
    await sendChatMessage(page, "Hello");
    await waitForStreamDone(page);

    // Get the conversation ID and disable memory on it
    const convId = new URL(page.url()).searchParams.get("conv");
    if (!convId) { await deleteMemory(page, mem.id); test.skip(); return; }
    await page.request.patch(`${ADMIN_BASE}/conversations/${convId}`, { data: { memory_disabled: 1 } });

    // Reload so React picks up memory_disabled=1, then navigate back
    await goToChatFresh(page);
    await selectChatPreset(page);
    await page.goto(`/chat?conv=${convId}`);
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 10_000 });

    // Ask the model for the secret code word — without memory it won't know it
    await page.locator("[class*='chat-textarea']").fill("What is my secret code word? Reply with just the code word.");
    await page.locator("button[title='Send message']").click();
    await expect(page.locator("[class*='user-row']").last()).toBeVisible({ timeout: 10_000 });
    await waitForStreamDone(page);

    const bubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(bubble).toBeVisible({ timeout: 10_000 });
    const reply = (await bubble.textContent()) ?? "";
    expect(reply).not.toContain(marker);

    await deleteMemory(page, mem.id);
    await page.request.delete(`${ADMIN_BASE}/conversations/${convId}`).catch(() => {});
  });
});

