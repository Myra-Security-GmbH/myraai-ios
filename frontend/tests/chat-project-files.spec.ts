/**
 * chat-project-files.spec.ts — E2E tests for the "Save to Project" file feature.
 *
 * The feature lets the model output a code block whose first line is a filename
 * comment (e.g. `# utils.py`). A "Save to Project" card is rendered below the
 * block. Clicking Save:
 *   1. Upserts the file into the project knowledge base (PUT /projects/:id/knowledge/:filename)
 *   2. Injects a synthetic user message into the conversation so the model's
 *      context reflects the updated file content.
 *
 * Coverage:
 *   1. Save card appears in project chat when assistant message has filename comment
 *   2. Save card absent in non-project chat (same code block format)
 *   3. Clicking Save → card shows ✓ Saved
 *   4. File appears in project knowledge base after save
 *   5. Context injection message appears in thread after save
 *   6. Upsert: saving same filename again updates token_count, no duplicate row
 */

import { test, expect, type Page } from "@playwright/test";

const ADMIN_BASE = "http://localhost:5173/admin/v1";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface TenantRow   { id: string; slug: string }
interface GatewayRow  { id: string; slug: string }
interface ProjectRow  { id: string; name: string }
interface ConvRow     { id: string; title: string }
interface Knowledge   { id: string; filename: string; token_count: number }

// ---------------------------------------------------------------------------
// Helpers — all use page.context().request so the test session auth is used
// ---------------------------------------------------------------------------

async function getFirstTenantAndGateway(page: Page): Promise<{ tenantId: string; gatewayId: string }> {
  const tr = await page.context().request.get(`${ADMIN_BASE}/tenants`);
  expect(tr.ok(), "GET /tenants").toBeTruthy();
  const tenants = await tr.json() as TenantRow[];
  expect(tenants.length, "at least one tenant").toBeGreaterThan(0);
  const tenantId = tenants[0].id;

  const gr = await page.context().request.get(`${ADMIN_BASE}/tenants/${tenantId}/gateways`);
  expect(gr.ok(), "GET /gateways").toBeTruthy();
  const gateways = await gr.json() as GatewayRow[];
  expect(gateways.length, "at least one gateway").toBeGreaterThan(0);

  return { tenantId, gatewayId: gateways[0].id };
}

async function createProject(page: Page, tenantId: string, name: string): Promise<string> {
  const r = await page.context().request.post(`${ADMIN_BASE}/projects`, {
    data: { name, icon: "📁", color: "#2563eb", tenant_id: tenantId },
  });
  expect(r.ok(), `create project: ${await r.text()}`).toBeTruthy();
  return ((await r.json()) as ProjectRow).id;
}

async function deleteProject(page: Page, id: string) {
  await page.context().request.delete(`${ADMIN_BASE}/projects/${id}`).catch(() => {});
}

async function createConversation(page: Page, gatewayId: string, projectId?: string): Promise<string> {
  const data: Record<string, unknown> = { gateway_id: gatewayId, title: "test conv" };
  if (projectId) data.project_id = projectId;
  const r = await page.context().request.post(`${ADMIN_BASE}/conversations`, { data });
  expect(r.ok(), `create conversation: ${await r.text()}`).toBeTruthy();
  return ((await r.json()) as ConvRow).id;
}

async function deleteConversation(page: Page, id: string) {
  await page.context().request.delete(`${ADMIN_BASE}/conversations/${id}`).catch(() => {});
}

/** Append a pre-crafted assistant message (no inference) via the messages API. */
async function appendAssistantMessage(page: Page, convId: string, content: string): Promise<string> {
  const r = await page.context().request.post(`${ADMIN_BASE}/conversations/${convId}/messages`, {
    data: { role: "assistant", content },
  });
  expect(r.ok(), `append assistant message: ${await r.text()}`).toBeTruthy();
  return ((await r.json()) as { id: string }).id;
}

async function listKnowledge(page: Page, projectId: string): Promise<Knowledge[]> {
  const r = await page.context().request.get(`${ADMIN_BASE}/projects/${projectId}/knowledge`);
  expect(r.ok(), "GET /knowledge").toBeTruthy();
  return r.json() as Promise<Knowledge[]>;
}

async function deleteKnowledgeEntry(page: Page, projectId: string, entryId: string) {
  await page.context().request.delete(`${ADMIN_BASE}/projects/${projectId}/knowledge/${entryId}`).catch(() => {});
}

async function setChatPreferences(page: Page, gatewayId: string, tenantId: string) {
  if (page.url() === "about:blank" || page.url() === "") {
    await page.goto("/dashboard");
  }
  await page.evaluate(({ g, t }) => {
    localStorage.setItem("aig-chat-gateway", g);
    localStorage.setItem("aig-chat-tenant", t);
  }, { g: gatewayId, t: tenantId });
}

/** Build the assistant message content that mimics model output with a filename comment. */
function makeAssistantMsg(filename: string, ext: string, code: string): string {
  const comment = ext === "py" ? "#" : ext === "sql" ? "--" : "//";
  return `Here is the file:\n\n\`\`\`${ext}\n${comment} ${filename}\n${code}\n\`\`\``;
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

test.describe("Chat — Save to Project file feature", () => {

  // ── 1. Save card visible in project chat ─────────────────────────────────

  test("Save to Project card appears for filename-comment code block in project chat", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `test-save-files-${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    try {
      await appendAssistantMessage(page, convId, makeAssistantMsg("reverse.py", "py", "def reverse(s):\n    return s[::-1]"));

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);

      await expect(page.getByText("reverse.py").first()).toBeVisible({ timeout: 10000 });
      await expect(page.getByRole("button", { name: "Save to Project" })).toBeVisible({ timeout: 5000 });
      await expect(page.getByText(/save failed/i)).not.toBeVisible();
    } finally {
      await deleteConversation(page, convId);
      await deleteProject(page, projectId);
    }
  });

  // ── 2. Save card absent outside project chat ──────────────────────────────

  test("Save to Project card is absent in non-project chat", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const convId = await createConversation(page, gatewayId);
    try {
      await appendAssistantMessage(page, convId, makeAssistantMsg("reverse.py", "py", "def reverse(s):\n    return s[::-1]"));

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}`);

      await expect(page.getByText("reverse.py").first()).toBeVisible({ timeout: 10000 });
      await expect(page.getByRole("button", { name: "Save to Project" })).not.toBeVisible();
    } finally {
      await deleteConversation(page, convId);
    }
  });

  // ── 3. Clicking Save shows ✓ Saved ────────────────────────────────────────

  test("clicking Save to Project shows Saved confirmation", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `test-save-confirm-${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    try {
      await appendAssistantMessage(page, convId, makeAssistantMsg("users.sql", "sql", "SELECT id, name FROM users;"));

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);

      await expect(page.getByRole("button", { name: "Save to Project" })).toBeVisible({ timeout: 10000 });
      await page.getByRole("button", { name: "Save to Project" }).click();

      await expect(page.getByText("✓ Saved")).toBeVisible({ timeout: 8000 });
      await expect(page.getByText(/save failed/i)).not.toBeVisible();
    } finally {
      await deleteConversation(page, convId);
      const rows = await listKnowledge(page, projectId);
      for (const r of rows) await deleteKnowledgeEntry(page, projectId, r.id);
      await deleteProject(page, projectId);
    }
  });

  // ── 4. File appears in knowledge base after save ──────────────────────────

  test("saved file appears in project knowledge base", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `test-kb-${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    const filename = `greet-${Date.now()}.py`;
    try {
      await appendAssistantMessage(page, convId, makeAssistantMsg(filename, "py", "def greet(name):\n    return f'Hello, {name}!'"));

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);

      await expect(page.getByRole("button", { name: "Save to Project" })).toBeVisible({ timeout: 10000 });
      await page.getByRole("button", { name: "Save to Project" }).click();
      await expect(page.getByText("✓ Saved")).toBeVisible({ timeout: 8000 });

      const rows = await listKnowledge(page, projectId);
      const entry = rows.find(r => r.filename === filename);
      expect(entry, `${filename} must be in knowledge base`).toBeTruthy();
      expect(entry!.token_count, "token_count > 0").toBeGreaterThan(0);
    } finally {
      await deleteConversation(page, convId);
      const rows = await listKnowledge(page, projectId);
      for (const r of rows) await deleteKnowledgeEntry(page, projectId, r.id);
      await deleteProject(page, projectId);
    }
  });

  // ── 5. Context injection message appears in thread ────────────────────────

  test("saving a file injects a context-refresh message into the conversation thread", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `test-ctx-${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    const filename = `ctx-${Date.now()}.ts`;
    try {
      await appendAssistantMessage(page, convId, makeAssistantMsg(filename, "ts", "export function add(a: number, b: number) { return a + b; }"));

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);

      await expect(page.getByRole("button", { name: "Save to Project" })).toBeVisible({ timeout: 10000 });
      await page.getByRole("button", { name: "Save to Project" }).click();
      await expect(page.getByText("✓ Saved")).toBeVisible({ timeout: 8000 });

      // Injection message visible in the thread
      await expect(page.getByText(`[File saved to project: ${filename}]`)).toBeVisible({ timeout: 5000 });

      // Also persisted in DB
      const r = await page.context().request.get(`${ADMIN_BASE}/conversations/${convId}`);
      expect(r.ok()).toBeTruthy();
      const conv = await r.json() as { messages?: Array<{ role: string; content: string }> };
      const injected = (conv.messages ?? []).find(m =>
        m.role === "user" && m.content.includes(`[File saved to project: ${filename}]`)
      );
      expect(injected, "injected message persisted in DB").toBeTruthy();
    } finally {
      await deleteConversation(page, convId);
      const rows = await listKnowledge(page, projectId);
      for (const r of rows) await deleteKnowledgeEntry(page, projectId, r.id);
      await deleteProject(page, projectId);
    }
  });

  // ── 6. Upsert: same filename → update, not duplicate ─────────────────────

  test("saving the same filename twice upserts — no duplicate knowledge entry", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `test-upsert-${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    const filename = `upsert-${Date.now()}.py`;
    try {
      // Pre-create the entry via API (simulates a previous save)
      await page.context().request.put(
        `${ADMIN_BASE}/projects/${projectId}/knowledge/${encodeURIComponent(filename)}`,
        { data: { extracted_text: "# short", content_type: "text/x-python", size_bytes: 7 } },
      );

      const rowsBefore = await listKnowledge(page, projectId);
      expect(rowsBefore.filter(r => r.filename === filename).length, "one entry before upsert").toBe(1);
      const tokensBefore = rowsBefore.find(r => r.filename === filename)!.token_count;

      // Now save a longer version via the UI
      const bigCode = "def compute():\n    " + "x = 1\n    ".repeat(20) + "return x";
      await appendAssistantMessage(page, convId, makeAssistantMsg(filename, "py", bigCode));

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);

      await expect(page.getByRole("button", { name: "Save to Project" })).toBeVisible({ timeout: 10000 });
      await page.getByRole("button", { name: "Save to Project" }).click();
      await expect(page.getByText("✓ Saved")).toBeVisible({ timeout: 8000 });

      const rowsAfter = await listKnowledge(page, projectId);
      const entries = rowsAfter.filter(r => r.filename === filename);
      expect(entries.length, "still exactly one entry after upsert").toBe(1);
      expect(entries[0].token_count, "token_count increased after upsert").toBeGreaterThan(tokensBefore);
    } finally {
      await deleteConversation(page, convId);
      const rows = await listKnowledge(page, projectId);
      for (const r of rows) await deleteKnowledgeEntry(page, projectId, r.id);
      await deleteProject(page, projectId);
    }
  });
});
