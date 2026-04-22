/**
 * chat-memory-scope.spec.ts — E2E tests for project-scoped memory isolation.
 *
 * Coverage:
 *   Group 1 — API: scope isolation (global vs project), membership guards
 *   Group 2 — UI: MemoriesPanel title changes with scope
 *   Group 3 — UI: manual add from panel saves to correct scope
 *   Group 4 — UI: auto-extraction writes to correct scope (route injection)
 *   Group 5 — Cascade: deleting a project removes its memories
 */

import { test, expect, type Page } from "@playwright/test";

const ADMIN_BASE    = `${process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173"}/admin/v1`;
const TENANT_SLUG   = "myratest";
const TARGET_PRESET = "UNSAFE claude-sonnet-4-6";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface MemRow  { id: string; content: string; type: string; source: string; project_id?: string }
interface ConvRow { id: string; }
interface ProjRow { id: string; }
interface TenantRow { id: string; slug: string; }
interface GatewayRow { id: string; slug: string; config?: Record<string, unknown> }

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function getTenantId(page: Page): Promise<string> {
  const r = await page.request.get(`${ADMIN_BASE}/tenants`);
  expect(r.ok(), "tenants ok").toBeTruthy();
  const tenants = await r.json() as TenantRow[];
  return tenants.find(t => t.slug === TENANT_SLUG)?.id ?? tenants[0].id;
}

async function createProject(page: Page, tenantId: string, name: string): Promise<string> {
  const r = await page.request.post(`${ADMIN_BASE}/projects`, { data: { name, tenant_id: tenantId } });
  expect(r.ok(), `createProject: ${await r.text()}`).toBeTruthy();
  return (await r.json() as ProjRow).id;
}

async function deleteProject(page: Page, id: string) {
  await page.request.delete(`${ADMIN_BASE}/projects/${id}`).catch(() => {});
}

async function createGlobalMemory(page: Page, content: string, type = "fact"): Promise<MemRow> {
  const r = await page.request.post(`${ADMIN_BASE}/memories`, { data: { content, type, source: "manual" } });
  expect(r.ok(), `createGlobalMemory: ${await r.text()}`).toBeTruthy();
  return r.json();
}

async function createProjectMemory(page: Page, projectId: string, content: string, type = "fact"): Promise<MemRow> {
  const r = await page.request.post(`${ADMIN_BASE}/memories`, {
    data: { content, type, source: "manual", project_id: projectId },
  });
  expect(r.ok(), `createProjectMemory: ${await r.text()}`).toBeTruthy();
  return r.json();
}

async function deleteMemory(page: Page, id: string) {
  await page.request.delete(`${ADMIN_BASE}/memories/${id}`).catch(() => {});
}

async function listGlobalMemories(page: Page): Promise<MemRow[]> {
  const r = await page.request.get(`${ADMIN_BASE}/memories`);
  expect(r.ok(), "listGlobalMemories ok").toBeTruthy();
  return r.json();
}

async function listProjectMemories(page: Page, projectId: string): Promise<MemRow[]> {
  const r = await page.request.get(`${ADMIN_BASE}/memories?project_id=${projectId}`);
  expect(r.ok(), "listProjectMemories ok").toBeTruthy();
  return r.json();
}

/** Navigate to /chat, clear storage, wait for tenant selector. */
async function goToChat(page: Page, projectId?: string) {
  await page.goto("/chat");
  await page.evaluate(() => { localStorage.clear(); sessionStorage.clear(); });
  if (projectId) {
    await page.goto(`/chat?project_id=${projectId}`);
  } else {
    await page.reload();
  }
  await page.locator("select").first().waitFor({ state: "visible", timeout: 10_000 });
}

/** Select tenant and click preset button. */
async function selectPreset(page: Page, presetName: string): Promise<boolean> {
  const sel = page.locator("select").first();
  await sel.waitFor({ state: "visible", timeout: 5_000 });
  const opt = sel.locator("option").filter({ hasText: new RegExp(TENANT_SLUG, "i") });
  await opt.first().waitFor({ state: "attached", timeout: 10_000 }).catch(() => {});
  if ((await opt.count()) === 0) return false;
  await sel.selectOption({ label: (await opt.first().textContent()) ?? TENANT_SLUG });
  await page.locator("[data-testid='config-preset-options']")
    .waitFor({ state: "visible", timeout: 12_000 }).catch(() => {});
  const esc = presetName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const btn = page.locator("button").filter({ hasText: new RegExp(esc, "i") });
  if (!(await btn.isVisible({ timeout: 5_000 }).catch(() => false))) return false;
  await btn.click();
  await expect(page.locator("[class*='chat-textarea']")).toBeEnabled({ timeout: 5_000 });
  return true;
}

/**
 * Intercept the next gateway inference SSE call and inject a fake streaming
 * response containing a <memory> tag with the given content.
 * Uses page.route — the intercept fires once then auto-removes.
 */
async function injectMemoryTag(page: Page, content: string, type = "fact") {
  await page.route("**/compat/chat/completions", async (route, request) => {
    if (request.method() !== "POST") { await route.continue(); return; }
    const tag = `<memory type="${type}">${content}</memory>`;
    const body = [
      `data: ${JSON.stringify({ id: "test", object: "chat.completion.chunk", model: "test", choices: [{ index: 0, delta: { role: "assistant", content: "" }, finish_reason: null }] })}`,
      `data: ${JSON.stringify({ id: "test", object: "chat.completion.chunk", model: "test", choices: [{ index: 0, delta: { content: `I noted that. ${tag}` }, finish_reason: null }] })}`,
      `data: ${JSON.stringify({ id: "test", object: "chat.completion.chunk", model: "test", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}`,
      "data: [DONE]",
      "",
    ].join("\n\n");
    await route.fulfill({
      status:  200,
      headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", "X-Accel-Buffering": "no" },
      body,
    });
  });
}

// ---------------------------------------------------------------------------
// Group 1: API isolation
// ---------------------------------------------------------------------------

test.describe("Memory scope — API isolation", () => {
  let globalMem: MemRow;
  let projId: string;
  let projMem: MemRow;
  let tenantId: string;

  test.beforeAll(async ({ browser }) => {
    const ctx  = await browser.newContext({ storageState: "tests/.auth/docker-session.json" });
    const page = await ctx.newPage();
    tenantId = await getTenantId(page);
    projId   = await createProject(page, tenantId, "scope-api-test-" + Date.now());
    globalMem = await createGlobalMemory(page, "global-fact-" + Date.now());
    projMem   = await createProjectMemory(page, projId, "project-fact-" + Date.now());
    await page.close(); await ctx.close();
  });

  test.afterAll(async ({ browser }) => {
    const ctx  = await browser.newContext({ storageState: "tests/.auth/docker-session.json" });
    const page = await ctx.newPage();
    await deleteMemory(page, globalMem.id);
    await deleteProject(page, projId);  // cascade-deletes projMem
    await page.close(); await ctx.close();
  });

  test("GET /memories returns global memories only (project_id absent)", async ({ page }) => {
    const mems = await listGlobalMemories(page);
    // Our global memory is present
    expect(mems.some(m => m.id === globalMem.id)).toBeTruthy();
    // Our project memory is absent from global pool
    expect(mems.some(m => m.id === projMem.id)).toBeFalsy();
    // All returned rows have no project_id field
    const withProjectId = mems.filter(m => m.project_id != null && m.project_id !== undefined);
    expect(withProjectId.length, "no project-scoped rows in global GET").toBe(0);
  });

  test("GET /memories?project_id=X returns only project memories", async ({ page }) => {
    const mems = await listProjectMemories(page, projId);
    expect(mems.some(m => m.id === projMem.id)).toBeTruthy();
    expect(mems.some(m => m.id === globalMem.id)).toBeFalsy();
    for (const m of mems) {
      expect(m.project_id, "all rows have correct project_id").toBe(projId);
    }
  });

  test("POST /memories without project_id creates global memory absent from project GET", async ({ page }) => {
    const content = "isolation-test-global-" + Date.now();
    const m = await createGlobalMemory(page, content);
    try {
      // Appears in global GET
      const global = await listGlobalMemories(page);
      expect(global.some(x => x.id === m.id)).toBeTruthy();
      // Absent from project GET
      const proj = await listProjectMemories(page, projId);
      expect(proj.some(x => x.id === m.id)).toBeFalsy();
    } finally {
      await deleteMemory(page, m.id);
    }
  });

  test("POST /memories with project_id creates project memory absent from global GET", async ({ page }) => {
    const content = "isolation-test-proj-" + Date.now();
    const m = await createProjectMemory(page, projId, content);
    try {
      expect(m.project_id, "returned memory has project_id").toBe(projId);
      // Absent from global GET
      const global = await listGlobalMemories(page);
      expect(global.some(x => x.id === m.id)).toBeFalsy();
      // Present in project GET
      const proj = await listProjectMemories(page, projId);
      expect(proj.some(x => x.id === m.id)).toBeTruthy();
    } finally {
      // Project cleanup handles this
    }
  });

  test("GET /memories?project_id= with non-existent project returns 200 empty for admins", async ({ page }) => {
    // Admin users bypass the membership guard and get 200 with empty array for unknown projects
    const fakeId = "00000000-0000-0000-0000-000000000000";
    const r = await page.request.get(`${ADMIN_BASE}/memories?project_id=${fakeId}`);
    expect(r.status()).toBe(200);
    const body = await r.json();
    expect(Array.isArray(body)).toBeTruthy();
    // Our project memory from setUp should NOT appear here
    expect((body as MemRow[]).some(m => m.id === projMem.id)).toBeFalsy();
  });

  test("POST /memories with non-existent project_id returns 404", async ({ page }) => {
    // Project does not exist → storage layer returns 404 before hitting FK constraint
    const fakeId = "00000000-0000-0000-0000-000000000000";
    const r = await page.request.post(`${ADMIN_BASE}/memories`, {
      data: { content: "should fail", type: "fact", source: "manual", project_id: fakeId },
    });
    expect(r.status()).toBe(404);
  });
});

// ---------------------------------------------------------------------------
// Group 2: UI — MemoriesPanel title changes with scope
// ---------------------------------------------------------------------------

test.describe("Memory scope — MemoriesPanel title", () => {
  let tenantId: string;
  let projId: string;
  let t0: number;

  test.beforeAll(async ({ browser }) => {
    const ctx  = await browser.newContext({ storageState: "tests/.auth/docker-session.json" });
    const page = await ctx.newPage();
    tenantId = await getTenantId(page);
    projId   = await createProject(page, tenantId, "scope-panel-title-" + Date.now());
    await page.close(); await ctx.close();
  });

  test.afterAll(async ({ browser }) => {
    const ctx  = await browser.newContext({ storageState: "tests/.auth/docker-session.json" });
    const page = await ctx.newPage();
    await deleteProject(page, projId);
    await page.close(); await ctx.close();
  });

  test.beforeEach(({ }) => { t0 = Date.now(); });
  test.setTimeout(60_000);

  test("standalone chat shows panel title 'Memories'", async ({ page }) => {
    await goToChat(page);
    const ok = await selectPreset(page, TARGET_PRESET);
    if (!ok) { test.skip(); return; }
    await page.locator("[data-cy='memories-btn']").click();
    await expect(page.locator("[data-cy='memories-panel']")).toBeVisible({ timeout: 5_000 });
    await expect(page.locator("[data-cy='memories-panel']")).toContainText("Memories");
    await expect(page.locator("[data-cy='memories-panel']")).not.toContainText("Project Memories");
  });

  test("project chat shows panel title 'Project Memories'", async ({ page }) => {
    await goToChat(page, projId);
    const ok = await selectPreset(page, TARGET_PRESET);
    if (!ok) { test.skip(); return; }
    await page.locator("[data-cy='memories-btn']").click();
    await expect(page.locator("[data-cy='memories-panel']")).toBeVisible({ timeout: 5_000 });
    await expect(page.locator("[data-cy='memories-panel']")).toContainText("Project Memories");
  });

  test("switching from standalone to project reloads memory pool", async ({ page }) => {
    // Create one global and one project memory
    const globalContent = "global-reload-test-" + Date.now();
    const projContent   = "project-reload-test-" + Date.now();
    const gm = await createGlobalMemory(page, globalContent);
    const pm = await createProjectMemory(page, projId, projContent);
    try {
      // Load standalone
      await goToChat(page);
      const ok = await selectPreset(page, TARGET_PRESET);
      if (!ok) { test.skip(); return; }
      await page.locator("[data-cy='memories-btn']").click();
      await expect(page.locator("[data-cy='memories-panel']")).toBeVisible({ timeout: 5_000 });
      // Global memory visible in standalone panel
      await expect(page.locator("[data-cy='memories-panel']")).toContainText(globalContent, { timeout: 5_000 });
      // Project memory not in standalone panel
      await expect(page.locator("[data-cy='memories-panel']")).not.toContainText(projContent);
      await page.locator("[data-cy='memories-panel'] button[title='Close']").click().catch(() =>
        page.keyboard.press("Escape")
      );

      // Navigate to project
      await goToChat(page, projId);
      await selectPreset(page, TARGET_PRESET);
      await page.locator("[data-cy='memories-btn']").click();
      await expect(page.locator("[data-cy='memories-panel']")).toBeVisible({ timeout: 5_000 });
      // Project memory visible in project panel
      await expect(page.locator("[data-cy='memories-panel']")).toContainText(projContent, { timeout: 5_000 });
      // Global memory not in project panel
      await expect(page.locator("[data-cy='memories-panel']")).not.toContainText(globalContent);
    } finally {
      await deleteMemory(page, gm.id);
      // pm deleted with project in afterAll
      await deleteMemory(page, pm.id).catch(() => {});
    }
  });
});

// ---------------------------------------------------------------------------
// Group 3: UI — manual add from panel uses correct scope
// ---------------------------------------------------------------------------

test.describe("Memory scope — manual add scoping", () => {
  let tenantId: string;
  let projId: string;
  test.setTimeout(60_000);

  test.beforeAll(async ({ browser }) => {
    const ctx  = await browser.newContext({ storageState: "tests/.auth/docker-session.json" });
    const page = await ctx.newPage();
    tenantId = await getTenantId(page);
    projId   = await createProject(page, tenantId, "scope-manual-add-" + Date.now());
    await page.close(); await ctx.close();
  });

  test.afterAll(async ({ browser }) => {
    const ctx  = await browser.newContext({ storageState: "tests/.auth/docker-session.json" });
    const page = await ctx.newPage();
    await deleteProject(page, projId);
    await page.close(); await ctx.close();
  });

  test("adding memory in project context saves with correct project_id", async ({ page }) => {
    await goToChat(page, projId);
    const ok = await selectPreset(page, TARGET_PRESET);
    if (!ok) { test.skip(); return; }
    await page.locator("[data-cy='memories-btn']").click();
    await expect(page.locator("[data-cy='memories-panel']")).toBeVisible({ timeout: 5_000 });

    const content = "manual-proj-" + Date.now();
    await page.locator("[data-cy='memory-add-input']").fill(content);
    await page.locator("[data-cy='memory-add-btn']").click();
    await expect(page.locator("[data-cy='memories-panel']")).toContainText(content, { timeout: 5_000 });

    // Verify via API: appears in project scope, not global
    const projMems   = await listProjectMemories(page, projId);
    const globalMems = await listGlobalMemories(page);
    expect(projMems.some(m => m.content.includes(content)),   "in project scope").toBeTruthy();
    expect(globalMems.some(m => m.content.includes(content)), "not in global scope").toBeFalsy();
  });

  test("adding memory in standalone context saves without project_id", async ({ page }) => {
    await goToChat(page);
    const ok = await selectPreset(page, TARGET_PRESET);
    if (!ok) { test.skip(); return; }
    await page.locator("[data-cy='memories-btn']").click();
    await expect(page.locator("[data-cy='memories-panel']")).toBeVisible({ timeout: 5_000 });

    const content = "manual-global-" + Date.now();
    await page.locator("[data-cy='memory-add-input']").fill(content);
    await page.locator("[data-cy='memory-add-btn']").click();
    await expect(page.locator("[data-cy='memories-panel']")).toContainText(content, { timeout: 5_000 });

    // Verify via API: appears in global scope, not in project
    const globalMems = await listGlobalMemories(page);
    const projMems   = await listProjectMemories(page, projId);
    const found = globalMems.find(m => m.content.includes(content));
    expect(found, "in global scope").toBeTruthy();
    expect(found?.project_id, "no project_id on global memory").toBeUndefined();
    expect(projMems.some(m => m.content.includes(content)), "not in project scope").toBeFalsy();

    // Clean up
    if (found) await deleteMemory(page, found.id);
  });
});

// ---------------------------------------------------------------------------
// Group 4: UI — auto-extraction writes to correct scope (route injection)
// ---------------------------------------------------------------------------

test.describe("Memory scope — auto-extraction scoping", () => {
  let tenantId: string;
  let projId: string;
  test.setTimeout(90_000);

  test.beforeAll(async ({ browser }) => {
    const ctx  = await browser.newContext({ storageState: "tests/.auth/docker-session.json" });
    const page = await ctx.newPage();
    tenantId = await getTenantId(page);
    projId   = await createProject(page, tenantId, "scope-auto-extract-" + Date.now());
    await page.close(); await ctx.close();
  });

  test.afterAll(async ({ browser }) => {
    const ctx  = await browser.newContext({ storageState: "tests/.auth/docker-session.json" });
    const page = await ctx.newPage();
    await deleteProject(page, projId);
    await page.close(); await ctx.close();
  });

  test("auto-extracted memory in project chat is project-scoped", async ({ page }) => {
    const marker = "AUTO-PROJ-" + Date.now();
    await injectMemoryTag(page, `Team uses ${marker}`);

    await goToChat(page, projId);
    const ok = await selectPreset(page, TARGET_PRESET);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new.*chat/i }).click();
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5_000 });
    await page.locator("[class*='chat-textarea']").fill("Remember: team likes TypeScript");
    await page.locator("button[title='Send message']").click();

    // Wait for the memory toast — it fires when the auto-save POST completes
    await expect(page.locator("[data-cy='memory-toast']")).toBeVisible({ timeout: 30_000 });

    // Verify via API: memory is in project scope
    const projMems   = await listProjectMemories(page, projId);
    const globalMems = await listGlobalMemories(page);
    expect(projMems.some(m => m.content.includes(marker)),   "in project scope").toBeTruthy();
    expect(globalMems.some(m => m.content.includes(marker)), "not in global scope").toBeFalsy();
  });

  test("auto-extracted memory in standalone chat is global", async ({ page }) => {
    const marker = "AUTO-GLOBAL-" + Date.now();
    await injectMemoryTag(page, `User likes ${marker}`);

    await goToChat(page);
    const ok = await selectPreset(page, TARGET_PRESET);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5_000 });
    await page.locator("[class*='chat-textarea']").fill("Remember: I like dark mode");
    await page.locator("button[title='Send message']").click();

    // Wait for the memory toast — it fires when the auto-save POST completes
    await expect(page.locator("[data-cy='memory-toast']")).toBeVisible({ timeout: 30_000 });

    const globalMems = await listGlobalMemories(page);
    const projMems   = await listProjectMemories(page, projId);
    const found = globalMems.find(m => m.content.includes(marker));
    expect(found, "in global scope").toBeTruthy();
    expect(found?.project_id, "no project_id").toBeUndefined();
    expect(projMems.some(m => m.content.includes(marker)), "not in project scope").toBeFalsy();

    if (found) await deleteMemory(page, found.id);
  });
});

// ---------------------------------------------------------------------------
// Group 5: Cascade — deleting a project removes its memories
// ---------------------------------------------------------------------------

test.describe("Memory scope — project delete cascade", () => {
  test("deleting a project hard-deletes its scoped memories", async ({ page }) => {
    const tenantId = await getTenantId(page);
    const pid      = await createProject(page, tenantId, "scope-cascade-test-" + Date.now());
    const m        = await createProjectMemory(page, pid, "should be deleted " + Date.now());

    // Confirm memory exists before deletion
    const before = await listProjectMemories(page, pid);
    expect(before.some(x => x.id === m.id)).toBeTruthy();

    // Delete the project — this calls delete_project() which hard-deletes project memories
    await deleteProject(page, pid);

    // After project deletion, project memories are hard-deleted.
    // The user may still be a member so the API returns 200, but the array must be empty.
    const r = await page.request.get(`${ADMIN_BASE}/memories?project_id=${pid}`);
    if (r.status() === 200) {
      const after = await r.json() as MemRow[];
      expect(after.some(x => x.id === m.id), "memory was hard-deleted").toBeFalsy();
    } else {
      // 403 or 404 also acceptable (membership was removed or project gone)
      expect([403, 404]).toContain(r.status());
    }
  });
});
