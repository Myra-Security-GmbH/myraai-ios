/**
 * chat-sonnet-format.spec.ts — regression tests for claude-sonnet-4-6 response formatting.
 *
 * Guards against the model wrapping prose answers in fenced code blocks, which causes
 * the frontend to render the entire response as a downloadable artifact card instead of
 * inline markdown text. (Root cause: the system prompt previously lacked an explicit
 * prohibition on code-fence-wrapping prose responses.)
 *
 * Preset: "PII claude-sonnet-4-6" → prod-pii gateway + claude-sonnet-4-6
 */

import { test, expect, Page } from "@playwright/test";

const ADMIN_URL     = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TARGET_TENANT = "myratest";
const TARGET_PRESET = "PII claude-sonnet-4-6";

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

async function selectPreset(page: Page): Promise<boolean> {
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  const tenantOpt = tenantSel.locator("option").filter({ hasText: new RegExp(TARGET_TENANT, "i") });
  if ((await tenantOpt.count()) === 0) return false;
  await tenantSel.selectOption({ label: (await tenantOpt.first().textContent()) ?? TARGET_TENANT });
  await page.waitForTimeout(600);

  const presetBtn = page.locator("button").filter({
    hasText: new RegExp(TARGET_PRESET.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i"),
  });
  const visible = await presetBtn.isVisible({ timeout: 5000 }).catch(() => false);
  if (!visible) return false;
  await presetBtn.click();
  await page.waitForTimeout(400);
  return true;
}

async function waitForStreamingDone(page: Page, timeoutMs = 90_000) {
  await page.locator("button[title='Stop generating']")
    .waitFor({ state: "visible", timeout: 30_000 }).catch(() => {});
  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: timeoutMs });
}

test.describe(`Chat — ${TARGET_PRESET} response formatting`, () => {
  let testStartTime: number;
  test.setTimeout(120_000);

  test.beforeEach(async ({ page }) => {
    testStartTime = Date.now();
    await page.goto("/chat");
    await page.waitForTimeout(600);
  });

  test.afterEach(async ({ page }) => {
    await deleteAllConversations(page, testStartTime);
  });

  test("structured analysis renders as inline markdown, not wrapped in an artifact card", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Could not select preset "${TARGET_PRESET}" — check myratest tenant config`).toBeTruthy();

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill(
      "Give a brief structured analysis with headers and bullet points: " +
      "what are 3 key benefits of zero-trust security architecture? Keep it short."
    );
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });
    await waitForStreamingDone(page, 90_000);

    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantBubble).toBeVisible({ timeout: 10_000 });

    const reply = (await assistantBubble.textContent()) ?? "";
    expect(reply.trim().length, "Expected a non-empty assistant response").toBeGreaterThan(20);

    // The entire response must NOT be rendered as an artifact card.
    // (Regression: a model wrapping its whole answer in ```markdown ... ``` with a filename
    // comment triggers ArtifactCard rendering, surfacing a Download button instead of text.)
    const artifactCard = assistantBubble.locator("[data-cy='artifact-card']");
    await expect(artifactCard, "Response must not be wrapped as an artifact card").not.toBeVisible();

    await expect(page.getByText(/TypeError|failed to fetch/i).first())
      .not.toBeVisible({ timeout: 2_000 }).catch(() => {});
  });

  test("plain conversational reply renders as inline text with no artifact card", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Could not select preset "${TARGET_PRESET}" — check myratest tenant config`).toBeTruthy();

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill("What is 2 + 2? Answer in one sentence.");
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });
    await waitForStreamingDone(page, 60_000);

    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantBubble).toBeVisible({ timeout: 10_000 });

    const reply = (await assistantBubble.textContent()) ?? "";
    expect(reply.trim().length, "Expected a non-empty assistant response").toBeGreaterThan(0);

    const artifactCard = assistantBubble.locator("[data-cy='artifact-card']");
    await expect(artifactCard).not.toBeVisible();

    await expect(page.getByText(/TypeError|failed to fetch/i).first())
      .not.toBeVisible({ timeout: 2_000 }).catch(() => {});
  });

  test("write_file request correctly produces an artifact card (positive case)", async ({ page }) => {
    const ok = await selectPreset(page);
    expect(ok, `Could not select preset "${TARGET_PRESET}" — check myratest tenant config`).toBeTruthy();

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill(
      'Create a file called hello.py that prints "Hello World". Use the <write_file> tag.'
    );
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });
    await waitForStreamingDone(page, 90_000);

    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantBubble).toBeVisible({ timeout: 10_000 });

    // When the model is explicitly asked to create a file, the artifact card SHOULD appear.
    const artifactCard = assistantBubble.locator("[data-cy='artifact-card']");
    await expect(artifactCard, "Expected artifact card for an explicit write_file request").toBeVisible({ timeout: 10_000 });

    await expect(page.getByText(/TypeError|failed to fetch/i).first())
      .not.toBeVisible({ timeout: 2_000 }).catch(() => {});
  });
});
