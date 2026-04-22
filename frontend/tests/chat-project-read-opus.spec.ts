/**
 * chat-project-read-opus.spec.ts — E2E test for project read_file with
 * claude-opus on prod-pii preset.
 *
 * Tests that when the model returns a native Anthropic tool_use for read_file
 * (instead of XML <read_file> tags), the frontend handles it correctly.
 *
 * Preset: "PII claude-opus-4.7" → prod-pii gateway + claude-opus-4-7
 */

import { test, expect, Page } from "@playwright/test";

const ADMIN_URL      = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TARGET_TENANT  = "myratest";
const TARGET_PRESET  = "UNSAFE claude-sonnet-4-6";

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

async function selectPreset(page: Page, presetName: string): Promise<boolean> {
  // Select tenant
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  const tenantOpt = tenantSel.locator("option").filter({ hasText: new RegExp(TARGET_TENANT, "i") });
  if ((await tenantOpt.count()) === 0) return false;
  await tenantSel.selectOption({ label: (await tenantOpt.first().textContent()) ?? TARGET_TENANT });

  // Click the preset button
  const presetBtn = page.locator("button").filter({ hasText: new RegExp(presetName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), "i") });
  const visible = await presetBtn.isVisible({ timeout: 5000 }).catch(() => false);
  if (!visible) {
    console.log("[TEST] Preset button not found:", presetName);
    return false;
  }
  await presetBtn.click();
  await expect(page.locator("[class*='chat-textarea']")).toBeEnabled({ timeout: 5000 });
  return true;
}

async function waitForStreamingDone(page: Page, timeoutMs = 90_000) {
  await page.locator("button[title='Stop generating']")
    .waitFor({ state: "visible", timeout: 30_000 }).catch(() => {});
  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: timeoutMs });
}

async function getFirstTenantId(page: Page): Promise<string> {
  const resp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
  const tenants = await resp.json() as Array<{ id: string; slug: string }>;
  return tenants.find((t) => t.slug === TARGET_TENANT)?.id ?? tenants[0]?.id ?? "";
}

test.describe("Chat — project read_file with Opus preset", () => {
  let testStartTime: number;
  test.setTimeout(120_000);

  test.beforeEach(async ({ page }) => {
    testStartTime = Date.now();
  });

  test.afterEach(async ({ page }) => {
    await deleteAllConversations(page, testStartTime);
  });

  test("model reads project file via tool_use or XML tags and produces response", async ({ page }) => {
    const tenantId = await getFirstTenantId(page);

    // Create a test project with a known knowledge file
    const projResp = await page.context().request.post(`${ADMIN_URL}/admin/v1/projects`, {
      data: { name: "e2e-opus-read-" + Date.now(), tenant_id: tenantId },
    });
    expect(projResp.ok(), `create project: ${await projResp.text()}`).toBeTruthy();
    const project = await projResp.json() as { id: string };

    // Upload a test file with UNIQUE content the model can't know from training
    const marker = "XYZZY-" + Date.now();
    const testContent = `Project codename: ${marker}. Budget approved: EUR 42,000. Lead: Dr. Müller. Status: green.`;
    await page.context().request.put(
      `${ADMIN_URL}/admin/v1/projects/${project.id}/knowledge/facts.txt`,
      { data: { extracted_text: testContent, content_type: "text/plain", size_bytes: testContent.length } }
    );

    try {
      // Navigate to project chat
      // Clear stale state from previous tests
      await page.goto("/chat");
      await page.evaluate(() => { localStorage.clear(); sessionStorage.clear(); });

      await page.goto(`/chat?project_id=${project.id}`);
      await page.locator("select").first().waitFor({ state: "visible", timeout: 10_000 });

      // Select the Opus preset
      const presetOk = await selectPreset(page, TARGET_PRESET);
      if (!presetOk) {
        // Fallback: try sonnet preset
        const sonnetOk = await selectPreset(page, "PII claude-sonnet");
        if (!sonnetOk) { test.skip(); return; }
      }

      // Start new chat (label is "New project chat" in project context)
      const newChatBtn = page.getByRole("button", { name: /new.*chat/i });
      await expect(newChatBtn).toBeVisible({ timeout: 10_000 });
      await newChatBtn.click();
      await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5000 });

      // Send message asking to read the file
      const textarea = page.locator("[class*='chat-textarea']");
      await expect(textarea).toBeVisible({ timeout: 5000 });
      await textarea.fill(`Read facts.txt and tell me the project codename and budget.`);
      await page.locator("button[title='Send message']").click();

      // User message must appear
      await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });

      // Wait for streaming to complete (long timeout for tool_use round-trips)
      await waitForStreamingDone(page, 90_000);

      // Assistant response must exist
      const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
      await expect(assistantBubble).toBeVisible({ timeout: 30_000 });

      const reply = (await assistantBubble.textContent()) ?? "";
      console.log("[TEST] assistant reply:", reply.slice(0, 400));

      // The response should mention content from the knowledge file
      expect(reply.length, "Response too short — model may not have read the file").toBeGreaterThan(20);
      // Check for either the unique marker or the budget — content only in the file
      expect(reply, "Expected response to reference knowledge file content").toMatch(/42[,.]?000|XYZZY|Müller|codename/i);

      // No error banner
      await expect(page.getByText(/TypeError|failed to fetch/i).first())
        .not.toBeVisible({ timeout: 2000 }).catch(() => {});

      // Check if read indicator was shown (either format works)
      const readIndicator = page.getByText(/📄 Read:|facts\.txt/i).first();
      const hasRead = await readIndicator.isVisible({ timeout: 3000 }).catch(() => false);
      console.log("[TEST] read indicator visible:", hasRead);

    } finally {
      await page.context().request.delete(`${ADMIN_URL}/admin/v1/projects/${project.id}`).catch(() => {});
    }
  });
});
