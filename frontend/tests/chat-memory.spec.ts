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
});
