/**
 * chat-project-read-commands.spec.ts — verifies the project file READ command feature.
 *
 * The feature lets the model emit <read_file>filename</read_file> to request a
 * project knowledge file. The frontend strips the tag, injects the file content
 * as a continuation user message, and makes a second inference request.
 *
 * Test structure:
 *   Suite A — System-prompt assertions (intercept real request, mock SSE response)
 *     1. System prompt lists files with read_file instructions, NOT file content
 *     2. System prompt file list updates when a second knowledge file is added
 *
 *   Suite B — Real inference (SAFE local only / vllm, no mocking)
 *     3. Model can be directed to emit read_file and then receives the file content
 *
 *   Suite C — Frontend plumbing (mocked SSE, deterministic)
 *     4. read_file tag is stripped from the visible assistant bubble
 *     5. Missing file handled gracefully with [File not found] injection
 *     6. MAX_FILE_READS=5 cap prevents infinite read loops
 */

import { test, expect, Page, Route } from "@playwright/test";

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

interface TenantRow  { id: string; slug: string; chat_presets?: Array<{ id: string; name: string; gateway_id?: string; model?: string }> }
interface GatewayRow { id: string; slug: string }
interface ModelPriceRow { provider: string; model: string }

async function getFirstTenantAndGateway(page: Page): Promise<{ tenantId: string; gatewayId: string } | null> {
  const tr = await page.request.get(`${ADMIN_URL}/admin/v1/tenants`);
  if (!tr.ok()) return null;
  const tenants = await tr.json() as TenantRow[];
  for (const t of tenants) {
    const gr = await page.request.get(`${ADMIN_URL}/admin/v1/tenants/${t.id}/gateways`);
    if (!gr.ok()) continue;
    const gws = await gr.json() as GatewayRow[];
    if (gws.length) return { tenantId: t.id, gatewayId: gws[0].id };
  }
  return null;
}

async function getAModel(page: Page): Promise<string | null> {
  const r = await page.request.get(`${ADMIN_URL}/admin/v1/models`);
  if (!r.ok()) return null;
  const rows = await r.json() as ModelPriceRow[];
  const claude = rows.find((m) => m.provider === "anthropic" && m.model.startsWith("claude"));
  if (claude) return `anthropic/${claude.model}`;
  if (rows.length) return `${rows[0].provider}/${rows[0].model}`;
  return null;
}

async function setChatPreferences(page: Page, gatewayId: string, model: string, tenantId: string) {
  const currentUrl = page.url();
  if (currentUrl === "about:blank" || currentUrl === "") {
    await page.goto("/dashboard");
    await expect(page).toHaveURL(/dashboard/, { timeout: 10000 });
  }
  await page.evaluate(({ g, m, t }) => {
    localStorage.setItem("aig-chat-gateway", g);
    localStorage.setItem("aig-chat-model", m);
    localStorage.setItem("aig-chat-tenant", t);
    localStorage.removeItem("aig-chat-preset"); // clear any cached preset to avoid conflicts
  }, { g: gatewayId, m: model, t: tenantId });
}

/**
 * Navigate to /chat, select the myratest tenant's first preset (SAFE local only / vllm),
 * and confirm the chat textarea becomes enabled. This persists the gateway/model to
 * localStorage so the selection survives navigation to /chat?project_id=X.
 */
async function selectSafeLocalPreset(page: Page): Promise<void> {
  await page.goto("/chat");
  await page.waitForLoadState("networkidle");

  const tenantSel = page.locator("select").first();
  await expect(tenantSel).toBeVisible({ timeout: 8000 });

  // Select the myratest tenant
  const tenantOpt = tenantSel.locator("option").filter({ hasText: /myratest/i });
  expect(await tenantOpt.count(), "myratest tenant must exist in the tenant selector").toBeGreaterThan(0);
  await tenantSel.selectOption({ label: (await tenantOpt.first().textContent()) ?? "myratest" });

  // In preset mode, preset buttons appear instead of gateway/model selects.
  // The FIRST preset is always "SAFE local only" (vllm — uses dev master key).
  const presetBtn = page.locator("[data-testid='config-preset-btn']");
  await expect(presetBtn.first()).toBeVisible({ timeout: 8000 });
  await presetBtn.first().click();

  // Confirm the textarea is enabled (gateway + model are now in React state + localStorage)
  await expect(page.locator("textarea").first()).toBeEnabled({ timeout: 8000 });
}

async function createProject(page: Page, tenantId: string, name: string, instructions?: string): Promise<string> {
  const resp = await page.request.post(`${ADMIN_URL}/admin/v1/projects`, {
    data: { name, icon: "📁", color: "#2563eb", tenant_id: tenantId, ...(instructions ? { instructions } : {}) },
  });
  expect(resp.ok(), `POST /projects: ${await resp.text()}`).toBeTruthy();
  const proj = await resp.json() as { id: string };
  return proj.id;
}

async function addKnowledgeFile(page: Page, projectId: string, filename: string, content: string): Promise<void> {
  const resp = await page.request.post(`${ADMIN_URL}/admin/v1/projects/${projectId}/knowledge`, {
    data: { filename, extracted_text: content, content_type: "text/plain" },
  });
  expect(resp.ok(), `POST /projects/${projectId}/knowledge: ${await resp.text()}`).toBeTruthy();
}

async function deleteProject(page: Page, pid: string): Promise<void> {
  await page.request.delete(`${ADMIN_URL}/admin/v1/projects/${pid}`).catch(() => {});
}

function makeSseBody(content: string, finishReason = "stop"): string {
  return [
    `data: ${JSON.stringify({ choices: [{ delta: { content }, finish_reason: null }] })}\n\n`,
    `data: ${JSON.stringify({ choices: [{ delta: {}, finish_reason: finishReason }] })}\n\n`,
    "data: [DONE]\n\n",
  ].join("");
}

async function sendMessage(page: Page, text: string): Promise<void> {
  const textarea = page.locator("[class*='chat-textarea']");
  await expect(textarea).toBeVisible({ timeout: 8000 });
  await textarea.fill(text);
  await page.locator("button[title='Send message']").click();
}

async function waitForStreamingDone(page: Page, timeoutMs = 120_000): Promise<void> {
  await expect(page.locator("[class*='bubble-row']:not([class*='user-row'])").first())
    .toBeVisible({ timeout: 20_000 });
  await expect(page.locator("button[title='Stop generation']"))
    .not.toBeVisible({ timeout: timeoutMs });
}

// ---------------------------------------------------------------------------
// Suite A — System-prompt assertions
// ---------------------------------------------------------------------------

test.describe("Chat — project read commands: system prompt", () => {
  let tenantId: string;
  let gatewayId: string;
  let model: string;
  let projectId: string;

  const FILE_NAME    = "readme.txt";
  const FILE_CONTENT = "secret-marker-alpha: This is the README content for the E2E test.";

  test.beforeAll(async ({ browser }) => {
    const ctx = await browser.newContext({ storageState: "tests/.auth/docker-session.json" });
    const page = await ctx.newPage();
    await page.goto("/dashboard");

    const tg = await getFirstTenantAndGateway(page);
    expect(tg, "at least one tenant + gateway must exist").not.toBeNull();
    tenantId  = tg!.tenantId;
    gatewayId = tg!.gatewayId;

    const m = await getAModel(page);
    expect(m, "at least one model must be configured").not.toBeNull();
    model = m!;

    await ctx.close();
  });

  test.beforeEach(async ({ page }) => {
    projectId = await createProject(page, tenantId, `E2E sys-prompt ${Date.now()}`);
    await addKnowledgeFile(page, projectId, FILE_NAME, FILE_CONTENT);
    await setChatPreferences(page, gatewayId, model, tenantId);
    await page.goto(`/chat?project_id=${projectId}`);
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 10000 });
  });

  test.afterEach(async ({ page }) => {
    await deleteProject(page, projectId);
  });

  test("system prompt lists file names with read_file instructions — not file content", async ({ page }) => {
    let capturedSystemMessage: string | null = null;

    // Intercept the first completions call: capture the system message then mock SSE
    await page.route(
      (url) => url.pathname.includes("/compat/chat/completions"),
      async (route: Route, request) => {
        const body = request.postDataJSON?.() as Record<string, unknown> | null;
        if (body?.stream === false) { await route.continue(); return; }
        const messages = (body?.messages ?? []) as Array<{ role: string; content: string }>;
        const sys = messages.find((m) => m.role === "system");
        if (sys && capturedSystemMessage === null) capturedSystemMessage = sys.content;
        await route.fulfill({
          status: 200,
          headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" },
          body: makeSseBody("I will use the read_file command to read the file."),
        });
      },
    );

    await sendMessage(page, "What files are available?");
    await waitForStreamingDone(page);

    expect(capturedSystemMessage, "system message must have been captured").not.toBeNull();
    // File name must be listed
    expect(capturedSystemMessage).toContain(FILE_NAME);
    // read_file instruction must be present
    expect(capturedSystemMessage).toContain("read_file");
    // The actual file content must NOT be in the initial system prompt
    // (content is deferred until the model explicitly requests it)
    expect(capturedSystemMessage, "file content must not be injected upfront").not.toContain(FILE_CONTENT);

    await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
  });

  test("system prompt lists all files when multiple knowledge files are present", async ({ page }) => {
    const SECOND_FILE = "config.json";
    await addKnowledgeFile(page, projectId, SECOND_FILE, '{ "version": 2 }');

    let capturedSystemMessage: string | null = null;
    await page.route(
      (url) => url.pathname.includes("/compat/chat/completions"),
      async (route: Route, request) => {
        const body = request.postDataJSON?.() as Record<string, unknown> | null;
        if (body?.stream === false) { await route.continue(); return; }
        const messages = (body?.messages ?? []) as Array<{ role: string; content: string }>;
        const sys = messages.find((m) => m.role === "system");
        if (sys && capturedSystemMessage === null) capturedSystemMessage = sys.content;
        await route.fulfill({
          status: 200,
          headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" },
          body: makeSseBody("I see two files available."),
        });
      },
    );

    // Reload to pick up the second file (knowledge is fetched on mount)
    await page.goto(`/chat?project_id=${projectId}`);
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 10000 });

    await sendMessage(page, "List available files");
    await waitForStreamingDone(page);

    expect(capturedSystemMessage).not.toBeNull();
    expect(capturedSystemMessage).toContain(FILE_NAME);
    expect(capturedSystemMessage).toContain(SECOND_FILE);
    expect(capturedSystemMessage).toContain("read_file");

    await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
  });
});

// ---------------------------------------------------------------------------
// Suite B — Real inference (SAFE local only / vllm)
// ---------------------------------------------------------------------------

test.describe("Chat — project read commands: real inference", () => {
  test.setTimeout(180_000); // real model responses can be slow

  let tenantId: string;
  let projectId: string;

  const FILE_NAME    = "facts.txt";
  const FILE_CONTENT = "unique-token-zq9x: The capital of France is Paris.";

  test.beforeAll(async ({ browser }) => {
    const ctx = await browser.newContext({ storageState: "tests/.auth/docker-session.json" });
    const page = await ctx.newPage();
    await page.goto("/dashboard");

    // Get the myratest tenant ID for project creation
    const tr = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
    expect(tr.ok()).toBeTruthy();
    const tenants = await tr.json() as TenantRow[];
    const myratest = tenants.find((t) => t.slug === "myratest") ?? tenants[0];
    expect(myratest, "myratest tenant must exist").toBeTruthy();
    tenantId = myratest.id;

    await ctx.close();
  });

  test.beforeEach(async ({ page }) => {
    projectId = await createProject(page, tenantId, `E2E real-inference ${Date.now()}`);
    await addKnowledgeFile(page, projectId, FILE_NAME, FILE_CONTENT);

    // Select the SAFE local only / vllm preset via the UI — this persists the
    // gateway+model to localStorage so /chat?project_id=X picks it up.
    await selectSafeLocalPreset(page);

    await page.goto(`/chat?project_id=${projectId}`);
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 10000 });
  });

  test.afterEach(async ({ page }) => {
    await deleteProject(page, projectId);
  });

  test("model uses read_file hint and receives file content in second inference leg", async ({ page }) => {
    // Capture the second SSE leg to verify the file was actually injected
    let fileContentInjected = false;
    page.on("request", (req) => {
      if (req.method() !== "POST" || !req.url().includes("/compat/chat/completions")) return;
      const body = req.postDataJSON?.() as Record<string, unknown> | null;
      if (body?.stream === false) return;
      const msgs = body?.messages as Array<{ role: string; content: string }> | undefined;
      if (msgs?.some((m) => m.role === "user" && typeof m.content === "string" && m.content.includes(FILE_CONTENT))) {
        fileContentInjected = true;
      }
    });

    // Directive that leaves no ambiguity: the model must emit the read_file command.
    // The system prompt already instructs the model how to do this.
    await sendMessage(
      page,
      `Read the file "${FILE_NAME}" using the read_file command now. ` +
      `Output only: <read_file>${FILE_NAME}</read_file>`,
    );

    await waitForStreamingDone(page, 120_000);

    // The model should have emitted <read_file>facts.txt</read_file>, triggering
    // a second inference leg with the file content injected.
    expect(
      fileContentInjected,
      "file content must have been injected into a second inference leg — " +
      "the model did not use the read_file command as instructed",
    ).toBeTruthy();

    // The final response must be visible with no errors
    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    await expect(assistantBubble).toBeVisible();
    const bubbleText = await assistantBubble.textContent() ?? "";
    expect(bubbleText, "raw read_file tag must not remain visible").not.toContain("<read_file>");

    await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
  });
});

// ---------------------------------------------------------------------------
// Suite C — Frontend plumbing (mocked SSE, deterministic)
// ---------------------------------------------------------------------------

test.describe("Chat — project read commands: frontend plumbing", () => {
  let tenantId: string;
  let gatewayId: string;
  let model: string;
  let projectId: string;

  const FILE_NAME    = "testfile.txt";
  const FILE_CONTENT = "The secret content is: hello world from knowledge base";

  test.beforeAll(async ({ browser }) => {
    const ctx = await browser.newContext({ storageState: "tests/.auth/docker-session.json" });
    const page = await ctx.newPage();
    await page.goto("/dashboard");

    const tg = await getFirstTenantAndGateway(page);
    expect(tg, "at least one tenant + gateway must exist").not.toBeNull();
    tenantId  = tg!.tenantId;
    gatewayId = tg!.gatewayId;

    const m = await getAModel(page);
    expect(m, "at least one model must be configured").not.toBeNull();
    model = m!;

    await ctx.close();
  });

  test.beforeEach(async ({ page }) => {
    projectId = await createProject(page, tenantId, `E2E plumbing ${Date.now()}`);
    await addKnowledgeFile(page, projectId, FILE_NAME, FILE_CONTENT);
    await setChatPreferences(page, gatewayId, model, tenantId);
    await page.goto(`/chat?project_id=${projectId}`);
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 10000 });
  });

  test.afterEach(async ({ page }) => {
    await deleteProject(page, projectId);
  });

  // Route: first SSE leg returns firstResponse; second leg (file injected) returns continuationResponse
  async function routeGateway(page: Page, firstResponse: string, continuationResponse: string): Promise<void> {
    await page.route(
      (url) => url.pathname.includes("/compat/chat/completions"),
      async (route: Route, request) => {
        const body = request.postDataJSON?.() as Record<string, unknown> | null;
        if (body?.stream === false) { await route.continue(); return; }
        const messages = (body?.messages ?? []) as Array<{ role: string; content: string }>;
        const hasInjection = messages.some(
          (m) => m.role === "user" && typeof m.content === "string" && m.content.startsWith("## File:"),
        );
        await route.fulfill({
          status: 200,
          headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" },
          body: makeSseBody(hasInjection ? continuationResponse : firstResponse),
        });
      },
    );
  }

  test("read_file tag is stripped from the visible assistant bubble", async ({ page }) => {
    await routeGateway(page, `<read_file>${FILE_NAME}</read_file>`, "I have read the file.");

    await sendMessage(page, "Read the test file");
    await waitForStreamingDone(page);

    const bubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    const text = await bubble.textContent() ?? "";
    expect(text).not.toContain("<read_file>");
    expect(text).not.toContain("</read_file>");
    await expect(bubble).toContainText("I have read the file.", { timeout: 5000 });
    await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
  });

  test("missing file handled gracefully — [File not found] injected into second leg", async ({ page }) => {
    const MISSING = "does-not-exist.txt";
    await routeGateway(page, `<read_file>${MISSING}</read_file>`, "The file was not available.");

    let notFoundSeen = false;
    page.on("request", (req) => {
      if (req.method() !== "POST" || !req.url().includes("/compat/chat/completions")) return;
      const body = req.postDataJSON?.() as Record<string, unknown> | null;
      if (body?.stream === false) return;
      const msgs = body?.messages as Array<{ role: string; content: string }> | undefined;
      if (msgs?.some((m) => m.role === "user" && m.content?.includes("File not found"))) notFoundSeen = true;
    });

    await sendMessage(page, "Read a nonexistent file");
    await waitForStreamingDone(page);

    expect(notFoundSeen, "second leg must include [File not found] message").toBeTruthy();
    await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
    await expect(page.getByText(/error/i).first()).not.toBeVisible();
  });

  test("MAX_FILE_READS=5 cap stops infinite read loops (Bug guard)", async ({ page }) => {
    let sseCount = 0;
    await page.route(
      (url) => url.pathname.includes("/compat/chat/completions"),
      async (route: Route, request) => {
        const body = request.postDataJSON?.() as Record<string, unknown> | null;
        if (body?.stream === false) { await route.continue(); return; }
        sseCount++;
        await route.fulfill({
          status: 200,
          headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" },
          body: makeSseBody(`<read_file>${FILE_NAME}</read_file>`),
        });
      },
    );

    await sendMessage(page, "Keep reading files");
    await waitForStreamingDone(page);

    // 1 initial + at most 5 file-read continuations = ≤ 6 SSE legs
    expect(sseCount, "must not exceed MAX_FILE_READS + 1 SSE requests").toBeLessThanOrEqual(6);
    expect(sseCount, "must have looped at least twice").toBeGreaterThanOrEqual(2);
    await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
  });
});
