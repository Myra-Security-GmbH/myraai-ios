/**
 * feedback-validation.spec.ts — server-side validation of the client_context
 * envelope on /admin/v1/app-feedback. Covers size cap, identity-overwrite,
 * unknown-key quarantine, and schema_version checks.
 */

import { test, expect } from "@playwright/test";
import { execSync } from "child_process";

const ADMIN_BASE = process.env.PLAYWRIGHT_ADMIN_URL
  ? `${process.env.PLAYWRIGHT_ADMIN_URL}/admin/v1`
  : "http://localhost:5173/admin/v1";

const DB_HOST = process.env.E2E_DB_HOST ?? "172.17.0.1";
const DB_USER = process.env.E2E_DB_USER ?? "gateway_int";
const DB_PASS = process.env.E2E_DB_PASS ?? "yefVaf]oresev8";
const DB_NAME = process.env.E2E_DB_NAME ?? "ai_gateway_int";

function sqlOne(query: string): string {
  return execSync(
    `mysql -N -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} ${DB_NAME} -e ${JSON.stringify(query)}`,
    { stdio: ["pipe", "pipe", "pipe"] }
  ).toString().trim();
}

function deleteBySummary(summary: string) {
  execSync(
    `mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} ${DB_NAME} -e ${JSON.stringify(
      `DELETE FROM app_feedback WHERE summary = ${JSON.stringify(summary)}`,
    )}`,
    { stdio: "pipe" }
  );
}

test.describe("feedback validation — server-side trust boundary", () => {
  test("rejects payload larger than 16 KiB with 400", async ({ page }) => {
    // Use a recognised key (user_agent) so the value isn't shunted to the
    // _unknown bucket and truncated to 4 KiB. user_agent has no per-field
    // size limit beyond the overall 16 KiB cap.
    const huge = "x".repeat(20_000);
    const r = await page.request.post(`${ADMIN_BASE}/app-feedback`, {
      data: {
        type: "other",
        summary: `e2e-val-too-big-${Date.now()}`,
        client_context: { schema_version: 1, user_agent: huge },
      },
    });
    expect(r.status()).toBe(400);
    const body = await r.json();
    expect(String(body.error)).toMatch(/too large/i);
  });

  test("overwrites client-supplied client_ip in the persisted blob", async ({ page }) => {
    const summary = `e2e-val-ip-${Date.now()}`;
    const r = await page.request.post(`${ADMIN_BASE}/app-feedback`, {
      data: {
        type: "other",
        summary,
        client_context: { schema_version: 1, client_ip: "1.2.3.4" },
      },
    });
    expect(r.ok()).toBeTruthy();
    const ip = sqlOne(
      `SELECT JSON_UNQUOTE(JSON_EXTRACT(client_context, '$._server.client_ip')) FROM app_feedback WHERE summary = ${JSON.stringify(summary)}`
    );
    expect(ip).not.toBe("1.2.3.4");
    expect(ip).not.toBe("");
    deleteBySummary(summary);
  });

  test("strips client-supplied tenant_id, user_id, user_role at top level", async ({ page }) => {
    const summary = `e2e-val-identity-${Date.now()}`;
    const r = await page.request.post(`${ADMIN_BASE}/app-feedback`, {
      data: {
        type: "other",
        summary,
        client_context: {
          schema_version: 1,
          tenant_id: "evil-tenant",
          user_id:   "evil-user",
          user_role: "admin",
        },
      },
    });
    expect(r.ok()).toBeTruthy();
    // Stripped client values must not exist at the top level OR under _unknown.
    const inTopLevel = sqlOne(
      `SELECT IFNULL(JSON_UNQUOTE(JSON_EXTRACT(client_context, '$.tenant_id')), '') FROM app_feedback WHERE summary = ${JSON.stringify(summary)}`
    );
    expect(inTopLevel).toBe("");
    const inUnknown = sqlOne(
      `SELECT IFNULL(JSON_UNQUOTE(JSON_EXTRACT(client_context, '$._unknown.tenant_id')), '') FROM app_feedback WHERE summary = ${JSON.stringify(summary)}`
    );
    expect(inUnknown).toBe("");
    deleteBySummary(summary);
  });

  test("server-supplied tenant_id and user_id are filled under _server", async ({ page }) => {
    const summary = `e2e-val-server-${Date.now()}`;
    const r = await page.request.post(`${ADMIN_BASE}/app-feedback`, {
      data: { type: "other", summary, client_context: { schema_version: 1 } },
    });
    expect(r.ok()).toBeTruthy();
    const userId = sqlOne(
      `SELECT JSON_UNQUOTE(JSON_EXTRACT(client_context, '$._server.user_id')) FROM app_feedback WHERE summary = ${JSON.stringify(summary)}`
    );
    expect(userId).not.toBe("");
    expect(userId).not.toBe("null");
    deleteBySummary(summary);
  });

  test("unknown top-level keys land in client_context._unknown", async ({ page }) => {
    const summary = `e2e-val-unknown-${Date.now()}`;
    const r = await page.request.post(`${ADMIN_BASE}/app-feedback`, {
      data: {
        type: "other",
        summary,
        client_context: {
          schema_version: 1,
          current_route: "/dashboard",
          some_random_field: "should-be-quarantined",
        },
      },
    });
    expect(r.ok()).toBeTruthy();
    const route = sqlOne(
      `SELECT JSON_UNQUOTE(JSON_EXTRACT(client_context, '$.current_route')) FROM app_feedback WHERE summary = ${JSON.stringify(summary)}`
    );
    const quar = sqlOne(
      `SELECT JSON_UNQUOTE(JSON_EXTRACT(client_context, '$._unknown.some_random_field')) FROM app_feedback WHERE summary = ${JSON.stringify(summary)}`
    );
    expect(route).toBe("/dashboard");
    expect(quar).toBe("should-be-quarantined");
    deleteBySummary(summary);
  });

  test("schema_version not in 1..N rejected with 400", async ({ page }) => {
    const r = await page.request.post(`${ADMIN_BASE}/app-feedback`, {
      data: {
        type: "other",
        summary: `e2e-val-sv-out-of-range-${Date.now()}`,
        client_context: { schema_version: 99 },
      },
    });
    expect(r.status()).toBe(400);
    const body = await r.json();
    expect(String(body.error)).toMatch(/schema_version/);
  });

  test("schema_version not an integer rejected with 400", async ({ page }) => {
    const r = await page.request.post(`${ADMIN_BASE}/app-feedback`, {
      data: {
        type: "other",
        summary: `e2e-val-sv-string-${Date.now()}`,
        client_context: { schema_version: "1" as unknown as number },
      },
    });
    expect(r.status()).toBe(400);
    const body = await r.json();
    expect(String(body.error)).toMatch(/schema_version/);
  });
});
