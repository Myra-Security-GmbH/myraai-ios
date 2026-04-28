/**
 * chat-qwen3-a3b.spec.ts — end-to-end tests for Qwen3.6-35B-A3B in the chat module.
 *
 * Gateway: myratest / prod-pii
 * Model:   qwen3.6-35b-a3b  (served by vllm-qwen3.6-A3B.service on port 8003,
 *                             routed via MODEL_PORTS in src/providers/vllm.lua)
 */

import { test, expect } from "./base";
import type {  Page  } from "./base";
import { deleteConversations, captureConvId } from "./helpers";

const ADMIN_URL      = process.env.PLAYWRIGHT_ADMIN_URL   ?? "https://ai-api-admin.myra.eu";
const GATEWAY_URL    = process.env.PLAYWRIGHT_GATEWAY_URL ?? "https://ai-api.myra.eu";
const TARGET_TENANT  = "myratest";
const TARGET_GATEWAY = "prod-pii";
const TARGET_MODEL   = "qwen3.6-35b-a3b";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Select myratest / prod-pii, then pick qwen3.6-35b-a3b from the ModelPicker. */
async function selectGatewayAndModel(page: Page): Promise<boolean> {
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  await expect(tenantSel).toContainText(TARGET_TENANT, { timeout: 10_000 });
  await tenantSel.selectOption({ label: TARGET_TENANT });
  await page.waitForTimeout(400);

  // Gateway — native select OR preset mode
  const hasGatewaySelect = await page.locator("select").nth(1)
    .isVisible({ timeout: 2000 }).catch(() => false);

  if (hasGatewaySelect) {
    const gatewaySel = page.locator("select").nth(1);
    await expect(gatewaySel).toContainText(TARGET_GATEWAY, { timeout: 10_000 });
    await gatewaySel.selectOption({ label: TARGET_GATEWAY });
    await page.waitForTimeout(400);
  } else {
    // Preset mode: find the preset for our target model via admin API and click its button.
    const tenantsResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
    if (!tenantsResp.ok()) return false;
    const tenantList = await tenantsResp.json() as Array<{
      id: string; slug: string;
      chat_presets?: Array<{ id: string; name: string; model: string; gateway_id: string }>;
    }>;
    const tenant = tenantList.find((t) => t.slug === TARGET_TENANT);
    if (!tenant) return false;
    const preset = (tenant.chat_presets ?? []).find((p) => p.model === TARGET_MODEL);
    if (!preset) return false;
    const presetBtn = page.locator("button").filter({ hasText: new RegExp(`^\\s*${preset.name}\\s*$`) });
    if (!(await presetBtn.isVisible({ timeout: 3000 }).catch(() => false))) return false;
    await presetBtn.click();
    await page.waitForTimeout(400);
    return true;
  }

  const modelBtn = page.locator("[aria-haspopup='listbox']");
  await modelBtn.waitFor({ state: "visible", timeout: 5000 });
  await modelBtn.click();

  const searchInput = page.locator("[role='listbox'] input[type='text'], [role='listbox'] input[type='search']");
  if (await searchInput.isVisible({ timeout: 2000 }).catch(() => false)) {
    await searchInput.fill(TARGET_MODEL);
    await page.waitForTimeout(300);
  }

  // Exact match: avoid picking e.g. "fireworks_ai/accounts/fireworks/models/qwen3.6-35b-a3b"
  const opt = page.locator("[role='listbox'] [role='option']")
    .filter({ hasText: new RegExp(`^\\s*${TARGET_MODEL}\\s*$`) })
    .first();
  if (!(await opt.isVisible({ timeout: 3000 }).catch(() => false))) {
    await page.keyboard.press("Escape");
    return false;
  }
  await opt.click();
  await page.waitForTimeout(300);
  return true;
}

/** Wait for the streaming stop-button to appear then disappear. */
async function waitForStreamingDone(page: Page, timeoutMs = 90_000) {
  await page.locator("button[title='Stop generating']")
    .waitFor({ state: "visible", timeout: 20_000 })
    .catch(() => {});
  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: timeoutMs });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe(`Chat — ${TARGET_MODEL} via ${TARGET_TENANT}/${TARGET_GATEWAY}`, () => {
  test.setTimeout(120_000);
  let convIds: string[] = [];

  test.beforeEach(async ({ page }) => {
    await page.goto("/chat");
    await page.waitForTimeout(600);
  });

  test.afterEach(async ({ page }) => {
    const id = captureConvId(page);
    if (id) convIds.push(id);
    await deleteConversations(page, convIds);
    convIds = [];
  });

  test("qwen3.6-35b-a3b appears in the ModelPicker for a vllm-enabled gateway", async ({ page, workerTenantId }) => {
    // myratest uses presets (no ModelPicker in config bar). Use the worker's own
    // e2e-tenant instead — no presets → normalMode → ModelPicker is always visible.
    // DB-1 configured e2e-gateway with provider_base_urls.vllm, so vllm models appear.
    await page.goto("/chat");

    const tenantSel = page.locator("select").first();
    await tenantSel.waitFor({ state: "visible", timeout: 5000 });
    // Wait for tenant options to load (API call may be async)
    await page.waitForFunction(
      (id) => Array.from(document.querySelectorAll("select option")).some((o) => (o as HTMLOptionElement).value === id),
      workerTenantId,
      { timeout: 8000 },
    ).catch(() => {});
    const optExists = (await tenantSel.locator(`option[value="${workerTenantId}"]`).count()) > 0;
    if (!optExists) { test.skip(true, "Worker tenant not in tenant dropdown"); return; }
    await tenantSel.selectOption({ value: workerTenantId });

    const gatewaySel = page.locator("select").nth(1);
    await gatewaySel.waitFor({ state: "visible", timeout: 5000 });
    if ((await gatewaySel.locator("option").count()) <= 1) {
      test.skip(true, "No gateway options for worker tenant"); return;
    }
    await gatewaySel.selectOption({ index: 1 });

    // ModelPicker must be visible in normalMode
    const modelBtn = page.locator("[aria-haspopup='listbox']");
    await modelBtn.waitFor({ state: "visible", timeout: 5000 });
    await modelBtn.click();

    const searchInput = page.locator("[role='listbox'] input[type='text'], [role='listbox'] input[type='search']");
    if (await searchInput.isVisible({ timeout: 2000 }).catch(() => false)) {
      await searchInput.fill(TARGET_MODEL);
      await page.waitForTimeout(300);
    }
    const opt = page.locator("[role='listbox'] [role='option']")
      .filter({ hasText: new RegExp(`^\\s*${TARGET_MODEL}\\s*$`) })
      .first();
    await expect(opt, `${TARGET_MODEL} must appear in the vllm ModelPicker`).toBeVisible({ timeout: 5000 });
    await page.keyboard.press("Escape");
  });

  test("selecting qwen3.6-35b-a3b is reflected in the config bar and localStorage", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    await page.waitForTimeout(200);
    const hasModelPicker = await page.locator("[aria-haspopup='listbox']").isVisible({ timeout: 1000 }).catch(() => false);
    if (hasModelPicker) {
      const label = (await page.locator("[aria-haspopup='listbox']").textContent() ?? "").trim();
      expect(label).toContain(TARGET_MODEL);
    }

    const stored = await page.evaluate((k) => localStorage.getItem(k), "aig-chat-model");
    expect(stored).toBe(TARGET_MODEL);
  });

  test("qwen3.6-35b-a3b selection survives a hard page reload", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    const hasModelPicker = await page.locator("[aria-haspopup='listbox']").isVisible({ timeout: 1000 }).catch(() => false);

    await page.waitForTimeout(200);
    await page.reload();
    await page.waitForTimeout(1200);

    if (hasModelPicker) {
      const label = (await page.locator("[aria-haspopup='listbox']").textContent() ?? "").trim();
      expect(label).toContain(TARGET_MODEL);
    } else {
      // Preset mode: verify the model is still stored in localStorage
      const stored = await page.evaluate((k) => localStorage.getItem(k), "aig-chat-model");
      expect(stored).toBe(TARGET_MODEL);
    }
  });

  test("structured analysis renders as inline markdown, not wrapped in an artifact card", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    expect(ok, "Could not select qwen3.6-35b-a3b on prod-pii — model unavailable").toBeTruthy();

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    // Prompt that triggers the Qwen3 tendency to wrap the whole answer in a ```markdown block
    await page.locator("[class*='chat-textarea']").fill(
      "Give a brief structured analysis with headers and bullet points: " +
      "what are 3 key benefits of zero-trust security architecture? Keep it short."
    );
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });
    await waitForStreamingDone(page, 60_000);

    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantBubble).toBeVisible({ timeout: 5_000 });

    const reply = (await assistantBubble.textContent()) ?? "";
    expect(reply.trim().length, "Expected a non-empty assistant response").toBeGreaterThan(20);

    // Regression: qwen3 used to wrap markdown analyses in ```markdown ... ``` with a filename
    // comment, causing the frontend to render the whole answer as a downloadable artifact card
    // instead of inline text. The system prompt now explicitly forbids this.
    const artifactCard = assistantBubble.locator("[data-cy='artifact-card']");
    await expect(artifactCard, "Response must not be wrapped as an artifact card").not.toBeVisible();

    await expect(page.getByText(/TypeError|failed to fetch/i).first())
      .not.toBeVisible({ timeout: 2_000 }).catch(() => {});
  });

  test("sends a message and receives a non-empty reply from qwen3.6-35b-a3b", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill("Reply with the single word: pong");
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });

    await waitForStreamingDone(page, 60_000);

    const assistantRow = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    await expect(assistantRow).toBeVisible({ timeout: 5000 });
    const reply = (await assistantRow.textContent() ?? "").trim();
    expect(reply.length).toBeGreaterThan(0);
  });

  // ── AGF-59: send button click regression guard ────────────────────────────

  test("send button click (not Enter) sends message and receives response", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    expect(ok, "Required gateway/model not available").toBeTruthy();

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill("Reply with exactly one word: hello");

    const sendBtn = page.locator("[data-cy='send-button']");
    await expect(sendBtn).toBeVisible({ timeout: 5000 });
    await expect(sendBtn).toBeEnabled({ timeout: 5000 });
    await sendBtn.click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });
    await waitForStreamingDone(page, 60_000);

    const assistantRow = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    await expect(assistantRow).toBeVisible({ timeout: 5000 });
    const reply = (await assistantRow.textContent() ?? "").trim();
    expect(reply.length, "Assistant must reply after send button click").toBeGreaterThan(0);

    await expect(page.getByText(/failed to fetch|TypeError/i).first())
      .not.toBeVisible({ timeout: 2000 }).catch(() => {});
  });

  test("send button is visible and not covered by any overlay", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    expect(ok, "Required gateway/model not available").toBeTruthy();

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill("test");

    const sendBtn = page.locator("[data-cy='send-button']");
    await expect(sendBtn).toBeVisible({ timeout: 5000 });

    const covered = await sendBtn.evaluate((el) => {
      const r = el.getBoundingClientRect();
      const cx = r.left + r.width / 2;
      const cy = r.top + r.height / 2;
      const top = document.elementFromPoint(cx, cy);
      return top !== null && !el.contains(top) && top !== el;
    });
    expect(covered, "Send button must not be covered by any overlay element").toBe(false);
  });

  test("rapid double-click on send does not leave chat in broken state", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    expect(ok, "Required gateway/model not available").toBeTruthy();

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill("Reply with one word: ping");

    // Click twice in rapid succession — second click may hit Stop, cancelling the stream
    const sendBtn = page.locator("[data-cy='send-button']");
    await sendBtn.click();
    await sendBtn.click();

    // Wait for any in-progress streaming to settle
    await page.locator("button[title='Send message']")
      .waitFor({ state: "visible", timeout: 90_000 });

    // Now send a fresh message via Enter to confirm the chat is still functional
    await page.locator("[class*='chat-textarea']").fill("Reply with one word: pong");
    await page.locator("[class*='chat-textarea']").press("Enter");

    await expect(page.locator("[class*='user-row']").last()).toBeVisible({ timeout: 10_000 });
    await waitForStreamingDone(page, 60_000);

    const assistantRows = page.locator("[class*='bubble-row']:not([class*='user-row'])");
    await expect(assistantRows.last()).toBeVisible({ timeout: 5000 });
    const lastReply = (await assistantRows.last().textContent() ?? "").trim();
    expect(lastReply.length, "Chat must still work after rapid double-click").toBeGreaterThan(0);

    await expect(page.getByText(/failed to fetch|TypeError/i).first())
      .not.toBeVisible({ timeout: 2000 }).catch(() => {});
  });
});

// ---------------------------------------------------------------------------
// Regression: <think> tags must not appear in streaming output (AGF-feedback 2026-04-28)
//
// Qwen3-family models embed thinking tokens in delta.content as <think>...</think>
// blocks.  The vllm provider's parse_sse_chunk must strip them before they reach
// the client.  This test calls the compat streaming endpoint directly and asserts
// that the accumulated delta.content contains no think tags.
// ---------------------------------------------------------------------------

interface PlaygroundToken {
  token: string;
  tenant_slug: string;
  gateway_slug: string;
  expires_at: string;
}

async function getPlaygroundToken(page: Page): Promise<PlaygroundToken> {
  const tenantsResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
  expect(tenantsResp.ok(), `GET /tenants failed: ${tenantsResp.status()}`).toBeTruthy();
  const tenants = await tenantsResp.json() as Array<{ id: string; slug: string }>;
  const tenant = tenants.find((t) => t.slug === TARGET_TENANT);
  expect(tenant, `Tenant ${TARGET_TENANT} not found`).toBeTruthy();

  const gwResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants/${tenant!.id}/gateways`);
  expect(gwResp.ok(), `GET /gateways failed: ${gwResp.status()}`).toBeTruthy();
  const gateways = await gwResp.json() as Array<{ id: string; slug: string }>;
  const gw = gateways.find((g) => g.slug === TARGET_GATEWAY);
  expect(gw, `Gateway ${TARGET_GATEWAY} not found`).toBeTruthy();

  const tokResp = await page.context().request.post(`${ADMIN_URL}/admin/v1/playground/token`, {
    data: { gateway_id: gw!.id },
  });
  expect(tokResp.ok(), `POST /playground/token failed: ${tokResp.status()}`).toBeTruthy();
  return tokResp.json() as Promise<PlaygroundToken>;
}

async function streamCompatMessage(page: Page, tok: PlaygroundToken, prompt: string): Promise<string> {
  const url = `${GATEWAY_URL}/v1/${tok.tenant_slug}/${tok.gateway_slug}/compat/chat/completions`;
  const resp = await page.context().request.fetch(url, {
    method:  "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${tok.token}` },
    data:    JSON.stringify({ model: TARGET_MODEL, messages: [{ role: "user", content: prompt }], stream: true }),
    timeout: 90_000,
  });
  const body = await resp.text();
  expect(resp.status(), `Compat endpoint returned ${resp.status()}: ${body.slice(0, 300)}`).toBe(200);

  let accumulated = "";
  for (const line of body.split("\n")) {
    const m = line.match(/^data:\s*(.+)$/);
    if (!m || m[1] === "[DONE]") continue;
    try {
      const parsed = JSON.parse(m[1]);
      if (parsed.aig_tool_call || parsed.aig_status) continue;
      accumulated += (parsed?.choices?.[0]?.delta?.content ?? "") as string;
    } catch { /* skip malformed chunk */ }
  }
  return accumulated;
}

test.describe(`${TARGET_MODEL} — no <think> tags in compat streaming output`, () => {
  test.setTimeout(120_000);

  test("<think> and </think> do not appear in streaming response", async ({ page }) => {
    await page.goto("/chat");
    const tok = await getPlaygroundToken(page);
    const text = await streamCompatMessage(page, tok, "Reply with exactly one word: hello");

    expect(text.length, "Expected a non-empty response from the model").toBeGreaterThan(0);
    expect(
      text,
      `Response must not contain <think>: "${text.slice(0, 500)}"`
    ).not.toContain("<think>");
    expect(
      text,
      `Response must not contain </think>: "${text.slice(0, 500)}"`
    ).not.toContain("</think>");
  });
});
