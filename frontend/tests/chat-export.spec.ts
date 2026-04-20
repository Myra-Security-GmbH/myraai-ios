/**
 * chat-export.spec.ts — verifies the "Download Markdown" and "Download PDF"
 * export buttons in the chat config bar.
 *
 * Conversations and messages are seeded via the admin API so no live LLM call
 * is required. The tests open the seeded conversation in the UI and then
 * exercise the export buttons.
 */

import { test, expect, Page, Download } from "@playwright/test";

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------

async function getFirstGatewayId(page: Page): Promise<string | null> {
  const tenantsResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
  if (!tenantsResp.ok()) return null;
  const tenants = (await tenantsResp.json()) as Array<{ id: string; slug: string }>;
  if (!tenants.length) return null;

  // Prefer myratest — test fixture tenants are newest and appear first in the list
  const preferred = tenants.find((t) => t.slug === "myratest") ?? tenants[0];
  const gwResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants/${preferred.id}/gateways`);
  if (!gwResp.ok()) return null;
  const gws = (await gwResp.json()) as Array<{ id: string }>;
  return gws.length ? gws[0].id : null;
}

async function createConversation(page: Page, gatewayId: string, title: string): Promise<string | null> {
  const resp = await page.context().request.post(`${ADMIN_URL}/admin/v1/conversations`, {
    data: { gateway_id: gatewayId, title },
  });
  if (!resp.ok()) return null;
  const conv = (await resp.json()) as { id: string };
  return conv.id;
}

async function addMessage(page: Page, convId: string, role: "user" | "assistant", content: string, model?: string) {
  await page.context().request.post(`${ADMIN_URL}/admin/v1/conversations/${convId}/messages`, {
    data: { role, content, ...(model ? { model } : {}) },
  });
}

async function getGatewaySlug(page: Page, gatewayId: string): Promise<string | null> {
  const tenantsResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
  if (!tenantsResp.ok()) return null;
  const tenants = (await tenantsResp.json()) as Array<{ id: string }>;
  for (const tenant of tenants) {
    const gwResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants/${tenant.id}/gateways`);
    if (!gwResp.ok()) continue;
    const gws = (await gwResp.json()) as Array<{ id: string; slug: string }>;
    const gw = gws.find((g) => g.id === gatewayId);
    if (gw) return gw.slug;
  }
  return null;
}

async function deleteConversation(page: Page, convId: string) {
  await page.context().request.delete(`${ADMIN_URL}/admin/v1/conversations/${convId}`).catch(() => {});
}

/** Open the conversation in the chat UI by clicking it in the sidebar. */
async function openConversation(page: Page, convId: string) {
  await page.goto("/chat");
  const convItem = page.locator(`[role='option'][data-id='${convId}']`);
  await convItem.waitFor({ state: "visible", timeout: 8000 });
  await convItem.click();
  // Wait until the conversation is active (aria-selected becomes true)
  await expect(convItem).toHaveAttribute("aria-selected", "true", { timeout: 5000 });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Chat — export (Markdown + PDF)", () => {
  let gatewayId: string;
  let gatewaySlug: string;

  test.beforeAll(async ({ browser }) => {
    const page = await browser.newPage();
    const gid = await getFirstGatewayId(page);
    if (!gid) { await page.close(); throw new Error("No gateway found — cannot run export tests"); }
    const slug = await getGatewaySlug(page, gid);
    await page.close();
    if (!slug) throw new Error("Could not resolve gateway slug — cannot run export tests");
    gatewayId = gid;
    gatewaySlug = slug;
  });

  // ── 1. Buttons disabled with no active conversation ───────────────────────

  test("both export buttons are disabled on fresh load", async ({ page }) => {
    await page.goto("/chat");
    await page.waitForTimeout(600);

    const mdBtn  = page.locator("button[title='Download Markdown']");
    const pdfBtn = page.locator("button[title='Download PDF']");

    const visible = await mdBtn.isVisible({ timeout: 5000 }).catch(() => false);
    if (!visible) { test.skip(); return; }

    await expect(mdBtn).toBeDisabled();
    await expect(pdfBtn).toBeDisabled();
  });

  // ── 2. Markdown export ────────────────────────────────────────────────────

  test("Markdown export downloads a .md file with correct content", async ({ page }) => {
    const convId = await createConversation(page, gatewayId, "Sky Colour Test");
    if (!convId) { test.skip(); return; }

    const userMsg = "What colour is the sky?";
    const assistantMsg = "The sky is blue due to Rayleigh scattering.";
    await addMessage(page, convId, "user", userMsg);
    await addMessage(page, convId, "assistant", assistantMsg, "claude-sonnet-4-6");

    try {
      await openConversation(page, convId);

      const mdBtn = page.locator("button[title='Download Markdown']");
      await expect(mdBtn).toBeEnabled({ timeout: 5000 });

      const [download]: [Download] = await Promise.all([
        page.waitForEvent("download", { timeout: 10_000 }),
        mdBtn.click(),
      ]);

      expect(download.suggestedFilename()).toMatch(/\.md$/);

      const stream = await download.createReadStream();
      const chunks: Buffer[] = [];
      await new Promise<void>((resolve, reject) => {
        stream.on("data", (c: Buffer) => chunks.push(c));
        stream.on("end", resolve);
        stream.on("error", reject);
      });
      const content = Buffer.concat(chunks).toString("utf-8");

      expect(content).toMatch(/^#\s+/m);                        // heading
      expect(content).toContain("**You**");
      expect(content).toContain(`**Claude (claude-sonnet-4-6) via ${gatewaySlug}**`);
      expect(content).toContain(userMsg);
      expect(content).toContain(assistantMsg);
      expect(content).toMatch(/\*Exported on .+\*/);
    } finally {
      await deleteConversation(page, convId);
    }
  });

  test("Markdown export omits docx text body, keeps filename reference", async ({ page }) => {
    const convId = await createConversation(page, gatewayId, "Docx Filter Test");
    if (!convId) { test.skip(); return; }

    // Simulate a user message that contains a docx content block
    const docxContent = JSON.stringify([
      {
        type: "docx",
        filename: "quarterly-report.docx",
        text: "This confidential full text must not appear in the export output.",
      },
    ]);
    await addMessage(page, convId, "user", docxContent);
    await addMessage(page, convId, "assistant", "I have reviewed the document.");

    try {
      await openConversation(page, convId);

      const mdBtn = page.locator("button[title='Download Markdown']");
      await expect(mdBtn).toBeEnabled({ timeout: 5000 });

      const [download]: [Download] = await Promise.all([
        page.waitForEvent("download", { timeout: 10_000 }),
        mdBtn.click(),
      ]);

      const stream = await download.createReadStream();
      const chunks: Buffer[] = [];
      await new Promise<void>((resolve, reject) => {
        stream.on("data", (c: Buffer) => chunks.push(c));
        stream.on("end", resolve);
        stream.on("error", reject);
      });
      const content = Buffer.concat(chunks).toString("utf-8");

      expect(content).toContain("[Document: quarterly-report.docx]");
      expect(content).not.toContain("confidential full text");
    } finally {
      await deleteConversation(page, convId);
    }
  });

  // ── 3. Export label format ────────────────────────────────────────────────

  test("export label shows ModelFamily (model-id) via gateway-slug per message", async ({ page }) => {
    const convId = await createConversation(page, gatewayId, "Label Format Test");
    if (!convId) { test.skip(); return; }

    await addMessage(page, convId, "user", "Tell me about the weather.");
    await addMessage(page, convId, "assistant", "It is sunny today.", "claude-opus-4-6");

    try {
      await openConversation(page, convId);

      const mdBtn = page.locator("button[title='Download Markdown']");
      await expect(mdBtn).toBeEnabled({ timeout: 5000 });

      const [download]: [Download] = await Promise.all([
        page.waitForEvent("download", { timeout: 10_000 }),
        mdBtn.click(),
      ]);

      const stream = await download.createReadStream();
      const chunks: Buffer[] = [];
      await new Promise<void>((resolve, reject) => {
        stream.on("data", (c: Buffer) => chunks.push(c));
        stream.on("end", resolve);
        stream.on("error", reject);
      });
      const content = Buffer.concat(chunks).toString("utf-8");

      expect(content).toContain(`**Claude (claude-opus-4-6) via ${gatewaySlug}**`);
    } finally {
      await deleteConversation(page, convId);
    }
  });

  // ── 4. PDF export ─────────────────────────────────────────────────────────

  test("PDF export POSTs markdown and downloads a valid PDF binary", async ({ page }) => {
    const convId = await createConversation(page, gatewayId, "PDF Export Test");
    if (!convId) { test.skip(); return; }

    await addMessage(page, convId, "user", "Name three colours of the rainbow.");
    await addMessage(page, convId, "assistant", "Red, orange, and yellow.");

    try {
      await openConversation(page, convId);

      const pdfBtn = page.locator("button[title='Download PDF']");
      await expect(pdfBtn).toBeEnabled({ timeout: 5000 });

      const exportReqPromise = page.waitForRequest(
        (req) => req.method() === "POST" && req.url().includes("/chat/export-pdf"),
        { timeout: 15_000 },
      );

      const [download]: [Download] = await Promise.all([
        page.waitForEvent("download", { timeout: 30_000 }),
        pdfBtn.click(),
      ]);

      const exportReq = await exportReqPromise;
      const reqBody = exportReq.postDataJSON() as Record<string, unknown>;
      expect(reqBody.markdown).toBeTruthy();
      expect(typeof reqBody.markdown).toBe("string");

      expect(download.suggestedFilename()).toMatch(/\.pdf$/);

      const stream = await download.createReadStream();
      const chunks: Buffer[] = [];
      await new Promise<void>((resolve, reject) => {
        stream.on("data", (c: Buffer) => chunks.push(c));
        stream.on("end", resolve);
        stream.on("error", reject);
      });
      const buf = Buffer.concat(chunks);
      expect(buf.length).toBeGreaterThan(100);
      expect(buf.slice(0, 4).toString("ascii")).toBe("%PDF");
    } finally {
      await deleteConversation(page, convId);
    }
  });

  test("PDF export failure shows error banner", async ({ page }) => {
    const convId = await createConversation(page, gatewayId, "PDF Failure Test");
    if (!convId) { test.skip(); return; }

    await addMessage(page, convId, "user", "Hello.");
    await addMessage(page, convId, "assistant", "Hi there.");

    try {
      await openConversation(page, convId);

      // Intercept the export-pdf endpoint and return 500
      await page.route(
        (url) => url.pathname.includes("/chat/export-pdf"),
        async (route) => {
          await route.fulfill({ status: 500, body: JSON.stringify({ error: "pandoc failure (simulated)" }) });
        },
      );

      const pdfBtn = page.locator("button[title='Download PDF']");
      await expect(pdfBtn).toBeEnabled({ timeout: 5000 });
      await pdfBtn.click();

      // Error banner should appear
      const errorBanner = page.getByText(/PDF export failed/i).first();
      await errorBanner.waitFor({ state: "visible", timeout: 8000 });
      await expect(errorBanner).toBeVisible();
    } finally {
      await deleteConversation(page, convId);
    }
  });
});
