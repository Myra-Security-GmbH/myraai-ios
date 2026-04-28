/**
 * chat-feedback-linkage.spec.ts — verify that POST /admin/v1/reports persists
 * the request_log_id and that the admin list endpoint surfaces the linked
 * request_log fields (model, provider, tokens) via JOIN.
 *
 * The full UI flow ("send a chat message, click Report on the bubble")
 * touches a lot of moving parts; the wire-format contract on its own
 * (request_log_id round-trips from POST → DB → admin list) is what proves
 * the JOIN works. The chat-message X-Request-Id capture is exercised by
 * existing chat-* specs that watch the streaming response.
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

function sqlExec(query: string) {
  execSync(
    `mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} ${DB_NAME} -e ${JSON.stringify(query)}`,
    { stdio: "pipe" }
  );
}
function sqlOne(query: string): string {
  return execSync(
    `mysql -N -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} ${DB_NAME} -e ${JSON.stringify(query)}`,
    { stdio: ["pipe", "pipe", "pipe"] }
  ).toString().trim();
}

function uuid(): string {
  return execSync("cat /proc/sys/kernel/random/uuid").toString().trim();
}

/** Seed a request_log row matching the schema; returns its id. */
function seedRequestLog(opts: { provider: string; model: string }): string {
  const id = uuid();
  // Use minimal column set that matches NOT NULL constraints in
  // src/storage/migrations/0001_initial_schema.sql.
  sqlExec(
    `INSERT INTO request_log (id, tenant_id, gateway_id, provider, model, status,
                              cached, input_tokens, output_tokens,
                              cost_usd, latency_ms, ts)
     VALUES (${JSON.stringify(id)}, '', '',
             ${JSON.stringify(opts.provider)}, ${JSON.stringify(opts.model)},
             200, 0, 100, 250, 0.0042, 1234,
             ${Date.now()})`
  );
  return id;
}

function deleteReportById(id: string) {
  sqlExec(`DELETE FROM content_report WHERE id = ${JSON.stringify(id)}`);
}

function deleteRequestLogById(id: string) {
  sqlExec(`DELETE FROM request_log WHERE id = ${JSON.stringify(id)}`);
}

test.describe("chat-feedback request_log linkage", () => {
  test("POST /reports persists request_log_id", async ({ page }) => {
    const reqLogId = seedRequestLog({ provider: "vllm", model: "qwen3.6-35b-a3b" });
    try {
      const r = await page.request.post(`${ADMIN_BASE}/reports`, {
        data: {
          reason: "inaccurate",
          message_id: uuid(),
          message_text: "e2e test message",
          request_log_id: reqLogId,
        },
      });
      expect(r.ok()).toBeTruthy();
      const body = await r.json();
      const persisted = sqlOne(
        `SELECT request_log_id FROM content_report WHERE id = ${JSON.stringify(body.id)}`
      );
      expect(persisted).toBe(reqLogId);
      deleteReportById(body.id);
    } finally {
      deleteRequestLogById(reqLogId);
    }
  });

  test("admin list endpoint surfaces JOINed request_log fields", async ({ page }) => {
    const reqLogId = seedRequestLog({ provider: "vllm", model: "qwen3.6-35b-a3b" });
    let reportId: string | undefined;
    try {
      const r = await page.request.post(`${ADMIN_BASE}/reports`, {
        data: {
          reason: "inaccurate",
          message_id: uuid(),
          message_text: "e2e test message — admin JOIN",
          request_log_id: reqLogId,
        },
      });
      expect(r.ok()).toBeTruthy();
      reportId = (await r.json()).id;

      const list = await page.request.get(`${ADMIN_BASE}/reports?status=open&limit=200`);
      expect(list.ok()).toBeTruthy();
      const rows = await list.json() as Array<{
        id: string;
        request_log_id: string | null;
        request_log_provider: string | null;
        request_log_model: string | null;
        request_log_status: number | null;
        request_log_input_tokens: number | null;
        request_log_output_tokens: number | null;
      }>;
      const ours = rows.find(x => x.id === reportId);
      expect(ours, "report id not in admin list").toBeTruthy();
      expect(ours!.request_log_id).toBe(reqLogId);
      expect(ours!.request_log_provider).toBe("vllm");
      expect(ours!.request_log_model).toBe("qwen3.6-35b-a3b");
      expect(ours!.request_log_status).toBe(200);
      expect(ours!.request_log_input_tokens).toBe(100);
      expect(ours!.request_log_output_tokens).toBe(250);
    } finally {
      if (reportId) deleteReportById(reportId);
      deleteRequestLogById(reqLogId);
    }
  });

  test("POST /reports rejects malformed request_log_id (non-UUID-shaped string)", async ({ page }) => {
    // The handler keeps only [%w%-]+ characters via the Lua match, then sub(1,36).
    // A wholly-invalid value like '../../etc/passwd' has slashes and dots which
    // both cause match() to fail → field stored as nil.
    const r = await page.request.post(`${ADMIN_BASE}/reports`, {
      data: {
        reason: "inaccurate",
        message_id: uuid(),
        message_text: "e2e test message — malformed log id",
        request_log_id: "../../etc/passwd",
      },
    });
    expect(r.ok()).toBeTruthy();  // Server accepts the report, just drops the bad linkage.
    const body = await r.json();
    const stored = sqlOne(
      `SELECT IFNULL(request_log_id, '__null__') FROM content_report WHERE id = ${JSON.stringify(body.id)}`
    );
    expect(stored).toBe("__null__");
    deleteReportById(body.id);
  });

  test("POST /reports without request_log_id still succeeds (legacy clients)", async ({ page }) => {
    const r = await page.request.post(`${ADMIN_BASE}/reports`, {
      data: {
        reason: "other",
        message_id: uuid(),
        message_text: "e2e test message — legacy client",
      },
    });
    expect(r.ok()).toBeTruthy();
    const body = await r.json();
    const stored = sqlOne(
      `SELECT IFNULL(request_log_id, '__null__') FROM content_report WHERE id = ${JSON.stringify(body.id)}`
    );
    expect(stored).toBe("__null__");
    deleteReportById(body.id);
  });

  test("admin list returns null request_log_* fields for reports without linkage", async ({ page }) => {
    const r = await page.request.post(`${ADMIN_BASE}/reports`, {
      data: { reason: "other", message_id: uuid(), message_text: "no linkage" },
    });
    expect(r.ok()).toBeTruthy();
    const reportId = (await r.json()).id;
    try {
      const list = await page.request.get(`${ADMIN_BASE}/reports?status=open&limit=200`);
      const rows = await list.json() as Array<{ id: string; request_log_provider: string | null }>;
      const ours = rows.find(x => x.id === reportId);
      expect(ours).toBeTruthy();
      // cjson omits SQL-NULL fields entirely; assert "absent or explicitly null"
      expect(ours!.request_log_provider == null).toBeTruthy();
    } finally {
      deleteReportById(reportId);
    }
  });
});
