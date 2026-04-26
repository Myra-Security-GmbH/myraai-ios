/**
 * cors.spec.ts — Verifies the inference API returns correct CORS headers so
 * the frontend (ai.myra.eu or ai-int.myra.eu) can make cross-origin requests.
 *
 * Runs against both production and integration Docker stacks.
 */

import { test, expect } from "./base";

const base = process.env.PLAYWRIGHT_BASE_URL ?? "http://localhost:5173";

// Derive inference base from PLAYWRIGHT_GATEWAY_URL (set by int/prod configs)
// or fall back to the production URL.
const INFERENCE_BASE  = (process.env.PLAYWRIGHT_GATEWAY_URL ?? "https://ai-api.myra.eu").replace(/\/$/, "");
const FRONTEND_ORIGIN = base.replace(/\/$/, "");
const COMPAT_URL      = `${INFERENCE_BASE}/v1/myratest/prod/compat/chat/completions`;

// Skip when running against localhost (dev mode — Vite proxies, no CORS needed)
test.beforeEach(({}, testInfo) => {
  if (!base.includes("ai.myra.eu") && !base.includes("ai-int.myra.eu")) {
    testInfo.skip(true, "CORS tests only run against the live stack (set PLAYWRIGHT_BASE_URL to ai.myra.eu or ai-int.myra.eu)");
  }
});

test.describe("Inference API — CORS", () => {

  test("OPTIONS preflight returns 204 with correct CORS headers", async ({ request }) => {
    const res = await request.fetch(COMPAT_URL, {
      method: "OPTIONS",
      headers: {
        "Origin":                         FRONTEND_ORIGIN,
        "Access-Control-Request-Method":  "POST",
        "Access-Control-Request-Headers": "Authorization, Content-Type",
      },
    });

    expect(res.status()).toBe(204);

    const h = res.headers();
    expect(h["access-control-allow-origin"],      "allow-origin header").toBe(FRONTEND_ORIGIN);
    expect(h["access-control-allow-credentials"], "allow-credentials header").toBe("true");
    expect(h["access-control-allow-methods"],     "allow-methods header").toMatch(/POST/i);
    expect(h["access-control-allow-headers"],     "allow-headers header").toMatch(/Authorization/i);
  });

  test("inference response includes CORS headers", async ({ request }) => {
    // No valid token — a 401 is fine; we only care that CORS headers are present
    const res = await request.fetch(COMPAT_URL, {
      method: "POST",
      headers: {
        "Origin":        FRONTEND_ORIGIN,
        "Content-Type":  "application/json",
        "Authorization": "Bearer invalid",
      },
      data: JSON.stringify({ model: "claude-haiku-4-5", messages: [{ role: "user", content: "hi" }] }),
    });

    // 401 or 403 expected — we only assert the CORS header is present
    const h = res.headers();
    expect(h["access-control-allow-origin"], "allow-origin on non-200 response").toBe(FRONTEND_ORIGIN);
  });

  test("browser fetch to inference API is not blocked by CORS", async ({ page }) => {
    // Load the frontend so the browser origin is ai.myra.eu
    await page.goto("/playground");
    await page.waitForLoadState("networkidle");

    // page.evaluate runs inside the browser — any TypeError means CORS blocked it
    const result = await page.evaluate(async (url: string) => {
      try {
        const res = await fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/json", "Authorization": "Bearer invalid" },
          body: JSON.stringify({ model: "claude-haiku-4-5", messages: [{ role: "user", content: "hi" }] }),
        });
        // Any HTTP status means the browser received the response — CORS allowed it
        return { ok: true, status: res.status };
      } catch (e: any) {
        return { ok: false, error: String(e) };
      }
    }, COMPAT_URL);

    expect(result.ok, `CORS blocked the request: ${(result as any).error}`).toBe(true);
    // Must be an auth error (401/403), not a CORS error
    expect((result as any).status).toBeLessThan(500);
  });

});
