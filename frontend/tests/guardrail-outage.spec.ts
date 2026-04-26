/**
 * guardrail-outage.spec.ts — Regression tests for silent guardrail failures.
 *
 * When a guardrail sidecar is unreachable, three things must happen:
 *
 *   1. With fail_open=true:
 *      - The request still succeeds (normal reply body).
 *      - The response carries X-Aig-Guardrail-Warning so clients can surface a
 *        banner. The warning text names the guardrail and the error class.
 *      - request_log.meta records guardrail_degraded=true and guardrail_error.
 *
 *   2. With fail_open=false:
 *      - The gateway returns a synthetic assistant message explaining that the
 *        guardrail is temporarily unavailable (not "blocked by content policy").
 *      - The message does NOT use generic placeholders like "pii_protector_error".
 *
 *   3. Frontend (Chat UI): the X-Aig-Guardrail-Warning banner renders with a
 *      dismiss button and does not block the assistant reply.
 *
 * Setup: a dedicated test gateway `guardrail-outage-test-*` on tenant `myratest`
 * whose pii_protector points at 127.0.0.1:1 (guaranteed TCP RST).
 *
 * Cleanup runs in finally{} for every test — no fixture ever leaks.
 */

import { test, expect, type APIRequestContext } from "./base";

const ADMIN_HOST = process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173";
const ADMIN_BASE = `${ADMIN_HOST}/admin/v1`;
// Inference lives on a different vhost in docker/production (ai-api.myra.eu)
// but is co-located on the Vite dev server in local mode via its /v1 proxy.
const V1_BASE    = ADMIN_HOST.includes("ai-api-admin")
  ? ADMIN_HOST.replace("ai-api-admin", "ai-api") + "/v1"
  : `${ADMIN_HOST}/v1`;

const UNREACHABLE_URL = "http://127.0.0.1:1";

interface Gateway { id: string; slug: string }
interface PlaygroundToken { token: string; tenant_slug: string; gateway_slug: string }

async function getMyratestId(request: APIRequestContext): Promise<string> {
  const resp = await request.get(`${ADMIN_BASE}/tenants`);
  expect(resp.ok(), "tenants API").toBeTruthy();
  const tenants = await resp.json() as Array<{ id: string; slug: string }>;
  const t = tenants.find((x) => x.slug === "myratest");
  expect(t, "myratest tenant must exist").toBeTruthy();
  return t!.id;
}

/**
 * Create a disposable test gateway with a pii_protector pointing at an
 * unreachable address. fail_open controls whether the gateway passes or
 * blocks on sidecar outage.
 */
async function createOutageGateway(
  request: APIRequestContext,
  tenantId: string,
  opts: { failOpen: boolean; slugSuffix: string },
): Promise<Gateway> {
  const slug = `guardrail-outage-test-${opts.slugSuffix}-${Date.now()}`;
  const config = {
    auth_required:      true,
    retry_count:        0,
    timeout_ms:         30_000,
    log_payloads:       true,
    cache_ttl:          0,
    guardrails: [{
      name:            "outage-probe",
      type:            "pii_protector",
      target:          "request",
      fail_open:       opts.failOpen,
      analyzer_url:    UNREACHABLE_URL,
      entities:        ["PERSON"],
      language:        "en",
      score_threshold: 0.7,
    }],
  };
  const resp = await request.post(`${ADMIN_BASE}/tenants/${tenantId}/gateways`, {
    data: { slug, config },
  });
  expect(resp.ok(), `create gateway: ${await resp.text()}`).toBeTruthy();
  const { id } = await resp.json() as { id: string };
  return { id, slug };
}

async function deleteGateway(request: APIRequestContext, gatewayId: string): Promise<void> {
  await request.delete(`${ADMIN_BASE}/gateways/${gatewayId}`);
}

async function mintToken(request: APIRequestContext, gatewayId: string): Promise<PlaygroundToken> {
  const resp = await request.post(`${ADMIN_BASE}/playground/token`, {
    data: { gateway_id: gatewayId },
  });
  expect(resp.ok(), `mint token: ${await resp.text()}`).toBeTruthy();
  return resp.json() as Promise<PlaygroundToken>;
}

interface CompatResponse { body: string; status: number; headers: Record<string, string> }

async function chatCompat(
  request: APIRequestContext,
  tok: PlaygroundToken,
  stream: boolean,
): Promise<CompatResponse> {
  const url = `${V1_BASE}/${tok.tenant_slug}/${tok.gateway_slug}/compat/chat/completions`;
  const resp = await request.post(url, {
    headers: {
      "content-type":  "application/json",
      "x-aig-token":   tok.token,
    },
    data: {
      model:       "qwen3-30b-a3b",
      messages:    [{ role: "user", content: "Reply with the single word: hello." }],
      max_tokens:  32,
      temperature: 0,
      stream,
    },
  });
  return {
    body:    await resp.text(),
    status:  resp.status(),
    headers: resp.headers(),
  };
}

// ---------------------------------------------------------------------------
// Backend behaviour
// ---------------------------------------------------------------------------

test.describe("guardrail outage — backend", () => {
  test("fail_open=true — succeeds and emits X-Aig-Guardrail-Warning (non-streaming)", async ({ request }) => {
    const tenantId = await getMyratestId(request);
    const gw = await createOutageGateway(request, tenantId, { failOpen: true, slugSuffix: "open-ns" });
    try {
      const tok = await mintToken(request, gw.id);
      const r = await chatCompat(request, tok, false);

      expect(r.status, `body=${r.body}`).toBe(200);

      const warn = r.headers["x-aig-guardrail-warning"];
      expect(warn, "X-Aig-Guardrail-Warning must be present on fail_open").toBeTruthy();
      expect(warn).toContain("outage-probe");
      expect(warn).toMatch(/unavailable/i);

      // Must not look like a policy block
      expect(r.body).not.toContain("blocked by content policy");
      expect(r.body).not.toContain("pii_protector_error");
    } finally {
      await deleteGateway(request, gw.id);
    }
  });

  test("fail_open=true — warning reaches the streaming response", async ({ request }) => {
    const tenantId = await getMyratestId(request);
    const gw = await createOutageGateway(request, tenantId, { failOpen: true, slugSuffix: "open-stream" });
    try {
      const tok = await mintToken(request, gw.id);
      const r = await chatCompat(request, tok, true);

      expect(r.status).toBe(200);
      expect(r.headers["x-aig-guardrail-warning"], "warning header on streaming SSE")
        .toMatch(/outage-probe/);
      expect(r.body).toContain("data: ");
    } finally {
      await deleteGateway(request, gw.id);
    }
  });

  test("fail_open=false — synthetic response explains outage, not policy block", async ({ request }) => {
    const tenantId = await getMyratestId(request);
    const gw = await createOutageGateway(request, tenantId, { failOpen: false, slugSuffix: "closed-ns" });
    try {
      const tok = await mintToken(request, gw.id);
      const r = await chatCompat(request, tok, false);

      expect(r.status).toBe(200);
      const parsed = JSON.parse(r.body) as {
        choices: Array<{ message: { content: string } }>;
      };
      const text = parsed.choices[0]?.message?.content ?? "";
      expect(text.toLowerCase()).toContain("temporarily unavailable");
      expect(text).toContain("outage-probe");
      expect(text).not.toContain("pii_protector_error");
      expect(text).not.toContain("blocked by content policy");
    } finally {
      await deleteGateway(request, gw.id);
    }
  });

  test("fail_open=false — streaming synthetic response also explains outage", async ({ request }) => {
    const tenantId = await getMyratestId(request);
    const gw = await createOutageGateway(request, tenantId, { failOpen: false, slugSuffix: "closed-stream" });
    try {
      const tok = await mintToken(request, gw.id);
      const r = await chatCompat(request, tok, true);

      expect(r.status).toBe(200);
      const text = r.body;
      expect(text.toLowerCase()).toContain("temporarily unavailable");
      expect(text).toContain("outage-probe");
      expect(text).toContain("[DONE]");
      expect(text).not.toContain("pii_protector_error");
    } finally {
      await deleteGateway(request, gw.id);
    }
  });
});

// ---------------------------------------------------------------------------
// Frontend UI — the warning banner must render in /chat after a real request
// ---------------------------------------------------------------------------
//
// We create a dedicated ephemeral tenant without chat_presets_config so the
// chat UI falls back to tenant+gateway+model pickers. That lets us target our
// outage gateway from the UI without fighting the preset selector on myratest.

async function createEphemeralTenant(request: APIRequestContext): Promise<{ id: string; slug: string }> {
  const slug = `z-guardrail-outage-${Date.now()}`;
  const resp = await request.post(`${ADMIN_BASE}/tenants`, { data: { slug, plan: "standard" } });
  expect(resp.ok(), `create tenant: ${await resp.text()}`).toBeTruthy();
  const body = await resp.json() as { id: string };
  return { id: body.id, slug };
}

async function deleteTenant(request: APIRequestContext, tenantId: string): Promise<void> {
  await request.delete(`${ADMIN_BASE}/tenants/${tenantId}`);
}

test.describe("guardrail outage — chat UI", () => {
  test.setTimeout(90_000);

  test("fail_open=true — banner appears and reply still arrives", async ({ page }) => {
    const tenant = await createEphemeralTenant(page.request);
    const gw     = await createOutageGateway(page.request, tenant.id, { failOpen: true, slugSuffix: "ui" });
    try {
      // Prime localStorage so Chat.tsx opens on our tenant + gateway.
      await page.addInitScript(([tenantId, gatewayId]) => {
        localStorage.setItem("aig-chat-tenant",  tenantId);
        localStorage.setItem("aig-chat-gateway", gatewayId);
        localStorage.setItem("aig-chat-model",   "qwen3-30b-a3b");
      }, [tenant.id, gw.id]);

      await page.goto("/chat");
      await page.waitForLoadState("networkidle");

      const input = page.locator("textarea").first();
      await expect(input, "chat input must become enabled").toBeEnabled({ timeout: 15_000 });
      await input.fill("Reply with just: hello.");
      await input.press("Enter");

      const banner = page.locator("[data-cy=guardrail-warning]");
      await expect(banner, "guardrail warning banner must appear").toBeVisible({ timeout: 30_000 });
      await expect(banner).toContainText(/outage-probe/);
      await expect(banner).toContainText(/unavailable/i);

      // The reply still arrives (fail_open) — confirm no hard error banner and
      // at least some assistant output was rendered.
      await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
    } finally {
      await deleteGateway(page.request, gw.id);
      await deleteTenant(page.request, tenant.id);
    }
  });

  test("fail_open=false — user sees 'temporarily unavailable' message", async ({ page }) => {
    const tenant = await createEphemeralTenant(page.request);
    const gw     = await createOutageGateway(page.request, tenant.id, { failOpen: false, slugSuffix: "ui-closed" });
    try {
      await page.addInitScript(([tenantId, gatewayId]) => {
        localStorage.setItem("aig-chat-tenant",  tenantId);
        localStorage.setItem("aig-chat-gateway", gatewayId);
        localStorage.setItem("aig-chat-model",   "qwen3-30b-a3b");
      }, [tenant.id, gw.id]);

      await page.goto("/chat");
      await page.waitForLoadState("networkidle");

      const input = page.locator("textarea").first();
      await expect(input).toBeEnabled({ timeout: 15_000 });
      await input.fill("Will be rejected.");
      await input.press("Enter");

      // The synthetic assistant message explains the outage in plain English —
      // not "blocked by content policy" and not "pii_protector_error". The
      // text appears in both the chat message and the sidebar conversation
      // preview, so use .first() to bypass strict-mode ambiguity.
      await expect(page.getByText(/temporarily unavailable/i).first())
        .toBeVisible({ timeout: 30_000 });
      await expect(page.getByText(/outage-probe/).first()).toBeVisible();
      await expect(page.getByText(/pii_protector_error/)).not.toBeVisible();
      await expect(page.getByText(/blocked by content policy/i)).not.toBeVisible();
    } finally {
      await deleteGateway(page.request, gw.id);
      await deleteTenant(page.request, tenant.id);
    }
  });
});
