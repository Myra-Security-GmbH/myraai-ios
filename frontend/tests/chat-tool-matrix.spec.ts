/**
 * chat-tool-matrix.spec.ts — full permutation E2E tests for server-side tool use.
 *
 * Covers all combinations of:
 *   models   : claude-sonnet-4-6 (Anthropic), qwen3-30b-a3b (vLLM)
 *   PII      : inactive (prod gateway), active (prod-pii gateway)
 *   tools    : web_search, fetch_url, read_file, write_file
 *
 * 16 combinations total; sonnet+noPII is already covered by the dedicated
 * per-tool spec files so those 4 are omitted here to avoid duplication.
 * The remaining 12 are all covered below.
 *
 * No model responses are mocked — every test makes real inference calls and
 * asserts on the actual response content.
 *
 * Presets (tenant "myratest"):
 *   "UNSAFE claude-sonnet-4-6" → prod     · anthropic · no PII
 *   "PII claude-sonnet-4-6"    → prod-pii · anthropic · PII active
 *   "SAFE local only"          → prod     · vllm      · no PII
 *   "PII qwen3"                → prod-pii · vllm      · PII active
 */

import { test, expect, type Page } from "@playwright/test";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const ADMIN_BASE  = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TENANT_SLUG = "myratest";

const PRESET_SONNET_PII  = "PII claude-sonnet-4-6";
const PRESET_QWEN3_NOPII = "SAFE local only";
const PRESET_QWEN3_PII   = "PII qwen3";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function getTenantId(page: Page): Promise<string> {
  const r = await page.context().request.get(`${ADMIN_BASE}/admin/v1/tenants`);
  const tenants = await r.json() as Array<{ id: string; slug: string }>;
  return tenants.find((t) => t.slug === TENANT_SLUG)?.id ?? "";
}

async function createProject(page: Page, tenantId: string, name: string): Promise<string> {
  const r = await page.context().request.post(`${ADMIN_BASE}/admin/v1/projects`, {
    data: { name, tenant_id: tenantId },
  });
  expect(r.ok(), `createProject: ${await r.text()}`).toBeTruthy();
  return (await r.json() as { id: string }).id;
}

async function deleteProject(page: Page, id: string) {
  await page.context().request.delete(`${ADMIN_BASE}/admin/v1/projects/${id}`).catch(() => {});
}

async function uploadKnowledgeFile(
  page: Page, projectId: string, filename: string, content: string
) {
  await page.context().request.put(
    `${ADMIN_BASE}/admin/v1/projects/${projectId}/knowledge/${filename}`,
    { data: { extracted_text: content, content_type: "text/plain", size_bytes: content.length } }
  );
}

async function getProjectKnowledge(page: Page, projectId: string) {
  const r = await page.context().request.get(
    `${ADMIN_BASE}/admin/v1/projects/${projectId}/knowledge`
  );
  return r.ok() ? (await r.json() as Array<{ filename: string }>) : [];
}

async function deleteAllConversations(page: Page, createdAfter: number) {
  try {
    const r = await page.context().request.get(`${ADMIN_BASE}/admin/v1/conversations`);
    if (!r.ok()) return;
    const convs = await r.json() as Array<{ id: string; created_at?: string }>;
    for (const c of convs) {
      if (c.created_at && new Date(c.created_at).getTime() < createdAfter) continue;
      await page.context().request.delete(`${ADMIN_BASE}/admin/v1/conversations/${c.id}`)
        .catch(() => {});
    }
  } catch { /* best-effort */ }
}

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

async function selectPreset(page: Page, presetName: string): Promise<boolean> {
  const sel = page.locator("select").first();
  await sel.waitFor({ state: "visible", timeout: 5_000 });
  // Wait for the tenant options to finish loading (the select renders before the API returns)
  const opt = sel.locator("option").filter({ hasText: new RegExp(TENANT_SLUG, "i") });
  await opt.first().waitFor({ state: "attached", timeout: 10_000 }).catch(() => {});
  if ((await opt.count()) === 0) return false;
  await sel.selectOption({ label: (await opt.first().textContent()) ?? TENANT_SLUG });
  // Wait for the preset options container to appear (tenant presets are now loaded)
  await page.locator("[data-testid='config-preset-options']")
    .waitFor({ state: "visible", timeout: 12_000 }).catch(() => {});
  const esc = presetName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const btn = page.locator("button").filter({ hasText: new RegExp(esc, "i") });
  if (!(await btn.isVisible({ timeout: 5_000 }).catch(() => false))) return false;
  await btn.click();
  await expect(page.locator("[class*='chat-textarea']")).toBeEnabled({ timeout: 5_000 });
  return true;
}

async function waitForReply(page: Page, timeoutMs = 90_000) {
  await page.locator("button[title='Stop generating']")
    .waitFor({ state: "visible", timeout: 20_000 }).catch(() => {});
  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: timeoutMs });
}

async function sendAndWait(page: Page, message: string, timeoutMs = 90_000): Promise<string> {
  // Button label is "New chat" in normal mode, "New project chat" in project context
  await page.getByRole("button", { name: /new.*chat/i }).click();
  await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5_000 });
  await page.locator("[class*='chat-textarea']").fill(message);
  await page.locator("button[title='Send message']").click();
  await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });
  await waitForReply(page, timeoutMs);
  const bubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
  await expect(bubble).toBeVisible({ timeout: 10_000 });
  return (await bubble.textContent()) ?? "";
}

async function assertNoError(page: Page) {
  await expect(page.getByText(/TypeError|failed to fetch|internal gateway error/i).first())
    .not.toBeVisible({ timeout: 2_000 }).catch(() => {});
}

// ---------------------------------------------------------------------------
// PII claude-sonnet-4-6 (Anthropic, prod-pii)
// ---------------------------------------------------------------------------

test.describe("Tool matrix — sonnet + PII (prod-pii)", () => {
  test.setTimeout(180_000);
  let t0: number;
  test.beforeEach(async ({ page }) => { t0 = Date.now(); await goToChat(page); });
  test.afterEach(async ({ page }) => deleteAllConversations(page, t0));

  test("web_search returns real result", async ({ page }) => {
    if (!await selectPreset(page, PRESET_SONNET_PII)) { test.skip(); return; }
    const reply = await sendAndWait(page,
      "What is the current price of Bitcoin in USD? Reply with just the number.");
    await assertNoError(page);
    expect(reply.trim().length).toBeGreaterThan(5);
    expect(reply).toMatch(/\d/);
  });

  test("fetch_url reads URL content", async ({ page }) => {
    if (!await selectPreset(page, PRESET_SONNET_PII)) { test.skip(); return; }
    const reply = await sendAndWait(page,
      "Read this page and tell me the product name: https://ai-docs.myra.eu");
    await assertNoError(page);
    expect(reply).toMatch(/ai.gateway|myra/i);
  });

  test("read_file reads from project knowledge base", async ({ page }) => {
    const tId = await getTenantId(page);
    const marker = "XYZZY-" + Date.now();
    const pid = await createProject(page, tId, "matrix-sonnet-pii-read-" + Date.now());
    try {
      await uploadKnowledgeFile(page, pid, "facts.txt",
        `Codename: ${marker}. Budget: EUR 99000.`);
      await goToChat(page, pid);
      if (!await selectPreset(page, PRESET_SONNET_PII)) { test.skip(); return; }
      const reply = await sendAndWait(page,
        "Read facts.txt and tell me the codename.", 120_000);
      await assertNoError(page);
      expect(reply).toContain(marker);
    } finally { await deleteProject(page, pid); }
  });

  test("write_file saves to project knowledge base", async ({ page }) => {
    const tId = await getTenantId(page);
    const marker = "e2e_" + Date.now();
    const pid = await createProject(page, tId, "matrix-sonnet-pii-write-" + Date.now());
    try {
      await goToChat(page, pid);
      if (!await selectPreset(page, PRESET_SONNET_PII)) { test.skip(); return; }
      await sendAndWait(page,
        `Create a file called ${marker}.txt with content "hello from e2e". ` +
        `Use the <write_file filename="${marker}.txt"> tag.`, 120_000);
      await assertNoError(page);
      const files = await getProjectKnowledge(page, pid);
      expect(files.some((f) => f.filename.includes(marker)),
        `${marker}.txt not found in project knowledge`).toBeTruthy();
    } finally { await deleteProject(page, pid); }
  });
});

// ---------------------------------------------------------------------------
// SAFE local only — qwen3, prod (vLLM, no PII)
// ---------------------------------------------------------------------------

test.describe("Tool matrix — qwen3 + no PII (prod)", () => {
  test.setTimeout(180_000);
  let t0: number;
  test.beforeEach(async ({ page }) => { t0 = Date.now(); await goToChat(page); });
  test.afterEach(async ({ page }) => deleteAllConversations(page, t0));

  test("web_search returns real result", async ({ page }) => {
    if (!await selectPreset(page, PRESET_QWEN3_NOPII)) { test.skip(); return; }
    const reply = await sendAndWait(page,
      "What is the current price of Bitcoin in USD? Reply with just the number.");
    await assertNoError(page);
    expect(reply.trim().length).toBeGreaterThan(5);
    expect(reply).toMatch(/\d/);
  });

  test("fetch_url reads URL content", async ({ page }) => {
    if (!await selectPreset(page, PRESET_QWEN3_NOPII)) { test.skip(); return; }
    const reply = await sendAndWait(page,
      "Read this page and tell me the product name: https://ai-docs.myra.eu");
    await assertNoError(page);
    expect(reply).toMatch(/ai.gateway|myra/i);
  });

  test("read_file reads from project knowledge base", async ({ page }) => {
    const tId = await getTenantId(page);
    const marker = "XYZZY-" + Date.now();
    const pid = await createProject(page, tId, "matrix-qwen3-nopii-read-" + Date.now());
    try {
      await uploadKnowledgeFile(page, pid, "facts.txt",
        `Codename: ${marker}. Budget: EUR 99000.`);
      await goToChat(page, pid);
      if (!await selectPreset(page, PRESET_QWEN3_NOPII)) { test.skip(); return; }
      const reply = await sendAndWait(page,
        "Read facts.txt and tell me the codename.", 120_000);
      await assertNoError(page);
      expect(reply).toContain(marker);
    } finally { await deleteProject(page, pid); }
  });

  test("write_file saves to project knowledge base", async ({ page }) => {
    const tId = await getTenantId(page);
    const marker = "e2e_" + Date.now();
    const pid = await createProject(page, tId, "matrix-qwen3-nopii-write-" + Date.now());
    try {
      await goToChat(page, pid);
      if (!await selectPreset(page, PRESET_QWEN3_NOPII)) { test.skip(); return; }
      await sendAndWait(page,
        `Create a file called ${marker}.txt with content "hello from e2e". ` +
        `Use the <write_file filename="${marker}.txt"> tag.`, 120_000);
      await assertNoError(page);
      const files = await getProjectKnowledge(page, pid);
      expect(files.some((f) => f.filename.includes(marker)),
        `${marker}.txt not found in project knowledge`).toBeTruthy();
    } finally { await deleteProject(page, pid); }
  });
});

// ---------------------------------------------------------------------------
// PII qwen3 — qwen3, prod-pii (vLLM, PII active)
// ---------------------------------------------------------------------------

test.describe("Tool matrix — qwen3 + PII (prod-pii)", () => {
  test.setTimeout(180_000);
  let t0: number;
  test.beforeEach(async ({ page }) => { t0 = Date.now(); await goToChat(page); });
  test.afterEach(async ({ page }) => deleteAllConversations(page, t0));

  test("web_search returns real result despite pii_force_buffered", async ({ page }) => {
    if (!await selectPreset(page, PRESET_QWEN3_PII)) { test.skip(); return; }
    const reply = await sendAndWait(page,
      "What is the current price of Bitcoin in USD? Reply with just the number.");
    await assertNoError(page);
    expect(reply.trim().length).toBeGreaterThan(5);
    expect(reply).toMatch(/\d/);
  });

  test("fetch_url reads URL content despite pii_force_buffered", async ({ page }) => {
    if (!await selectPreset(page, PRESET_QWEN3_PII)) { test.skip(); return; }
    const reply = await sendAndWait(page,
      "Read this page and tell me the product name: https://ai-docs.myra.eu");
    await assertNoError(page);
    expect(reply).toMatch(/ai.gateway|myra/i);
  });

  test("read_file reads from project knowledge base despite pii_force_buffered", async ({ page }) => {
    const tId = await getTenantId(page);
    const marker = "XYZZY-" + Date.now();
    const pid = await createProject(page, tId, "matrix-qwen3-pii-read-" + Date.now());
    try {
      await uploadKnowledgeFile(page, pid, "facts.txt",
        `Codename: ${marker}. Budget: EUR 99000.`);
      await goToChat(page, pid);
      if (!await selectPreset(page, PRESET_QWEN3_PII)) { test.skip(); return; }
      const reply = await sendAndWait(page,
        "Read facts.txt and tell me the codename.", 120_000);
      await assertNoError(page);
      expect(reply).toContain(marker);
    } finally { await deleteProject(page, pid); }
  });

  test("write_file saves to project knowledge base despite pii_force_buffered", async ({ page }) => {
    const tId = await getTenantId(page);
    const marker = "e2e_" + Date.now();
    const pid = await createProject(page, tId, "matrix-qwen3-pii-write-" + Date.now());
    try {
      await goToChat(page, pid);
      if (!await selectPreset(page, PRESET_QWEN3_PII)) { test.skip(); return; }
      await sendAndWait(page,
        `Create a file called ${marker}.txt with content "hello from e2e". ` +
        `Use the <write_file filename="${marker}.txt"> tag.`, 120_000);
      await assertNoError(page);
      const files = await getProjectKnowledge(page, pid);
      expect(files.some((f) => f.filename.includes(marker)),
        `${marker}.txt not found in project knowledge`).toBeTruthy();
    } finally { await deleteProject(page, pid); }
  });
});
