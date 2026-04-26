/**
 * chat-anthropic-think-tag.spec.ts
 *
 * Regression test for: `</think>` appearing literally in chat output when an
 * Anthropic model (claude-sonnet-4-6) calls the web_search tool.
 *
 * Root cause:
 *   anthropic.lua always injects the web_search_20250305 tool into every compat
 *   request.  When the model calls it, Anthropic returns two content blocks:
 *     index 0 → tool_use (web_search)
 *     index 1 → text (the answer)
 *   The old parse_sse_chunk used `chunk.index > 0` to decide whether to emit
 *   `</think>`.  Index > 0 fired on the text block even though no `<think>` was
 *   ever opened → `thinking.strip("</think>", false)` did not strip it
 *   → literal `</think>` passed through to the client.
 *
 * Fix: parse_sse_chunk now receives a per-stream `st` table (allocated once per
 * stream in upstream.lua) and tracks `st.thinking_opened`.  `</think>` is only
 * emitted when `st.thinking_opened` is true — i.e., when a thinking block was
 * actually opened earlier in the same stream.
 *
 * Test strategy (API-level, no inference result assertion needed):
 *   1. Obtain a playground token for the prod (Anthropic) gateway.
 *   2. POST a current-events question directly to the compat streaming endpoint.
 *      A current-events question reliably triggers the web_search tool.
 *   3. Collect every SSE `data:` line from the stream.
 *   4. Accumulate all `choices[0].delta.content` chunks.
 *   5. Assert the accumulated text does NOT contain the literal string `</think>`.
 *   6. Assert a non-empty response was received (the model answered).
 */

import { test, expect, type Page } from "./base";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const ADMIN_URL   = process.env.PLAYWRIGHT_ADMIN_URL   ?? "https://ai-api-admin.myra.eu";
const GATEWAY_URL = process.env.PLAYWRIGHT_GATEWAY_URL ?? "https://ai-api.myra.eu";

const TARGET_TENANT  = "myratest";
const TARGET_GATEWAY = "prod-pii";  // Anthropic (claude-sonnet-4-6) gateway slug
const TARGET_MODEL   = "claude-sonnet-4-6";

// A question that reliably causes Claude to invoke the web_search tool
const TRIGGER_PROMPT = "What is today's date and what is one major news headline right now?";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

interface PlaygroundToken {
  token: string;
  tenant_slug: string;
  gateway_slug: string;
  expires_at: string;
}

async function getPlaygroundToken(page: Page): Promise<PlaygroundToken | null> {
  // Resolve gateway id from slug
  const tenantsResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
  if (!tenantsResp.ok()) return null;
  const tenants = await tenantsResp.json() as Array<{ id: string; slug: string }>;
  const tenant = tenants.find((t) => t.slug === TARGET_TENANT);
  if (!tenant) return null;

  const gwResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants/${tenant.id}/gateways`);
  if (!gwResp.ok()) return null;
  const gateways = await gwResp.json() as Array<{ id: string; slug: string }>;
  const gw = gateways.find((g) => g.slug === TARGET_GATEWAY);
  if (!gw) return null;

  const tokResp = await page.context().request.post(`${ADMIN_URL}/admin/v1/playground/token`, {
    data: { gateway_id: gw.id },
  });
  if (!tokResp.ok()) return null;
  return tokResp.json() as Promise<PlaygroundToken>;
}

/**
 * Stream a single message through the compat endpoint and return the
 * accumulated response text.  Throws if the HTTP status is not 200.
 */
async function streamMessage(page: Page, tok: PlaygroundToken, prompt: string): Promise<string> {
  const url = `${GATEWAY_URL}/v1/${tok.tenant_slug}/${tok.gateway_slug}/compat/chat/completions`;

  const resp = await page.context().request.fetch(url, {
    method: "POST",
    headers: {
      "Content-Type":  "application/json",
      "Authorization": `Bearer ${tok.token}`,
    },
    data: JSON.stringify({
      model:    TARGET_MODEL,
      messages: [{ role: "user", content: prompt }],
      stream:   true,
    }),
  });

  const body = await resp.text();
  expect(resp.status(), `Compat endpoint returned ${resp.status()}: ${body.slice(0, 300)}`).toBe(200);

  const raw = body;

  // Parse SSE: extract delta.content from every data: line
  let accumulated = "";
  for (const line of raw.split("\n")) {
    const data = line.match(/^data:\s*(.+)$/);
    if (!data || data[1] === "[DONE]") continue;
    try {
      const parsed = JSON.parse(data[1]);
      // Skip gateway meta events (aig_tool_call, aig_status, etc.)
      if (parsed.aig_tool_call || parsed.aig_status) continue;
      const content: string = parsed?.choices?.[0]?.delta?.content ?? "";
      accumulated += content;
    } catch { /* malformed chunk — skip */ }
  }

  return accumulated;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Anthropic — no spurious </think> in compat output", () => {
  test.setTimeout(120_000);

  test("</think> does not appear in compat response when web_search tool fires", async ({ page }) => {
    // Navigate first so the session cookie is attached to the page context
    await page.goto("/chat");

    const tok = await getPlaygroundToken(page);
    expect(tok, "Could not obtain playground token for prod gateway").toBeTruthy();

    const text = await streamMessage(page, tok!, TRIGGER_PROMPT);

    expect(text.length, "Expected a non-empty response from the model").toBeGreaterThan(10);

    // Core regression assertion: the literal tag must not appear in the output
    expect(
      text,
      `Response must not contain literal </think> — got: "${text.slice(0, 300)}"`
    ).not.toContain("</think>");

    // Also assert <think> is absent (no orphaned opening tag either)
    expect(
      text,
      `Response must not contain literal <think> — got: "${text.slice(0, 300)}"`
    ).not.toContain("<think>");
  });

  test("</think> does not appear in a simple non-search response", async ({ page }) => {
    // Even when no tool fires the stream must be clean
    await page.goto("/chat");

    const tok = await getPlaygroundToken(page);
    expect(tok, "Could not obtain playground token for prod gateway").toBeTruthy();

    const text = await streamMessage(page, tok!, "Reply with exactly three words: yes no maybe");

    expect(text.length, "Expected a non-empty response").toBeGreaterThan(0);
    expect(text, `Response must not contain </think>: "${text}"`).not.toContain("</think>");
    expect(text, `Response must not contain <think>: "${text}"`).not.toContain("<think>");
  });
});
