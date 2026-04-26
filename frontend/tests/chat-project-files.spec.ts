/**
 * chat-project-files.spec.ts — E2E tests for the artifact card + "Save to Project" feature.
 *
 * When a model output contains a code block whose first line is a filename comment
 * (e.g. `# utils.py`), an artifact card is rendered in the chat instead of inline code.
 * Clicking the card opens a side panel. In project context, the panel shows a
 * "Save to Project" button which:
 *   1. Upserts the file into the project knowledge base (PUT /projects/:id/knowledge/:filename)
 *   2. Injects a synthetic user message into the conversation so the model's
 *      context reflects the updated file content.
 *
 * Coverage:
 *   1. Artifact card appears in project chat when assistant message has filename comment
 *   2. Artifact card is visible in non-project chat; panel has no Save button
 *   3. Clicking artifact card opens panel; clicking Save in panel → ✓ Saved
 *   4. File appears in project knowledge base after save
 *   5. Context injection message appears in thread after save
 *   6. Upsert: saving same filename again updates token_count, no duplicate row
 */

import { test, expect, type Page } from "./base";

const ADMIN_BASE = `${process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173"}/admin/v1`;

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

  // ── 1. Artifact card visible in project chat ─────────────────────────────

  test("artifact card appears for filename-comment code block in project chat", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `test-save-files-${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    try {
      await appendAssistantMessage(page, convId, makeAssistantMsg("reverse.py", "py", "def reverse(s):\n    return s[::-1]"));

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);

      // Artifact card must appear with the filename; full code must NOT be shown inline
      await expect(page.locator("[data-cy=artifact-card]")).toBeVisible({ timeout: 10000 });
      await expect(page.getByText("reverse.py").first()).toBeVisible({ timeout: 10000 });
      // "Save to Project" is in the panel, not the thread
      await expect(page.getByRole("button", { name: "Save to Project" })).not.toBeVisible();
    } finally {
      await deleteConversation(page, convId);
      await deleteProject(page, projectId);
    }
  });

  // ── 2. Artifact card visible in non-project chat; no Save button ─────────

  test("artifact card is visible in non-project chat but has no Save button", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const convId = await createConversation(page, gatewayId);
    try {
      await appendAssistantMessage(page, convId, makeAssistantMsg("reverse.py", "py", "def reverse(s):\n    return s[::-1]"));

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}`);

      // Artifact card is always shown for named code blocks
      await expect(page.locator("[data-cy=artifact-card]")).toBeVisible({ timeout: 10000 });
      await expect(page.getByText("reverse.py").first()).toBeVisible({ timeout: 10000 });
      // Open the panel — no Save button without project context
      await page.locator("[data-cy=artifact-card]").click();
      await expect(page.locator("[data-cy=panel-download-btn]")).toBeVisible({ timeout: 5000 });
      await expect(page.locator("[data-cy=panel-save-btn]")).not.toBeVisible();
    } finally {
      await deleteConversation(page, convId);
    }
  });

  // ── 3. Click card → panel → Save shows ✓ Saved ───────────────────────────

  test("clicking artifact card opens panel; clicking Save in panel shows Saved confirmation", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `test-save-confirm-${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    try {
      await appendAssistantMessage(page, convId, makeAssistantMsg("users.sql", "sql", "SELECT id, name FROM users;"));

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);

      // Click artifact card to open panel
      await expect(page.locator("[data-cy=artifact-card]")).toBeVisible({ timeout: 10000 });
      await page.locator("[data-cy=artifact-card]").click();

      // Save button appears in panel header (project context)
      await expect(page.locator("[data-cy=panel-save-btn]")).toBeVisible({ timeout: 5000 });
      await page.locator("[data-cy=panel-save-btn]").click();

      await expect(page.locator("[data-cy=panel-save-btn]")).toHaveText("✓", { timeout: 8000 });
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

      // Open panel and save
      await expect(page.locator("[data-cy=artifact-card]")).toBeVisible({ timeout: 10000 });
      await page.locator("[data-cy=artifact-card]").click();
      await expect(page.locator("[data-cy=panel-save-btn]")).toBeVisible({ timeout: 5000 });
      await page.locator("[data-cy=panel-save-btn]").click();
      await expect(page.locator("[data-cy=panel-save-btn]")).toHaveText("✓", { timeout: 8000 });

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

      // Open panel and save via panel button
      await expect(page.locator("[data-cy=artifact-card]")).toBeVisible({ timeout: 10000 });
      await page.locator("[data-cy=artifact-card]").click();
      await expect(page.locator("[data-cy=panel-save-btn]")).toBeVisible({ timeout: 5000 });
      await page.locator("[data-cy=panel-save-btn]").click();
      await expect(page.locator("[data-cy=panel-save-btn]")).toHaveText("✓", { timeout: 8000 });

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

      // Open panel and save via panel button
      await expect(page.locator("[data-cy=artifact-card]")).toBeVisible({ timeout: 10000 });
      await page.locator("[data-cy=artifact-card]").click();
      await expect(page.locator("[data-cy=panel-save-btn]")).toBeVisible({ timeout: 5000 });
      await page.locator("[data-cy=panel-save-btn]").click();
      await expect(page.locator("[data-cy=panel-save-btn]")).toHaveText("✓", { timeout: 8000 });

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

  // ── 7. Batch: Save All card appears for multiple filename blocks ───────────

  test("Save All card appears when assistant message has multiple filename blocks", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `test-batch-${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    const ts = Date.now();
    const files = [
      { filename: `utils-${ts}.py`,   ext: "py",  code: "def util(): pass" },
      { filename: `schema-${ts}.sql`, ext: "sql", code: "CREATE TABLE t (id INT);" },
      { filename: `api-${ts}.ts`,     ext: "ts",  code: "export const api = {};" },
    ];
    const content = files.map(f => makeAssistantMsg(f.filename, f.ext, f.code)).join("\n\n");
    try {
      await appendAssistantMessage(page, convId, content);
      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);

      // Consolidated card must appear
      await expect(page.getByRole("button", { name: "Save All to Project" })).toBeVisible({ timeout: 10000 });
      // Individual "Save to Project" buttons must NOT be visible
      await expect(page.getByRole("button", { name: "Save to Project" })).not.toBeVisible();
      // All filenames listed in the batch card
      for (const f of files) {
        await expect(page.getByText(f.filename).first()).toBeVisible();
      }
    } finally {
      await deleteConversation(page, convId);
      await deleteProject(page, projectId);
    }
  });

  // ── 8. Batch: Save All saves all files and injects context messages ────────

  test("Save All to Project saves all files and injects a context message per file", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `test-batch-save-${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    const ts = Date.now();
    const files = [
      { filename: `alpha-${ts}.py`,   ext: "py",  code: "def alpha(): pass" },
      { filename: `beta-${ts}.sql`,   ext: "sql", code: "CREATE TABLE beta (id INT);" },
      { filename: `gamma-${ts}.ts`,   ext: "ts",  code: "export const gamma = 1;" },
    ];
    const content = files.map(f => makeAssistantMsg(f.filename, f.ext, f.code)).join("\n\n");
    try {
      await appendAssistantMessage(page, convId, content);
      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);

      await expect(page.getByRole("button", { name: "Save All to Project" })).toBeVisible({ timeout: 10000 });
      await page.getByRole("button", { name: "Save All to Project" }).click();
      await expect(page.getByText("✓ All saved")).toBeVisible({ timeout: 10000 });

      // All files must be in the knowledge base
      const rows = await listKnowledge(page, projectId);
      for (const f of files) {
        const entry = rows.find(r => r.filename === f.filename);
        expect(entry, `${f.filename} must be in knowledge base`).toBeTruthy();
        expect(entry!.token_count, "token_count > 0").toBeGreaterThan(0);
      }

      // A context injection message must appear in the thread for each file
      for (const f of files) {
        await expect(page.getByText(`[File saved to project: ${f.filename}]`)).toBeVisible({ timeout: 5000 });
      }
    } finally {
      await deleteConversation(page, convId);
      const rows = await listKnowledge(page, projectId);
      for (const r of rows) await deleteKnowledgeEntry(page, projectId, r.id);
      await deleteProject(page, projectId);
    }
  });

  // ── 9. Batch: "Save individually" hides the SaveAll card ─────────────────

  test("Save individually button hides SaveAll card; artifact cards remain visible", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `test-individual-${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    const ts = Date.now();
    const files = [
      { filename: `x-${ts}.py`,  ext: "py",  code: "x = 1" },
      { filename: `y-${ts}.ts`,  ext: "ts",  code: "const y = 2;" },
    ];
    const content = files.map(f => makeAssistantMsg(f.filename, f.ext, f.code)).join("\n\n");
    try {
      await appendAssistantMessage(page, convId, content);
      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);

      // Batch card visible initially; individual artifact cards visible too
      await expect(page.getByRole("button", { name: "Save All to Project" })).toBeVisible({ timeout: 10000 });
      await expect(page.getByRole("button", { name: "Save individually" })).toBeVisible();
      await expect(page.locator("[data-cy=artifact-card]")).toHaveCount(2, { timeout: 5000 });

      // Click "Save individually"
      await page.getByRole("button", { name: "Save individually" }).click();

      // Batch card must disappear; individual artifact cards remain; no Save buttons in thread
      await expect(page.getByRole("button", { name: "Save All to Project" })).not.toBeVisible();
      await expect(page.locator("[data-cy=artifact-card]")).toHaveCount(2);
      await expect(page.getByRole("button", { name: "Save to Project" })).not.toBeVisible();
    } finally {
      await deleteConversation(page, convId);
      await deleteProject(page, projectId);
    }
  });
});

// ---------------------------------------------------------------------------
// Artifact card UX
// ---------------------------------------------------------------------------

test.describe("Chat — artifact card UX", () => {

  // ── Named code block renders as card, not inline code ────────────────────
  test("named code block renders as artifact card with no inline code", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const convId = await createConversation(page, gatewayId);
    try {
      const code = "def reverse(s):\n    return s[::-1]";
      await appendAssistantMessage(page, convId, makeAssistantMsg("reverse.py", "py", code));

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}`);

      // Card must be visible
      await expect(page.locator("[data-cy=artifact-card]")).toBeVisible({ timeout: 10000 });
      // Filename label shown on card
      await expect(page.getByText("reverse.py").first()).toBeVisible();
      // Full code must NOT be shown inline in the chat bubble
      await expect(page.getByText("def reverse(s):")).not.toBeVisible();
    } finally {
      await deleteConversation(page, convId);
    }
  });

  // ── Clicking artifact card opens the side panel ───────────────────────────
  test("clicking artifact card opens the artifact panel with code tab", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const convId = await createConversation(page, gatewayId);
    try {
      const code = "def hello():\n    print('Hello')";
      await appendAssistantMessage(page, convId, makeAssistantMsg("hello.py", "py", code));

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}`);

      await expect(page.locator("[data-cy=artifact-card]")).toBeVisible({ timeout: 10000 });
      await page.locator("[data-cy=artifact-card]").click();

      // Panel must open and show the code
      await expect(page.locator("[data-cy=panel-copy-btn]")).toBeVisible({ timeout: 5000 });
      await expect(page.getByText("def hello():")).toBeVisible({ timeout: 5000 });
    } finally {
      await deleteConversation(page, convId);
    }
  });

  // ── Panel download button visible ─────────────────────────────────────────
  test("artifact panel shows download button", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const convId = await createConversation(page, gatewayId);
    try {
      await appendAssistantMessage(page, convId, makeAssistantMsg("data.sql", "sql", "SELECT * FROM users;"));

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}`);

      await expect(page.locator("[data-cy=artifact-card]")).toBeVisible({ timeout: 10000 });
      await page.locator("[data-cy=artifact-card]").click();

      await expect(page.locator("[data-cy=panel-download-btn]")).toBeVisible({ timeout: 5000 });
    } finally {
      await deleteConversation(page, convId);
    }
  });

  // ── HTML artifact shows Preview tab in panel ──────────────────────────────
  test("HTML artifact card opens panel with Preview tab", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const convId = await createConversation(page, gatewayId);
    try {
      const html = "# index.html\n<!DOCTYPE html><html><head><title>Test</title></head><body><h1>Hello</h1><p>World</p><div>Line</div><span>Another</span><p>More</p></body></html>";
      await appendAssistantMessage(page, convId, `\`\`\`html\n${html}\n\`\`\``);

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}`);

      await expect(page.locator("[data-cy=artifact-card]")).toBeVisible({ timeout: 10000 });
      await page.locator("[data-cy=artifact-card]").click();

      // Preview tab must exist and be active by default for html
      await expect(page.getByRole("button", { name: "Preview", exact: true })).toBeVisible({ timeout: 5000 });
      await expect(page.getByRole("button", { name: "Code", exact: true })).toBeVisible();
    } finally {
      await deleteConversation(page, convId);
    }
  });

  // ── Anonymous (no filename) code block stays inline ───────────────────────
  test("anonymous code block without filename stays inline (no artifact card)", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const convId = await createConversation(page, gatewayId);
    try {
      // No filename comment on first line
      await appendAssistantMessage(page, convId, "Here is some code:\n\n```python\ndef anonymous():\n    pass\n```");

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}`);

      await page.waitForLoadState("networkidle");
      // No artifact card — code rendered inline
      await expect(page.locator("[data-cy=artifact-card]")).not.toBeVisible();
      // Code IS shown inline
      await expect(page.getByText("def anonymous():")).toBeVisible({ timeout: 10000 });
    } finally {
      await deleteConversation(page, convId);
    }
  });

  // ── Panel Download button on card works ───────────────────────────────────
  test("card download button triggers a file download without opening the panel", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const convId = await createConversation(page, gatewayId);
    try {
      await appendAssistantMessage(page, convId, makeAssistantMsg("script.sh", "sh", "#!/bin/sh\necho hello"));

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}`);

      await expect(page.locator("[data-cy=artifact-card]")).toBeVisible({ timeout: 10000 });

      // Download button is on the card; clicking it triggers a download
      const [download] = await Promise.all([
        page.waitForEvent("download"),
        page.locator("[data-cy=artifact-card-download]").click(),
      ]);
      expect(download.suggestedFilename()).toBe("script.sh");

      // Panel should NOT have opened (no copy button visible)
      await expect(page.locator("[data-cy=panel-copy-btn]")).not.toBeVisible();
    } finally {
      await deleteConversation(page, convId);
    }
  });

  // ── Multiple named blocks: each gets a card ───────────────────────────────
  test("multiple named blocks in one message each get an artifact card", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const convId = await createConversation(page, gatewayId);
    const ts = Date.now();
    const files = [
      { filename: `a-${ts}.py`,  ext: "py",  code: "a = 1" },
      { filename: `b-${ts}.ts`,  ext: "ts",  code: "const b = 2;" },
    ];
    const content = files.map(f => makeAssistantMsg(f.filename, f.ext, f.code)).join("\n\n");
    try {
      await appendAssistantMessage(page, convId, content);
      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}`);

      await expect(page.locator("[data-cy=artifact-card]")).toHaveCount(2, { timeout: 10000 });
    } finally {
      await deleteConversation(page, convId);
    }
  });

});

// ---------------------------------------------------------------------------
// Project context banner + pill
// ---------------------------------------------------------------------------

test.describe("Chat — project context banner and pill", () => {

  test("project banner is visible in message area when in project context", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, "Banner Test Project");
    const convId = await createConversation(page, gatewayId, projectId);
    try {
      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);
      await page.waitForLoadState("networkidle");

      // Banner must show project name
      await expect(page.getByText("Banner Test Project").first()).toBeVisible({ timeout: 8000 });

      // "Open project" link must point to /projects/:id
      const openLink = page.getByRole("link", { name: /open project/i });
      await expect(openLink).toBeVisible();
      await expect(openLink).toHaveAttribute("href", `/projects/${projectId}`);

      // "Exit project" link must point to /chat
      const exitLink = page.getByRole("link", { name: /exit project/i });
      await expect(exitLink).toBeVisible();
      await expect(exitLink).toHaveAttribute("href", "/chat");
    } finally {
      await deleteConversation(page, convId);
      await deleteProject(page, projectId);
    }
  });

  test("project banner is absent in normal (non-project) chat", async ({ page }) => {
    const { gatewayId, tenantId } = await getFirstTenantAndGateway(page);
    const convResp = await page.context().request.post(`${ADMIN_BASE}/conversations`, {
      data: { gateway_id: gatewayId, title: "Normal chat" },
    });
    expect(convResp.ok()).toBeTruthy();
    const convId = ((await convResp.json()) as { id: string }).id;
    try {
      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}`);
      await page.waitForLoadState("networkidle");

      await expect(page.getByRole("link", { name: /open project/i })).not.toBeVisible();
      await expect(page.getByRole("link", { name: /exit project/i })).not.toBeVisible();
    } finally {
      await page.context().request.delete(`${ADMIN_BASE}/conversations/${convId}`).catch(() => {});
    }
  });

  test("banner shows file count when project has knowledge files", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, "Banner Files Project");
    const convId = await createConversation(page, gatewayId, projectId);
    const knResp = await page.context().request.post(`${ADMIN_BASE}/projects/${projectId}/knowledge`, {
      data: { filename: "notes.txt", content_type: "text/plain", size_bytes: 5, extracted_text: "hello" },
    });
    expect(knResp.ok()).toBeTruthy();
    const knId = ((await knResp.json()) as { id: string }).id;
    try {
      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);
      await page.waitForLoadState("networkidle");

      await expect(page.getByText(/1 file/)).toBeVisible({ timeout: 8000 });
    } finally {
      await deleteConversation(page, convId);
      await page.context().request.delete(`${ADMIN_BASE}/projects/${projectId}/knowledge/${knId}`).catch(() => {});
      await deleteProject(page, projectId);
    }
  });

  test("exit project link navigates away from project context", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, "Exit Nav Project");
    const convId = await createConversation(page, gatewayId, projectId);
    try {
      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);
      await page.waitForLoadState("networkidle");

      await expect(page.getByRole("link", { name: /exit project/i })).toBeVisible({ timeout: 8000 });
      await page.getByRole("link", { name: /exit project/i }).click();

      await expect(page).toHaveURL(/\/chat/, { timeout: 5000 });
      await expect(page).not.toHaveURL(/project_id/);
      await expect(page.getByRole("link", { name: /exit project/i })).not.toBeVisible();
    } finally {
      await deleteConversation(page, convId);
      await deleteProject(page, projectId);
    }
  });

  // ── P1.2 — Clickable "instructions active" opens modal ───────────────────

  test("clicking 'instructions active' opens project instructions modal", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const r = await page.context().request.post(`${ADMIN_BASE}/projects`, {
      data: {
        name: `Instructions Modal ${Date.now()}`,
        icon: "📁",
        color: "#2563eb",
        tenant_id: tenantId,
        instructions: "These are the test instructions. Follow them carefully.",
      },
    });
    expect(r.ok()).toBeTruthy();
    const projectId = ((await r.json()) as ProjectRow).id;
    const convId = await createConversation(page, gatewayId, projectId);
    try {
      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);
      await page.waitForLoadState("networkidle");

      // "instructions active" button must be visible in banner
      const btn = page.getByRole("button", { name: /instructions active/i });
      await expect(btn).toBeVisible({ timeout: 8000 });

      // Click to open modal
      await btn.click();

      // Modal must appear with title and content
      await expect(page.getByText("Project Instructions")).toBeVisible({ timeout: 5000 });
      await expect(page.getByText("These are the test instructions. Follow them carefully.")).toBeVisible();
    } finally {
      await deleteConversation(page, convId);
      await deleteProject(page, projectId);
    }
  });

  // ── P1.3 — "New project chat" label in sidebar ───────────────────────────

  test("sidebar new-chat button shows 'New project chat' in project context", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `Sidebar Label ${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    try {
      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);
      await page.waitForLoadState("networkidle");

      // The new chat button must say "New project chat" in project context
      await expect(page.getByRole("button", { name: /new project chat/i })).toBeVisible({ timeout: 8000 });
    } finally {
      await deleteConversation(page, convId);
      await deleteProject(page, projectId);
    }
  });

  test("sidebar new-chat button shows 'New Chat' outside project context", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const convId = await createConversation(page, gatewayId);
    try {
      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}`);
      await page.waitForLoadState("networkidle");

      await expect(page.getByRole("button", { name: /^new chat$/i })).toBeVisible({ timeout: 8000 });
      await expect(page.getByRole("button", { name: /new project chat/i })).not.toBeVisible();
    } finally {
      await deleteConversation(page, convId);
    }
  });

});

// ---------------------------------------------------------------------------
// Project welcome screen (empty state with project context)
// ---------------------------------------------------------------------------

test.describe("Chat — project welcome screen", () => {

  test("project welcome card shown when opening project with no conversation selected", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const r = await page.context().request.post(`${ADMIN_BASE}/projects`, {
      data: {
        name: `Welcome Screen ${Date.now()}`,
        icon: "🚀",
        color: "#7c3aed",
        tenant_id: tenantId,
        description: "A project for testing the welcome screen",
      },
    });
    expect(r.ok()).toBeTruthy();
    const project = (await r.json()) as ProjectRow & { name: string };
    const projectId = project.id;
    try {
      await setChatPreferences(page, gatewayId, tenantId);
      // Navigate to project context without a conversation
      await page.goto(`/chat?project_id=${projectId}`);
      await page.waitForLoadState("networkidle");

      // Welcome card must show project name and description
      await expect(page.getByText("Welcome Screen", { exact: false }).first()).toBeVisible({ timeout: 8000 });
      await expect(page.getByText("A project for testing the welcome screen")).toBeVisible({ timeout: 5000 });
    } finally {
      await deleteProject(page, projectId);
    }
  });

  test("welcome card shows instructions toggle when project has instructions", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const r = await page.context().request.post(`${ADMIN_BASE}/projects`, {
      data: {
        name: `Welcome Instructions ${Date.now()}`,
        icon: "📝",
        color: "#0ea5e9",
        tenant_id: tenantId,
        instructions: "Follow these project-level guidelines when coding.",
      },
    });
    expect(r.ok()).toBeTruthy();
    const projectId = ((await r.json()) as ProjectRow).id;
    try {
      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?project_id=${projectId}`);
      await page.waitForLoadState("networkidle");

      // Instructions toggle must be visible and collapsed by default
      const toggle = page.getByRole("button", { name: /instructions/i }).first();
      await expect(toggle).toBeVisible({ timeout: 8000 });

      // Instructions body not visible until expanded
      await expect(page.getByText("Follow these project-level guidelines when coding.")).not.toBeVisible();

      // Expand
      await toggle.click();
      await expect(page.getByText("Follow these project-level guidelines when coding.")).toBeVisible({ timeout: 3000 });
    } finally {
      await deleteProject(page, projectId);
    }
  });

  test("welcome card shows file chips for project knowledge files", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `Welcome Files ${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    const knResp = await page.context().request.post(`${ADMIN_BASE}/projects/${projectId}/knowledge`, {
      data: { filename: "welcome-test.txt", content_type: "text/plain", size_bytes: 12, extracted_text: "hello world" },
    });
    expect(knResp.ok()).toBeTruthy();
    const knId = ((await knResp.json()) as { id: string }).id;
    try {
      await setChatPreferences(page, gatewayId, tenantId);
      // New conversation with no messages
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);
      await page.waitForLoadState("networkidle");

      // Welcome card's file chip
      await expect(page.getByText("welcome-test.txt").first()).toBeVisible({ timeout: 8000 });
    } finally {
      await deleteConversation(page, convId);
      await page.context().request.delete(`${ADMIN_BASE}/projects/${projectId}/knowledge/${knId}`).catch(() => {});
      await deleteProject(page, projectId);
    }
  });

  test("welcome card is NOT shown when conversation has messages", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `No Welcome ${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    try {
      // Add a message so the thread is non-empty
      await appendAssistantMessage(page, convId, "Hello from the assistant.");

      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);
      await page.waitForLoadState("networkidle");

      // Message must be visible (thread not empty state)
      await expect(page.getByText("Hello from the assistant.")).toBeVisible({ timeout: 8000 });

      // Generic empty-state text and welcome hint must NOT appear
      await expect(page.getByText("Start a new chat below")).not.toBeVisible();
    } finally {
      await deleteConversation(page, convId);
      await deleteProject(page, projectId);
    }
  });

});

// ---------------------------------------------------------------------------
// P2.5 — Files panel accessible from chat banner
// ---------------------------------------------------------------------------

test.describe("Chat — files panel from banner", () => {

  test("Files button in banner opens files panel with file list", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `Files Panel ${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    const knResp = await page.context().request.post(`${ADMIN_BASE}/projects/${projectId}/knowledge`, {
      data: { filename: "panel-file.md", content_type: "text/markdown", size_bytes: 20, extracted_text: "# Panel test content" },
    });
    expect(knResp.ok()).toBeTruthy();
    const knId = ((await knResp.json()) as { id: string }).id;
    try {
      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);
      await page.waitForLoadState("networkidle");

      // Files button must be visible in banner
      const filesBtn = page.getByRole("button", { name: /files/i }).first();
      await expect(filesBtn).toBeVisible({ timeout: 8000 });

      // Panel not visible yet
      await expect(page.locator("[data-cy=chat-files-panel]")).not.toBeVisible();

      // Click to open
      await filesBtn.click();
      await expect(page.locator("[data-cy=chat-files-panel]")).toBeVisible({ timeout: 3000 });

      // File must be listed
      await expect(page.getByText("panel-file.md").first()).toBeVisible();

      // Click to close
      await filesBtn.click();
      await expect(page.locator("[data-cy=chat-files-panel]")).not.toBeVisible();
    } finally {
      await deleteConversation(page, convId);
      await page.context().request.delete(`${ADMIN_BASE}/projects/${projectId}/knowledge/${knId}`).catch(() => {});
      await deleteProject(page, projectId);
    }
  });

  test("clicking a file in the files panel opens the preview modal", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `File Preview Panel ${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    const knResp = await page.context().request.post(`${ADMIN_BASE}/projects/${projectId}/knowledge`, {
      data: { filename: "preview-from-panel.txt", content_type: "text/plain", size_bytes: 14, extracted_text: "preview content" },
    });
    expect(knResp.ok()).toBeTruthy();
    const knId = ((await knResp.json()) as { id: string }).id;
    try {
      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);
      await page.waitForLoadState("networkidle");

      // Open files panel
      const filesBtn = page.getByRole("button", { name: /files/i }).first();
      await expect(filesBtn).toBeVisible({ timeout: 8000 });
      await filesBtn.click();
      await expect(page.locator("[data-cy=chat-files-panel]")).toBeVisible({ timeout: 3000 });

      // Click a file item
      const fileItem = page.locator("[data-cy=chat-file-item]").first();
      await expect(fileItem).toBeVisible();
      await fileItem.click();

      // Preview modal must appear with the filename as title
      await expect(page.getByText("preview-from-panel.txt").first()).toBeVisible({ timeout: 5000 });
    } finally {
      await deleteConversation(page, convId);
      await page.context().request.delete(`${ADMIN_BASE}/projects/${projectId}/knowledge/${knId}`).catch(() => {});
      await deleteProject(page, projectId);
    }
  });

  test("Files button absent in banner when project has no knowledge files", async ({ page }) => {
    const { tenantId, gatewayId } = await getFirstTenantAndGateway(page);
    const projectId = await createProject(page, tenantId, `No Files ${Date.now()}`);
    const convId = await createConversation(page, gatewayId, projectId);
    try {
      await setChatPreferences(page, gatewayId, tenantId);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);
      await page.waitForLoadState("networkidle");

      // Banner must be visible (project context) but no Files button
      await expect(page.getByRole("link", { name: /open project/i })).toBeVisible({ timeout: 8000 });
      await expect(page.getByRole("button", { name: /files \(/i })).not.toBeVisible();
    } finally {
      await deleteConversation(page, convId);
      await deleteProject(page, projectId);
    }
  });

});
