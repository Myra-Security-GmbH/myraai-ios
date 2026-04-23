/**
 * chat-anthropic-caching.spec.ts
 *
 * Verifies that Anthropic prompt caching actually works end-to-end through the
 * gateway when a gateway has prompt_caching.enabled=true.
 *
 * Strategy:
 *   1. Find a gateway with the Anthropic provider and prompt_caching enabled.
 *   2. Send a request with a large, stable system prompt so Anthropic has
 *      enough tokens to cache (minimum ~1024 tokens).
 *   3. Repeat the IDENTICAL request.
 *   4. Check the admin logs API: first request must have cache_creation_tokens > 0,
 *      second request must have cache_read_tokens > 0.
 *
 * This test guards against the regression where tool-level cache_control TTL
 * mismatches (5m from the client vs 1h injected by the gateway) caused Anthropic
 * to silently drop all caching — resulting in every request being charged at full
 * input token cost.
 *
 * The test calls the gateway inference API directly (not via the chat UI) so it
 * can construct a precise request and inspect the log entries.
 */

import { test, expect } from "@playwright/test";

const ADMIN_URL    = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const GATEWAY_URL  = process.env.PLAYWRIGHT_GATEWAY_URL ?? "https://ai-api.myra.eu";
const TARGET_MODEL = "claude-sonnet-4-6";

// Large enough system prompt to reach Anthropic's minimum cacheable size (~1 024 tokens).
// A random run ID is embedded so the system prompt is unique per test run, which guarantees
// cache_creation_tokens > 0 on the first request regardless of prior runs.
// Both requests in a single run use the SAME prompt so the second one reads from cache.
const RUN_ID = Math.random().toString(36).slice(2);
const STABLE_SYSTEM_PROMPT = `You are a precise technical assistant specialising in software architecture.
Run ID: ${RUN_ID}

## Core principles
- Always respond in clear, structured prose.
- Cite evidence before drawing conclusions.
- When uncertain, say so explicitly.
- Prefer tables for comparative information.
- Never fabricate facts or API details.

## Domain knowledge summary
${"The following is a detailed description of software architecture best practices. ".repeat(60)}

## Response format
Respond in plain English. Do not use bullet lists unless the user explicitly asks.
Keep answers under 300 words unless depth is required.`;

interface InferenceUsage {
  prompt_tokens: number;
  completion_tokens: number;
  cache_creation_tokens: number;
  cache_read_tokens: number;
}

interface Gateway {
  id: string;
  slug: string;
  config: Record<string, unknown>;
}

interface Tenant {
  id: string;
  slug: string;
}

interface PlaygroundToken {
  token: string;
  tenant_slug: string;
  gateway_slug: string;
}

async function findAnthropicCachingGateway(
  page: import("@playwright/test").Page
): Promise<{ tenantSlug: string; gatewaySlug: string; gatewayId: string } | null> {
  const tenantsResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
  if (!tenantsResp.ok()) return null;
  const tenants = (await tenantsResp.json()) as Tenant[];

  for (const tenant of tenants) {
    const gwResp = await page.context().request.get(
      `${ADMIN_URL}/admin/v1/tenants/${tenant.id}/gateways`
    );
    if (!gwResp.ok()) continue;
    const gws = (await gwResp.json()) as Gateway[];
    for (const gw of gws) {
      const cfg = gw.config as {
        prompt_caching?: { enabled?: boolean };
        provider_base_urls?: Record<string, string>;
      };
      // Must have prompt_caching.enabled=true and be an Anthropic gateway
      // (no vllm/provider_base_urls override pointing elsewhere).
      const hasCache = cfg?.prompt_caching?.enabled === true;
      const isAnthropic = !cfg?.provider_base_urls;
      if (hasCache && isAnthropic) {
        return { tenantSlug: tenant.slug, gatewaySlug: gw.slug, gatewayId: gw.id };
      }
    }
  }
  return null;
}

async function getPlayToken(
  page: import("@playwright/test").Page,
  gatewayId: string
): Promise<PlaygroundToken | null> {
  const resp = await page.context().request.post(
    `${ADMIN_URL}/admin/v1/playground/token`,
    { data: { gateway_id: gatewayId } }
  );
  if (!resp.ok()) return null;
  return (await resp.json()) as PlaygroundToken;
}

async function sendInference(
  page: import("@playwright/test").Page,
  tok: PlaygroundToken,
  systemPrompt: string,
  userMessage: string
): Promise<InferenceUsage | null> {
  const url = `${GATEWAY_URL}/v1/${tok.tenant_slug}/${tok.gateway_slug}/compat/chat/completions`;
  const resp = await page.context().request.post(url, {
    data: {
      model:      TARGET_MODEL,
      max_tokens: 64,
      stream:     false,
      messages: [
        { role: "system",  content: systemPrompt },
        { role: "user",    content: userMessage  },
      ],
    },
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${tok.token}`,
    },
    timeout: 60_000,
  });
  if (!resp.ok()) return null;
  const body = await resp.json() as { usage?: InferenceUsage };
  return body.usage ?? null;
}


test.describe("Anthropic prompt caching — end-to-end", () => {
  test.setTimeout(120_000);

  test("first request creates cache, second request reads from cache", async ({ page }) => {
    const gw = await findAnthropicCachingGateway(page);
    if (!gw) {
      throw new Error(
        "No Anthropic gateway with prompt_caching.enabled=true found — " +
        "configure one before running this test"
      );
    }

    const tok = await getPlayToken(page, gw.gatewayId);
    if (!tok) throw new Error(`Could not get playground token for gateway ${gw.gatewayId}`);

    // Different user messages prevent the gateway's own response cache from
    // short-circuiting request 2. The system prompt is identical so Anthropic
    // can still read it from its prompt cache on the second call.
    const userMsg1 = "Repeat the first sentence of your system prompt. [req-1]";
    const userMsg2 = "Repeat the first sentence of your system prompt. [req-2]";

    // ── Request 1: should create cache ───────────────────────────────────────
    const usage1 = await sendInference(page, tok, STABLE_SYSTEM_PROMPT, userMsg1);
    expect(usage1, "First inference request failed").not.toBeNull();

    expect(
      usage1!.cache_creation_tokens,
      `First request must create cache entries — got cache_creation_tokens=${usage1!.cache_creation_tokens}. ` +
      `If this is 0, cache_control injection is broken (the 5m→1h TTL mismatch regression).`
    ).toBeGreaterThan(0);

    // ── Request 2 (different user msg, same system prompt): should read from cache
    const usage2 = await sendInference(page, tok, STABLE_SYSTEM_PROMPT, userMsg2);
    expect(usage2, "Second inference request failed").not.toBeNull();

    expect(
      usage2!.cache_read_tokens,
      `Second identical request must read from cache — got cache_read_tokens=${usage2!.cache_read_tokens}. ` +
      `If this is 0, the cache key is not stable across requests (check system prompt normalisation).`
    ).toBeGreaterThan(0);
  });
});
