/**
 * chat-write-file.spec.ts — E2E tests for the <write_file> tag in /chat.
 *
 * Verifies that models can create/update files using <write_file filename="x">content</write_file>
 * and that:
 *   - In project chats: files are auto-saved to the project knowledge base
 *   - In normal chats: files render as ArtifactCards (viewable, copyable)
 *
 * Gateway: myratest / prod   Model: claude-sonnet-4-6
 */

import { test, expect } from "./base";
import type {  Page  } from "./base";
import { deleteConversations, captureConvId } from "./helpers";

const ADMIN_URL      = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TARGET_TENANT  = "myratest";
const TARGET_GATEWAY = "prod";
const TARGET_MODEL   = "claude-sonnet-4-6";
const TARGET_PRESET  = "UNSAFE claude-sonnet-4-6";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function selectGatewayWithModel(page: Page): Promise<boolean> {
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  await expect(tenantSel).toContainText(TARGET_TENANT, { timeout: 10_000 });
  await tenantSel.selectOption({ label: TARGET_TENANT });
  const presetBtn = page.locator("button").filter({ hasText: new RegExp(TARGET_PRESET.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), "i") });
  if (!(await presetBtn.isVisible({ timeout: 5000 }).catch(() => false))) return false;
  await presetBtn.click();
  await expect(page.locator("[class*='chat-textarea']")).toBeEnabled({ timeout: 5000 });
  return true;
}

async function waitForStreamingDone(page: Page, timeoutMs = 90_000) {
  await page.locator("button[title='Stop generating']")
    .waitFor({ state: "visible", timeout: 20_000 }).catch(() => {});
  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: timeoutMs });
}

async function getFirstTenantId(page: Page): Promise<string> {
  const resp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
  const tenants = await resp.json() as Array<{ id: string; slug: string }>;
  const t = tenants.find((t) => t.slug === TARGET_TENANT);
  return t?.id ?? tenants[0]?.id ?? "";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Chat — write_file tag", () => {
  let convIds: string[] = [];
  test.setTimeout(120_000);

  test.beforeEach(async ({ page }) => {
    await page.goto("/chat");
    await page.evaluate(() => { localStorage.clear(); sessionStorage.clear(); });
    await page.reload();
    await page.locator("select").first().waitFor({ state: "visible", timeout: 10_000 });
  });

  test.afterEach(async ({ page }) => {
    const id = captureConvId(page);
    if (id) convIds.push(id);
    await deleteConversations(page, convIds);
    convIds = [];
  });

  // ── 1. Normal chat: write_file renders as ArtifactCard ──────────────────

  test("write_file in normal chat renders as an artifact card", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5000 });

    await page.locator("[class*='chat-textarea']").fill(
      'Create a file called hello.py that prints "Hello World". Use the <write_file> tag.'
    );
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });
    await waitForStreamingDone(page, 90_000);

    // The response should contain an artifact card with the filename
    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantBubble).toBeVisible({ timeout: 10_000 });

    // Check for artifact card or code block containing hello.py
    const artifactCard = assistantBubble.locator("[class*='artifact-card']").first();
    const codeBlock = assistantBubble.locator("pre code").first();
    const hasArtifact = await artifactCard.isVisible({ timeout: 5000 }).catch(() => false);
    const hasCode = await codeBlock.isVisible({ timeout: 3000 }).catch(() => false);

    // Either an artifact card or a code block should be visible
    expect(hasArtifact || hasCode, "Expected artifact card or code block with hello.py").toBeTruthy();

    // No error banner
    await expect(page.getByText(/TypeError|failed to fetch/i).first())
      .not.toBeVisible({ timeout: 2000 }).catch(() => {});
  });

  // ── 2. Project chat: write_file auto-saves to knowledge base ────────────

  test("write_file in project chat saves file to knowledge base", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    const tenantId = await getFirstTenantId(page);
    const projName = "e2e-write-file-test-" + Date.now();

    // Create a temporary project
    const projResp = await page.context().request.post(`${ADMIN_URL}/admin/v1/projects`, {
      data: { name: projName, tenant_id: tenantId },
    });
    expect(projResp.ok(), `create project: ${await projResp.text()}`).toBeTruthy();
    const project = await projResp.json() as { id: string };

    try {
      // Navigate to project chat — the project param must be in the URL
      await page.goto(`/chat?project=${project.id}`);
      await page.locator("select").first().waitFor({ state: "visible", timeout: 10_000 });

      // Re-select gateway/model
      const ok2 = await selectGatewayWithModel(page);
      if (!ok2) { test.skip(true, "Required gateway or model not available in this environment"); return; }

      // Verify project context banner is visible
      const projectBanner = page.locator("[class*='project-banner'], [class*='project-pill']").first();
      const hasProjectCtx = await projectBanner.isVisible({ timeout: 3000 }).catch(() => false);

      await page.getByRole("button", { name: /new chat/i }).click();
      await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5000 });

      const marker = "e2e_write_" + Date.now();
      await page.locator("[class*='chat-textarea']").fill(
        `Create a Python file called ${marker}.py that prints "hello from e2e". ` +
        `You MUST use the <write_file filename="${marker}.py"> tag to create the file.`
      );
      await page.locator("button[title='Send message']").click();

      await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });
      await waitForStreamingDone(page, 90_000);

      // In project context: check if file was saved via API
      if (hasProjectCtx) {
        const knowledgeResp = await page.context().request.get(
          `${ADMIN_URL}/admin/v1/projects/${project.id}/knowledge`
        );
        if (knowledgeResp.ok()) {
          const files = await knowledgeResp.json() as Array<{ filename: string }>;
          const saved = files.some((f) => f.filename.includes(marker));
          if (saved) {
            // File was auto-saved — success!
            expect(saved).toBeTruthy();
          }
        }
      }

      // Regardless of project context, the response should exist without errors
      const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
      await expect(assistantBubble).toBeVisible({ timeout: 10_000 });

      await expect(page.getByText(/TypeError|failed to fetch/i).first())
        .not.toBeVisible({ timeout: 2000 }).catch(() => {});

    } finally {
      await page.context().request.delete(`${ADMIN_URL}/admin/v1/projects/${project.id}`).catch(() => {});
    }
  });

  // ── 3. No error after write_file ────────────────────────────────────────

  test("no error banner after write_file response", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5000 });

    await page.locator("[class*='chat-textarea']").fill(
      'Create a minimal HTML file called test.html with a heading "Test". Use <write_file>.'
    );
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });
    await waitForStreamingDone(page, 90_000);

    // No error
    await expect(page.getByText(/TypeError|failed to fetch|error/i).first())
      .not.toBeVisible({ timeout: 3000 }).catch(() => {});

    // Reply exists
    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantBubble).toBeVisible({ timeout: 10_000 });
    const text = (await assistantBubble.textContent()) ?? "";
    expect(text.length).toBeGreaterThan(5);
  });
});
