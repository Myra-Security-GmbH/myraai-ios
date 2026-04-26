/**
 * project-knowledge-upload.spec.ts — E2E tests for binary file uploads to project knowledge base.
 *
 * Feature: POST /admin/v1/projects/:id/knowledge/upload
 *          GET  /admin/v1/projects/:id/knowledge/:kid/download
 *
 * Suites:
 *   1. Plain text upload — existing text path still works; source == 'text'
 *   2. Binary upload — PDF, DOCX, XLSX, PPTX; text extracted; blob stored; source == 'upload'
 *   3. Error handling — oversized file rejected; unsupported type rejected
 *   4. Download — binary download returns original bytes; text download fallback works
 *   5. Blob deletion — after knowledge delete, download returns 404
 *   6. Regression — legacy text-only rows (source=='text') still downloadable
 */

import path from "path";
import fs from "fs";
import { test, expect, type Page } from "./base";

// When running with playwright.docker.config.ts, PLAYWRIGHT_ADMIN_URL is set to
// "https://ai-api-admin.myra.eu" and the docker session cookie covers that domain.
// When running with the default dev-server config, fall back to the Vite proxy.
const ADMIN_BASE = (process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173") + "/admin/v1";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface ProjectRow   { id: string; name: string }
interface KnowledgeRow { id: string; filename: string; content_type: string; size_bytes: number; token_count: number; source: string }

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function getMyratestTenantId(page: Page): Promise<string> {
  const resp = await page.context().request.get(`${ADMIN_BASE}/tenants`);
  expect(resp.ok(), "GET /tenants").toBeTruthy();
  const tenants = await resp.json() as Array<{ id: string; slug: string }>;
  const t = tenants.find((x) => x.slug === "myratest") ?? tenants[0];
  expect(t, "myratest tenant must exist").toBeTruthy();
  return t.id;
}

async function createProject(page: Page, tenantId: string, name: string): Promise<string> {
  const r = await page.context().request.post(`${ADMIN_BASE}/projects`, {
    data: { name, icon: "📁", color: "#2563eb", tenant_id: tenantId },
  });
  expect(r.ok(), `create project "${name}": ${await r.text()}`).toBeTruthy();
  return ((await r.json()) as ProjectRow).id;
}

async function deleteProject(page: Page, id: string) {
  await page.context().request.delete(`${ADMIN_BASE}/projects/${id}`).catch(() => {});
}

async function uploadTextKnowledge(
  page: Page,
  projectId: string,
  filename: string,
  text: string,
): Promise<KnowledgeRow> {
  const r = await page.context().request.post(`${ADMIN_BASE}/projects/${projectId}/knowledge`, {
    data: {
      filename,
      content_type: "text/plain",
      size_bytes: Buffer.byteLength(text, "utf8"),
      extracted_text: text,
    },
  });
  expect(r.ok(), `upload text knowledge "${filename}": ${await r.text()}`).toBeTruthy();
  return r.json() as Promise<KnowledgeRow>;
}

function fixtureB64(filename: string): string {
  const fpath = path.join(__dirname, "fixtures", filename);
  return fs.readFileSync(fpath).toString("base64");
}

async function uploadBinaryKnowledge(
  page: Page,
  projectId: string,
  filename: string,
  mimeType: string,
  b64: string,
): Promise<{ resp: Awaited<ReturnType<typeof page.context>["request"]["post"]>; row?: KnowledgeRow }> {
  const resp = await page.context().request.post(`${ADMIN_BASE}/projects/${projectId}/knowledge/upload`, {
    data: { filename, mime_type: mimeType, data: b64 },
  });
  if (resp.ok()) {
    return { resp, row: (await resp.json()) as KnowledgeRow };
  }
  return { resp };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Project knowledge — binary file upload", () => {

  // ── Suite 1: Plain text upload still works ────────────────────────────────
  test.describe("plain text upload", () => {
    let projectId = "";
    let tenantId = "";

    test.beforeEach(async ({ page }) => {
      tenantId = await getMyratestTenantId(page);
      projectId = await createProject(page, tenantId, "kbu-text-" + Date.now());
    });

    test.afterEach(async ({ page }) => {
      await deleteProject(page, projectId);
    });

    test("upload text file — source is 'text', content accessible", async ({ page }) => {
      const row = await uploadTextKnowledge(page, projectId, "notes.txt", "Hello world");
      expect(row.id).toBeTruthy();
      expect(row.filename).toBe("notes.txt");
      expect(row.source == null || row.source === "text").toBeTruthy();

      // Verify the row appears in list
      const listResp = await page.context().request.get(`${ADMIN_BASE}/projects/${projectId}/knowledge`);
      expect(listResp.ok()).toBeTruthy();
      const list = await listResp.json() as KnowledgeRow[];
      const found = list.find((r) => r.id === row.id);
      expect(found, "row in list").toBeTruthy();
    });
  });

  // ── Suite 2: Binary upload — PDF ─────────────────────────────────────────
  test.describe("PDF upload", () => {
    let projectId = "";
    let tenantId = "";

    test.beforeEach(async ({ page }) => {
      tenantId = await getMyratestTenantId(page);
      projectId = await createProject(page, tenantId, "kbu-pdf-" + Date.now());
    });

    test.afterEach(async ({ page }) => {
      await deleteProject(page, projectId);
    });

    test("upload PDF — source='upload', token_count > 0", async ({ page }) => {
      const b64 = fixtureB64("eiffel-tower.pdf");
      const { resp, row } = await uploadBinaryKnowledge(
        page, projectId, "eiffel-tower.pdf", "application/pdf", b64,
      );
      expect(resp.status(), `upload PDF: ${await resp.text()}`).toBe(201);
      expect(row!.source).toBe("upload");
      expect(row!.token_count).toBeGreaterThan(0);
      expect(row!.content_type).toBe("application/pdf");
    });

    test("PDF download returns binary with correct Content-Type", async ({ page }) => {
      const b64 = fixtureB64("eiffel-tower.pdf");
      const { resp, row } = await uploadBinaryKnowledge(
        page, projectId, "eiffel-tower.pdf", "application/pdf", b64,
      );
      expect(resp.status()).toBe(201);

      const dlResp = await page.context().request.get(
        `${ADMIN_BASE}/projects/${projectId}/knowledge/${row!.id}/download`,
      );
      expect(dlResp.ok(), `download: ${dlResp.status()}`).toBeTruthy();
      expect(dlResp.headers()["content-type"]).toContain("application/pdf");
      expect(dlResp.headers()["content-disposition"]).toContain("eiffel-tower.pdf");

      // Verify the returned bytes start with the PDF magic number %PDF-
      const bodyBuf = await dlResp.body();
      expect(bodyBuf.slice(0, 4).toString()).toBe("%PDF");
    });
  });

  // ── Suite 3: Binary upload — DOCX ────────────────────────────────────────
  test.describe("DOCX upload", () => {
    let projectId = "";
    let tenantId = "";

    test.beforeEach(async ({ page }) => {
      tenantId = await getMyratestTenantId(page);
      projectId = await createProject(page, tenantId, "kbu-docx-" + Date.now());
    });

    test.afterEach(async ({ page }) => {
      await deleteProject(page, projectId);
    });

    test("upload DOCX — source='upload', text extracted, token_count > 0", async ({ page }) => {
      const b64 = fixtureB64("eiffel-tower.docx");
      const { resp, row } = await uploadBinaryKnowledge(
        page, projectId, "eiffel-tower.docx",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document", b64,
      );
      expect(resp.status(), `upload DOCX: ${await resp.text()}`).toBe(201);
      expect(row!.source).toBe("upload");
      expect(row!.token_count).toBeGreaterThan(0);

      // Verify the single-item endpoint returns extracted_text
      const itemResp = await page.context().request.get(
        `${ADMIN_BASE}/projects/${projectId}/knowledge/${row!.id}`,
      );
      expect(itemResp.ok()).toBeTruthy();
      const item = await itemResp.json() as { extracted_text?: string };
      expect(item.extracted_text).toBeTruthy();
      expect(item.extracted_text!.length).toBeGreaterThan(0);
    });
  });

  // ── Suite 4: Binary upload — XLSX ────────────────────────────────────────
  test.describe("XLSX upload", () => {
    let projectId = "";
    let tenantId = "";

    test.beforeEach(async ({ page }) => {
      tenantId = await getMyratestTenantId(page);
      projectId = await createProject(page, tenantId, "kbu-xlsx-" + Date.now());
    });

    test.afterEach(async ({ page }) => {
      await deleteProject(page, projectId);
    });

    test("upload XLSX — extracted text looks like CSV", async ({ page }) => {
      const b64 = fixtureB64("q1-sales.xlsx");
      const { resp, row } = await uploadBinaryKnowledge(
        page, projectId, "q1-sales.xlsx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", b64,
      );
      expect(resp.status(), `upload XLSX: ${await resp.text()}`).toBe(201);
      expect(row!.source).toBe("upload");

      const itemResp = await page.context().request.get(
        `${ADMIN_BASE}/projects/${projectId}/knowledge/${row!.id}`,
      );
      expect(itemResp.ok()).toBeTruthy();
      const item = await itemResp.json() as { extracted_text?: string };
      // CSV output contains commas
      expect(item.extracted_text).toBeTruthy();
      expect(item.extracted_text).toContain(",");
    });
  });

  // ── Suite 5: Binary upload — PPTX ────────────────────────────────────────
  test.describe("PPTX upload", () => {
    let projectId = "";
    let tenantId = "";

    test.beforeEach(async ({ page }) => {
      tenantId = await getMyratestTenantId(page);
      projectId = await createProject(page, tenantId, "kbu-pptx-" + Date.now());
    });

    test.afterEach(async ({ page }) => {
      await deleteProject(page, projectId);
    });

    test("upload PPTX — extracted text is non-empty", async ({ page }) => {
      const b64 = fixtureB64("q1-roadmap.pptx");
      const { resp, row } = await uploadBinaryKnowledge(
        page, projectId, "q1-roadmap.pptx",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation", b64,
      );
      expect(resp.status(), `upload PPTX: ${await resp.text()}`).toBe(201);
      expect(row!.source).toBe("upload");
      expect(row!.token_count).toBeGreaterThan(0);
    });
  });

  // ── Suite 6: Error handling ───────────────────────────────────────────────
  test.describe("error handling", () => {
    let projectId = "";
    let tenantId = "";

    test.beforeEach(async ({ page }) => {
      tenantId = await getMyratestTenantId(page);
      projectId = await createProject(page, tenantId, "kbu-err-" + Date.now());
    });

    test.afterEach(async ({ page }) => {
      await deleteProject(page, projectId);
    });

    test("oversized file (>20MB) is rejected", async ({ page }) => {
      // Create a 21 MB buffer of zeros and base64-encode it.
      // The rejection may come from nginx (413 HTML) if a reverse proxy limit
      // is hit, or from Lua (413 JSON) if the body passes through to the handler.
      // Either way the request must not succeed (non-2xx response).
      const bigBuf = Buffer.alloc(21 * 1024 * 1024, 0);
      const b64 = bigBuf.toString("base64");
      const { resp } = await uploadBinaryKnowledge(
        page, projectId, "too-large.pdf", "application/pdf", b64,
      );
      expect(resp.ok(), "oversized file must be rejected (status was " + resp.status() + ")").toBeFalsy();
    });

    test("unsupported file type is rejected with 422", async ({ page }) => {
      // Upload a small fake .exe (a few bytes)
      const fakeBin = Buffer.from([0x4D, 0x5A, 0x00, 0x00]);  // MZ header
      const b64 = fakeBin.toString("base64");
      const { resp } = await uploadBinaryKnowledge(
        page, projectId, "malware.exe", "application/octet-stream", b64,
      );
      expect(resp.status()).toBe(422);
      const body = await resp.json() as { error?: string };
      expect(body.error).toContain("Unsupported");
    });

    test("missing filename returns 400", async ({ page }) => {
      const b64 = fixtureB64("eiffel-tower.pdf");
      const resp = await page.context().request.post(
        `${ADMIN_BASE}/projects/${projectId}/knowledge/upload`,
        { data: { mime_type: "application/pdf", data: b64 } },
      );
      expect(resp.status()).toBe(400);
    });

    test("invalid base64 returns 400", async ({ page }) => {
      const resp = await page.context().request.post(
        `${ADMIN_BASE}/projects/${projectId}/knowledge/upload`,
        { data: { filename: "test.pdf", mime_type: "application/pdf", data: "!!!not-base64!!!" } },
      );
      expect(resp.status()).toBe(400);
    });
  });

  // ── Suite 7: Blob deletion ────────────────────────────────────────────────
  test.describe("blob deletion", () => {
    let projectId = "";
    let tenantId = "";

    test.beforeEach(async ({ page }) => {
      tenantId = await getMyratestTenantId(page);
      projectId = await createProject(page, tenantId, "kbu-del-" + Date.now());
    });

    test.afterEach(async ({ page }) => {
      await deleteProject(page, projectId);
    });

    test("deleting knowledge row removes blob — download returns 404", async ({ page }) => {
      const b64 = fixtureB64("eiffel-tower.pdf");
      const { resp, row } = await uploadBinaryKnowledge(
        page, projectId, "eiffel-tower.pdf", "application/pdf", b64,
      );
      expect(resp.status()).toBe(201);
      const kid = row!.id;

      // Delete the knowledge row
      const delResp = await page.context().request.delete(
        `${ADMIN_BASE}/projects/${projectId}/knowledge/${kid}`,
      );
      expect(delResp.ok(), "delete knowledge").toBeTruthy();

      // Download must now return 404
      const dlResp = await page.context().request.get(
        `${ADMIN_BASE}/projects/${projectId}/knowledge/${kid}/download`,
      );
      expect(dlResp.status()).toBe(404);
    });
  });

  // ── Suite 8: Regression — download endpoint returns 404 for text-only rows ─
  test.describe("regression: text-only rows", () => {
    let projectId = "";
    let tenantId = "";

    test.beforeEach(async ({ page }) => {
      tenantId = await getMyratestTenantId(page);
      projectId = await createProject(page, tenantId, "kbu-reg-" + Date.now());
    });

    test.afterEach(async ({ page }) => {
      await deleteProject(page, projectId);
    });

    test("download endpoint returns 404 for text-only (source='text') rows", async ({ page }) => {
      const row = await uploadTextKnowledge(page, projectId, "readme.md", "# Title\n\nSome text.");
      const dlResp = await page.context().request.get(
        `${ADMIN_BASE}/projects/${projectId}/knowledge/${row.id}/download`,
      );
      expect(dlResp.status()).toBe(404);
      const body = await dlResp.json() as { error?: string };
      expect(body.error).toContain("no original file stored");
    });

    test("text knowledge row source is 'text' (not 'upload')", async ({ page }) => {
      const row = await uploadTextKnowledge(page, projectId, "info.txt", "Some information.");
      // source may be null (omitted by cjson) or the string 'text'
      const source = row.source;
      expect(source == null || source === "text").toBeTruthy();
    });
  });

  // ── Suite 9: UI — binary upload flow ─────────────────────────────────────
  test.describe("UI upload flow", () => {
    let projectId = "";
    let tenantId = "";

    test.beforeEach(async ({ page }) => {
      tenantId = await getMyratestTenantId(page);
      projectId = await createProject(page, tenantId, "kbu-ui-" + Date.now());
    });

    test.afterEach(async ({ page }) => {
      await deleteProject(page, projectId);
    });

    test("uploading a PDF via the UI shows the file in the knowledge table", async ({ page }) => {
      await page.goto(`/projects/${projectId}`);
      // Navigate to the Knowledge tab
      const knowledgeTab = page.getByRole("button", { name: /^files$/i })
        .or(page.getByRole("tab", { name: /^files$/i }));
      await knowledgeTab.waitFor({ state: "visible", timeout: 10000 });
      await knowledgeTab.click();

      // The drop zone and upload button should be visible
      await expect(page.locator("[data-cy=knowledge-drop-zone]")).toBeVisible({ timeout: 5000 });

      // Set the file on the hidden input
      const pdfPath = path.join(__dirname, "fixtures", "eiffel-tower.pdf");
      const fileInput = page.locator("input[type=file]");
      await fileInput.setInputFiles(pdfPath);

      // Button should show "Processing…" then return to "Upload File"
      const uploadBtn = page.locator("[data-cy=upload-knowledge-btn]");
      // Wait for processing to finish (up to 60s for PDF extraction)
      await expect(uploadBtn).not.toBeDisabled({ timeout: 60000 });

      // The file should now appear in the table
      await expect(page.getByText("eiffel-tower.pdf")).toBeVisible({ timeout: 5000 });

      // No error banner
      await expect(page.locator(`.alert--error`)).not.toBeVisible();
    });
  });
});
