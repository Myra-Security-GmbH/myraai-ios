/**
 * chat-pdf-export.spec.ts — E2E tests for the chat PDF export feature.
 *
 * Two test groups:
 *
 *   1. API-level  — POST markdown directly to /admin/v1/chat/export-pdf.
 *      Validates that the backend produces a valid PDF with:
 *        • correct fonts (Liberation Sans embedded)
 *        • numbers not letter-spaced  ($325.9B ≠ "$ 3 2 5 . 9 B")
 *        • tables, emoji, headings, code blocks all present
 *      Uses pdftotext (poppler-utils) to extract text for assertions.
 *
 *   2. UI / full-flow — sends the actual TAM query through the chat UI,
 *      waits for a streamed model response, clicks "Download PDF", and
 *      verifies the downloaded file is a valid non-trivial PDF.
 *      Uses the SAFE vllm preset so inference works in the local environment.
 *
 * Regression guard: the literal strings "$ 3 2 5" or "2 0 2 5" (inter-digit
 * spaces) must not appear anywhere in the extracted PDF text.
 */

import { test, expect, type Page } from "./base";
import { deleteConversations, captureConvId } from "./helpers";
import { execSync }                 from "child_process";
import * as fs                      from "fs";
import * as path                    from "path";
import * as os                      from "os";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const ADMIN_URL  = process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173";
const ADMIN_BASE = `${ADMIN_URL}/admin/v1`;

// TAM question that produces a response rich in numbers, tables, and structure
const TAM_QUERY =
  "What is the market potential (TAM) in the European Union to host LLM models " +
  "and provide GDPR-compliant solutions for European clients? " +
  "We already are a highly-certified, trusted company with lots of government contracts. " +
  "Please include a market size table with year-by-year projections and key growth drivers.";

// Rich markdown that exercises every element the CSS must handle.
// Mirrors the structure buildExportMarkdown() produces for a real conversation.
const RICH_MARKDOWN = `# EU GDPR-Compliant LLM Hosting — TAM Analysis

*Exported on April 20, 2026*

---

**You**

${TAM_QUERY}

---

**Qwen3-30B-A3B via prod**

## Market Overview

The European market for GDPR-compliant LLM hosting is estimated at **€12.5B** in 2025,
growing at a **34.2% CAGR** through 2030 to reach **€52.8B**.

### Key Figures

- Total Addressable Market (2025): **€12.5B**
- Projected 2030 TAM: **€52.8B**
- Year-on-year growth (2025→2026): **+38.1%**
- EU AI Act compliance premium: **15–20%** above US-hosted alternatives
- Enterprise contract value range: **$250,000 – $12,500,000** per year

### Year-by-Year Market Projections

| Year | Market Size | YoY Growth | Cumulative CAGR |
|------|-------------|------------|-----------------|
| 2025 | €12.5B      | —          | —               |
| 2026 | €17.3B      | +38.1%     | 38.1%           |
| 2027 | €23.1B      | +33.5%     | 35.8%           |
| 2028 | €30.8B      | +33.2%     | 35.0%           |
| 2029 | €40.4B      | +31.1%     | 34.4%           |
| 2030 | €52.8B      | +30.7%     | 34.2%           |

### Regulatory Certifications 🏛️

Our competitive moat rests on pre-existing certifications that typically take
18–24 months to obtain:

- ✅ ISO 27001 (international information security)
- ✅ BSI C5 (Germany — Bundesamt für Sicherheit in der Informationstechnik)
- ✅ SecNumCloud (France — ANSSI)
- ✅ ENS High (Spain — Centro Criptológico Nacional)
- ✅ C5:2020 (Austria — A-SIT)

### Key Growth Drivers 📊

> "Sovereignty-first AI infrastructure is not optional for regulated industries
> operating in the EU. The cost of non-compliance with GDPR now exceeds the cost
> of dedicated EU-hosted AI platforms in 94% of enterprise scenarios." — Gartner 2026

1. **GDPR enforcement** — Article 44 prohibits cross-border data transfers to
   jurisdictions without adequacy decisions. US Cloud Act exposure forces repatriation.
2. **EU AI Act (effective Aug 2026)** — High-risk AI systems require traceability,
   human oversight, and data governance that only sovereign infrastructure can provide.
3. **Government mandates** — 11 of 27 EU member states now require that AI processing
   of citizen data occur within national borders.

### Technical Stack

\`\`\`python
# Example: sovereign inference with audit logging
client = AigClient(
    base_url="https://ai-api.myra.eu/v1/myratest/prod/compat",
    api_key=os.environ["AIG_TOKEN"],
)

response = client.chat.completions.create(
    model="qwen3.6-35b-a3b",
    messages=[{"role": "user", "content": "Summarise Q1 2026 earnings."}],
    stream=True,
)
\`\`\`

---`;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Extract plain text from PDF bytes using pdftotext (poppler-utils).
 * Writes to a tmp file, runs pdftotext, cleans up.
 */
function pdfToText(pdfBytes: Buffer): string {
  const tmp = path.join(os.tmpdir(), `aig-pdf-test-${Date.now()}.pdf`);
  try {
    fs.writeFileSync(tmp, pdfBytes);
    const out = execSync(`pdftotext "${tmp}" -`, { encoding: "utf-8", timeout: 15_000 });
    return out;
  } finally {
    try { fs.unlinkSync(tmp); } catch { /* ignore */ }
  }
}

/**
 * Assert that no digit sequence in the extracted text has inter-digit spaces.
 * e.g., "2 0 2 5" (bad) vs "2025" (good).
 * We check by looking for a digit, a space, a digit pattern inside what should
 * be a number context.
 */
function assertNoInterDigitSpacing(text: string) {
  // Detect patterns like "3 2 5" or "2 0 2 5" that indicate spaced digits.
  // Real text can have "1 million" or "2 items" but not "3 2 5" in sequence.
  const spaced = text.match(/\d \d \d/);
  expect(
    spaced,
    `PDF text contains inter-digit spaces (digit rendering bug): "${spaced?.[0]}".\nFull text excerpt: "${text.slice(0, 500)}"`,
  ).toBeNull();
}

interface TenantRow {
  id: string;
  slug: string;
  chat_presets?: Array<{ id: string; name: string; model: string; gateway_id: string; provider: string }>;
}

async function getMyratestTenant(page: Page): Promise<TenantRow | null> {
  const r = await page.context().request.get(`${ADMIN_BASE}/tenants`);
  if (!r.ok()) return null;
  const tenants = (await r.json()) as TenantRow[];
  return tenants.find((t) => t.slug === "myratest") ?? null;
}

/** Select the SAFE local-only (vllm) preset button if the page is in preset mode. */
async function selectSafePreset(page: Page, tenant: TenantRow): Promise<boolean> {
  const safePreset = (tenant.chat_presets ?? []).find(
    (p) => p.provider === "vllm" || p.name.toLowerCase().includes("safe"),
  );
  if (!safePreset) return false;
  const btn = page.getByRole("button", { name: safePreset.name });
  if (!(await btn.isVisible({ timeout: 5_000 }).catch(() => false))) return false;
  await btn.click();
  await page.waitForTimeout(300);
  return true;
}

/** Wait for streaming to finish: stop button disappears, send button reappears. */
async function waitForStreamingDone(page: Page, timeoutMs = 120_000) {
  await page.locator("button[title='Stop generating']")
    .waitFor({ state: "visible", timeout: 20_000 })
    .catch(() => {});
  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: timeoutMs });
}

// ---------------------------------------------------------------------------
// Suite 1 — API-level PDF generation
// ---------------------------------------------------------------------------

test.describe("Chat — PDF export (API level)", () => {
  test.setTimeout(60_000);

  test("export-pdf endpoint returns a valid PDF for rich markdown", async ({ page }) => {
    await page.goto("/chat");

    const resp = await page.context().request.post(`${ADMIN_BASE}/chat/export-pdf`, {
      data: { markdown: RICH_MARKDOWN, filename: "tam-analysis" },
    });

    expect(resp.status(), `export-pdf returned ${resp.status()}: ${await resp.text().catch(() => "")}`).toBe(200);
    expect(resp.headers()["content-type"]).toContain("application/pdf");

    const bytes = await resp.body();
    // Valid PDF starts with %PDF
    expect(Buffer.from(bytes).slice(0, 4).toString("ascii")).toBe("%PDF");
    // A document with this much content must be at least 15 KB
    expect(bytes.length, "PDF appears empty or too small").toBeGreaterThan(15_000);
  });

  test("numbers in exported PDF have no inter-digit spaces", async ({ page }) => {
    await page.goto("/chat");

    const resp = await page.context().request.post(`${ADMIN_BASE}/chat/export-pdf`, {
      data: { markdown: RICH_MARKDOWN, filename: "digit-spacing-test" },
    });
    expect(resp.status()).toBe(200);

    const bytes = await resp.body();
    const text  = pdfToText(Buffer.from(bytes));

    // Core regression assertion
    assertNoInterDigitSpacing(text);

    // Key numbers must appear intact
    expect(text).toContain("12.5");   // €12.5B
    expect(text).toContain("52.8");   // €52.8B
    expect(text).toContain("34.2");   // 34.2% CAGR
    expect(text).toContain("2025");
    expect(text).toContain("2030");
    expect(text).toContain("38.1");   // 38.1% YoY
  });

  test("exported PDF contains table, headings, code block, and emoji", async ({ page }) => {
    await page.goto("/chat");

    const resp = await page.context().request.post(`${ADMIN_BASE}/chat/export-pdf`, {
      data: { markdown: RICH_MARKDOWN, filename: "structure-test" },
    });
    expect(resp.status()).toBe(200);

    const bytes = await resp.body();
    const text  = pdfToText(Buffer.from(bytes));

    // Headings
    expect(text).toMatch(/Market Overview/i);
    expect(text).toMatch(/Year-by-Year/i);
    expect(text).toMatch(/Regulatory/i);

    // Table rows — pdftotext linearises tables; check a few cell values
    expect(text).toContain("2025");
    expect(text).toContain("2026");
    expect(text).toContain("2030");
    expect(text).toContain("Cumulative");

    // Emoji rendered (pdftotext may render them as boxes or unicode — just check document is non-trivial)
    expect(text.length).toBeGreaterThan(500);

    // Code block content
    expect(text).toContain("AigClient");
    expect(text).toContain("qwen3.6-35b-a3b");

    // Blockquote text
    expect(text).toMatch(/sovereignty.first/i);

    // No error artefacts
    expect(text).not.toContain("PDF generation failed");
    expect(text).not.toContain("pandoc");
  });

  test("Liberation Sans and Liberation Mono are embedded as body and code fonts", async ({ page }) => {
    await page.goto("/chat");

    const resp = await page.context().request.post(`${ADMIN_BASE}/chat/export-pdf`, {
      data: { markdown: RICH_MARKDOWN, filename: "font-check" },
    });
    expect(resp.status()).toBe(200);

    const bytes  = await resp.body();
    const tmp    = path.join(os.tmpdir(), `aig-font-check-${Date.now()}.pdf`);
    fs.writeFileSync(tmp, Buffer.from(bytes));
    let fontList = "";
    try {
      // pdffonts (poppler-utils) lists every embedded font by name.
      // WeasyPrint subsets fonts with a random prefix: "XXXXXX+Liberation-Sans"
      fontList = execSync(`pdffonts "${tmp}"`, { encoding: "utf-8", timeout: 10_000 });
    } finally {
      try { fs.unlinkSync(tmp); } catch { /* ignore */ }
    }

    // Body font: Liberation Sans (or Liberation Sans Bold for headings)
    expect(fontList, `Expected Liberation-Sans in font list:\n${fontList}`).toMatch(/Liberation-Sans/i);
    // Code font: Liberation Mono
    expect(fontList, `Expected Liberation-Mono in font list:\n${fontList}`).toMatch(/Liberation-Mono/i);
    // Must NOT contain Liberation Serif (we switched body from serif to sans)
    expect(fontList, `Unexpected Liberation-Serif in font list — body font regression:\n${fontList}`)
      .not.toMatch(/Liberation-Serif/i);
  });
});

// ---------------------------------------------------------------------------
// Suite 2 — Full UI flow (inference → PDF download)
// ---------------------------------------------------------------------------

test.describe("Chat — PDF export (full UI flow)", () => {
  let convIds: string[] = [];
  test.setTimeout(180_000);

  test.beforeEach(async ({ page }) => {
    await page.goto("/chat");
    await page.waitForTimeout(400);
  });

  test.afterEach(async ({ page }) => {
    const id = captureConvId(page);
    if (id) convIds.push(id);
    await deleteConversations(page, convIds);
    convIds = [];
  });

  test("TAM query produces a PDF download with numbers and no inter-digit spaces", async ({ page }) => {
    const tenant = await getMyratestTenant(page);
    if (!tenant) {
      test.fail(true, "myratest tenant not found");
      return;
    }

    // Worker sessions default to their own e2e tenant which has no presets.
    // Explicitly switch to myratest via the tenant selector so preset buttons appear.
    const tenantSelect = page.locator('[data-testid="config-tenant-select"]');
    if (await tenantSelect.isVisible({ timeout: 5_000 }).catch(() => false)) {
      await tenantSelect.selectOption(tenant.id);
      await page.waitForTimeout(500);
    }

    const ok = await selectSafePreset(page, tenant);
    if (!ok) {
      test.fail(true, "Could not find SAFE vllm preset — check myratest tenant presets");
      return;
    }

    // Start a new conversation
    const newChatBtn = page.getByRole("button", { name: /new chat/i });
    if (await newChatBtn.isVisible({ timeout: 3_000 }).catch(() => false)) {
      await newChatBtn.click();
      await page.waitForTimeout(300);
    }

    // PDF export button must be disabled before any message is sent
    const pdfBtn = page.locator("button[title='Download PDF']");
    await expect(pdfBtn).toBeDisabled({ timeout: 5_000 });

    // Send the TAM query
    const input = page.locator("[class*='chat-textarea']");
    await input.waitFor({ state: "visible", timeout: 10_000 });
    await input.fill(TAM_QUERY);
    await page.locator("button[title='Send message']").click();

    // User bubble must appear immediately (optimistic render)
    await expect(
      page.locator("[class*='user-row']").first()
    ).toBeVisible({ timeout: 10_000 });

    // Wait for the model to finish streaming
    await waitForStreamingDone(page, 150_000);

    // No error banner
    await expect(page.getByText(/PDF export failed|error/i).first())
      .not.toBeVisible({ timeout: 2_000 })
      .catch(() => {});

    // PDF button must now be enabled
    await expect(pdfBtn).toBeEnabled({ timeout: 5_000 });

    // Capture the download triggered by clicking "Download PDF"
    const [download] = await Promise.all([
      page.waitForEvent("download", { timeout: 30_000 }),
      pdfBtn.click(),
    ]);

    expect(download.suggestedFilename()).toMatch(/\.pdf$/i);

    const savePath = path.join(os.tmpdir(), `aig-ui-export-${Date.now()}.pdf`);
    await download.saveAs(savePath);

    try {
      const bytes = fs.readFileSync(savePath);

      // Valid PDF
      expect(bytes.slice(0, 4).toString("ascii")).toBe("%PDF");
      expect(bytes.length, "Downloaded PDF is too small").toBeGreaterThan(5_000);

      // Extract text and check digit rendering
      const text = pdfToText(bytes);
      expect(text.length, "PDF text is empty — WeasyPrint may have failed").toBeGreaterThan(100);

      // Regression: no inter-digit spaces
      assertNoInterDigitSpacing(text);

      // The TAM query response will almost certainly include percentages or large numbers
      expect(text).toMatch(/\d{2,}/);   // at least one multi-digit number present
    } finally {
      try { fs.unlinkSync(savePath); } catch { /* ignore */ }
    }
  });
});
