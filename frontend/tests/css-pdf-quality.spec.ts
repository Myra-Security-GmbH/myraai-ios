/**
 * css-pdf-quality.spec.ts — PDF CSS rendering quality tests.
 *
 * Uses the /admin/v1/chat/export-pdf endpoint and pymupdf (available in the
 * Docker container) for geometric analysis of the produced PDF.
 *
 * Tests confirm actual rendering issues and serve as regression guards.
 *
 * Issues detected (tests FAIL until fixed):
 *   • Blockquote not visually emphasised — its before/after gap equals plain
 *     paragraph gap.  Root cause: `blockquote { margin: 0 0 0 1em }` — zero
 *     vertical margin.  Fix: add `margin-top: 14pt; margin-bottom: 14pt`.
 *
 * Regression guards (tests PASS now, catch future regressions):
 *   • Paragraphs have at least 10pt spacing (currently ~16.9pt from pandoc CSS)
 *   • List items are distinguishable (gap > 0pt)
 *   • Page is standard A4 (595±3 × 842±3 pt)
 *   • H2 headings have more space before than after (visual hierarchy)
 */

import { test, expect, type Page } from "./base";
import { execSync } from "child_process";
import * as fs   from "fs";
import * as path from "path";
import * as os   from "os";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const ADMIN_URL  = process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173";
const ADMIN_BASE = `${ADMIN_URL}/admin/v1`;
const CONTAINER  = "ai-gateway-gateway-1";

// ---------------------------------------------------------------------------
// Markdown fixtures
// ---------------------------------------------------------------------------

const TWO_PARAGRAPHS_MD = `# Spacing Test

First paragraph with some text content that fills the line nicely.

Second paragraph with different text content to measure the gap.
`;

const BLOCKQUOTE_MD = `# Blockquote Test

Paragraph before the blockquote goes here with some text.

> This is a blockquote that should have more vertical breathing room than a plain paragraph.

Paragraph after the blockquote goes here with some text.
`;

const LIST_MD = `# List Test

- Alpha list item with enough text to be a distinct block
- Beta list item with enough text to be a distinct block
- Gamma list item with enough text to be a distinct block
`;

const HEADING_HIERARCHY_MD = `# Document Title

Opening paragraph text.

## Section Heading

Section content paragraph.

## Another Section

More content here.
`;

// ---------------------------------------------------------------------------
// Pymupdf geometry helper
// ---------------------------------------------------------------------------

/**
 * pymupdf analysis script.  Uses get_text("blocks") which returns tuples:
 *   (x0, y0, x1, y1, text, block_no, block_type)
 * block_type 0 = text, 1 = image.
 */
const PYMUPDF_SCRIPT = `
import fitz, json, sys

doc = fitz.open(sys.argv[1])
page = doc[0]

raw_blocks = page.get_text("blocks")

text_blocks = []
for b in raw_blocks:
    # tuple: (x0, y0, x1, y1, text, block_no, type)
    if len(b) < 7 or b[6] != 0:
        continue
    text = b[4].strip()
    if not text:
        continue
    text_blocks.append({
        "y0":  round(b[1], 1),
        "y1":  round(b[3], 1),
        "x0":  round(b[0], 1),
        "text": text[:100],
    })

text_blocks.sort(key=lambda b: b["y0"])

gaps = []
for i in range(1, len(text_blocks)):
    gaps.append({
        "gap_pt":    round(text_blocks[i]["y0"] - text_blocks[i-1]["y1"], 1),
        "prev_text": text_blocks[i-1]["text"],
        "next_text": text_blocks[i]["text"],
    })

print(json.dumps({
    "page_w":      round(page.rect.width,  1),
    "page_h":      round(page.rect.height, 1),
    "first_y":     text_blocks[0]["y0"] if text_blocks else 0,
    "last_y":      text_blocks[-1]["y1"] if text_blocks else 0,
    "block_count": len(text_blocks),
    "blocks":      text_blocks,
    "gaps":        gaps,
}))
`;

interface Block {
  y0: number; y1: number; x0: number; text: string;
}
interface Gap {
  gap_pt: number; prev_text: string; next_text: string;
}
interface PdfGeometry {
  page_w: number; page_h: number;
  first_y: number; last_y: number;
  block_count: number;
  blocks: Block[];
  gaps: Gap[];
}

function pdfGeometry(pdfBytes: Buffer): PdfGeometry {
  const stamp      = `${Date.now()}-${Math.floor(Math.random() * 10000)}`;
  const hostPdf    = path.join(os.tmpdir(), `aig-geo-${stamp}.pdf`);
  const hostScript = path.join(os.tmpdir(), `aig-geo-${stamp}.py`);
  const ctrPdf     = `/tmp/aig-geo-${stamp}.pdf`;
  const ctrScript  = `/tmp/aig-geo-${stamp}.py`;

  fs.writeFileSync(hostPdf,    pdfBytes);
  fs.writeFileSync(hostScript, PYMUPDF_SCRIPT);

  try {
    execSync(`docker cp "${hostPdf}"    ${CONTAINER}:"${ctrPdf}"`,    { timeout: 10_000 });
    execSync(`docker cp "${hostScript}" ${CONTAINER}:"${ctrScript}"`, { timeout: 10_000 });
    const raw = execSync(
      `docker exec ${CONTAINER} python3 "${ctrScript}" "${ctrPdf}"`,
      { encoding: "utf-8", timeout: 30_000 },
    );
    return JSON.parse(raw) as PdfGeometry;
  } finally {
    try { fs.unlinkSync(hostPdf);    } catch { /* ignore */ }
    try { fs.unlinkSync(hostScript); } catch { /* ignore */ }
    try {
      execSync(`docker exec ${CONTAINER} rm -f "${ctrPdf}" "${ctrScript}"`, { timeout: 5_000 });
    } catch { /* ignore */ }
  }
}

async function exportPdf(page: Page, markdown: string): Promise<Buffer> {
  const resp = await page.context().request.post(`${ADMIN_BASE}/chat/export-pdf`, {
    data: { markdown, filename: "quality-test" },
  });
  expect(
    resp.status(),
    `export-pdf returned ${resp.status()}: ${await resp.text().catch(() => "")}`,
  ).toBe(200);
  return Buffer.from(await resp.body());
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

test.describe("Chat — PDF CSS quality (geometry)", () => {
  test.setTimeout(90_000);

  test.beforeEach(async ({ page }) => {
    await page.goto("/chat");
  });

  // ── 1. Blockquote emphasis (FAILS until fixed) ────────────────────────────
  //
  // A blockquote should be visually distinguished from regular paragraphs by
  // having MORE vertical breathing room.  Currently blockquote has
  // `margin: 0 0 0 1em` (zero vertical margins), so its gap equals a normal
  // paragraph gap.  After adding `blockquote { margin-top: 14pt; margin-bottom: 14pt; }`
  // the blockquote gaps will be larger than plain paragraph gaps.

  test("blockquote has more vertical spacing than a plain paragraph (emphasis)", async ({ page }) => {
    // Run sequentially to avoid race on the export-pdf temp-file naming.
    const bqBytes   = await exportPdf(page, BLOCKQUOTE_MD);
    const paraBytes = await exportPdf(page, TWO_PARAGRAPHS_MD);

    const bqGeo   = pdfGeometry(bqBytes);
    const paraGeo = pdfGeometry(paraBytes);

    // Measure gap between two adjacent paragraphs (baseline)
    const paraGap = paraGeo.gaps.find(
      (g) => g.prev_text.includes("First paragraph") || g.next_text.includes("Second paragraph"),
    );
    expect(
      paraGap,
      `Could not find paragraph-to-paragraph gap.\nGaps: ${JSON.stringify(paraGeo.gaps)}`,
    ).toBeDefined();

    // Measure gap before the blockquote
    const gapBeforeBq = bqGeo.gaps.find(
      (g) => g.next_text.toLowerCase().includes("blockquote") ||
             g.next_text.toLowerCase().includes("breathing room"),
    );
    expect(
      gapBeforeBq,
      `Could not find gap before blockquote.\nBlocks: ${JSON.stringify(bqGeo.blocks.map((b) => b.text))}`,
    ).toBeDefined();

    const paraGapPt = paraGap!.gap_pt;
    const bqGapPt   = gapBeforeBq!.gap_pt;

    // The blockquote gap should be noticeably larger than a plain paragraph gap.
    // Currently they are equal (~16.9pt each), so this test FAILS.
    // After fix (add margin-top: 14pt to blockquote), blockquote gap will be
    // larger than the plain paragraph gap.
    expect(
      bqGapPt,
      `Blockquote pre-gap (${bqGapPt}pt) is not larger than paragraph gap (${paraGapPt}pt).\n` +
        `Blockquotes should have extra emphasis through increased vertical spacing.\n` +
        `Fix: change "blockquote { margin: 0 0 0 1em }" to ` +
        `"blockquote { margin: 14pt 0 14pt 1em }" in src/admin/chat.lua PDF CSS.`,
    ).toBeGreaterThan(paraGapPt + 1);
  });

  // ── 2. Paragraph spacing regression guard ────────────────────────────────

  test("consecutive paragraphs have at least 10pt vertical spacing", async ({ page }) => {
    const bytes = await exportPdf(page, TWO_PARAGRAPHS_MD);
    const geo   = pdfGeometry(bytes);

    const paraGap = geo.gaps.find(
      (g) => g.prev_text.includes("First paragraph") || g.next_text.includes("Second paragraph"),
    );
    expect(
      paraGap,
      `Could not find gap between the two paragraphs.\nAll gaps: ${JSON.stringify(geo.gaps)}`,
    ).toBeDefined();

    expect(
      paraGap!.gap_pt,
      `Paragraph gap is ${paraGap!.gap_pt}pt — expected ≥ 10pt (regression guard).\n` +
        `Ensure "p { margin-bottom }" is set in the PDF CSS.`,
    ).toBeGreaterThanOrEqual(10);
  });

  // ── 3. List items are distinguishable ────────────────────────────────────

  test("list items have positive vertical spacing between them", async ({ page }) => {
    const bytes = await exportPdf(page, LIST_MD);
    const geo   = pdfGeometry(bytes);

    // List items render with their bullet character (•) as a separate block at the
    // same y position.  Compute gaps between consecutive TEXT content blocks
    // (not bullets) by finding the blocks that contain list keyword text and
    // computing the direct y-coordinate gap between them.
    const listKeywords = ["Alpha", "Beta", "Gamma"];
    const listBlocks   = geo.blocks.filter((b) =>
      listKeywords.some((k) => b.text.includes(k)),
    );

    expect(
      listBlocks.length,
      `Expected 3 list item text blocks, found ${listBlocks.length}.\n` +
        `Blocks: ${JSON.stringify(geo.blocks.map((b) => b.text))}`,
    ).toBe(3);

    for (let i = 1; i < listBlocks.length; i++) {
      const gap = listBlocks[i].y0 - listBlocks[i - 1].y1;
      expect(
        gap,
        `Gap between list item "${listBlocks[i - 1].text.slice(0, 20)}" → ` +
          `"${listBlocks[i].text.slice(0, 20)}" is ${gap}pt (expected > 0).`,
      ).toBeGreaterThan(0);
    }
  });

  // ── 4. Page is standard A4 ────────────────────────────────────────────────

  test("exported PDF uses A4 page dimensions", async ({ page }) => {
    const bytes = await exportPdf(page, TWO_PARAGRAPHS_MD);
    const geo   = pdfGeometry(bytes);

    // A4: 595.28 × 841.89 pt (allow ±3pt)
    expect(
      geo.page_w,
      `PDF page width is ${geo.page_w}pt — expected ≈ 595pt (A4). ` +
        `Add '@page { size: A4; }' to the PDF CSS.`,
    ).toBeGreaterThanOrEqual(592);
    expect(geo.page_w).toBeLessThanOrEqual(598);

    expect(
      geo.page_h,
      `PDF page height is ${geo.page_h}pt — expected ≈ 842pt (A4).`,
    ).toBeGreaterThanOrEqual(839);
    expect(geo.page_h).toBeLessThanOrEqual(845);
  });

  // ── 5. Heading hierarchy: h2 has more space before than after ─────────────

  test("h2 headings have more vertical space before them than after (visual hierarchy)", async ({ page }) => {
    const bytes = await exportPdf(page, HEADING_HIERARCHY_MD);
    const geo   = pdfGeometry(bytes);

    // Find the first h2 ("Section Heading")
    const gapBefore = geo.gaps.find((g) => g.next_text.includes("Section Heading"));
    const gapAfter  = geo.gaps.find((g) => g.prev_text.includes("Section Heading"));

    expect(
      gapBefore,
      `Could not find gap BEFORE "Section Heading".\nAll gaps: ${JSON.stringify(geo.gaps)}`,
    ).toBeDefined();
    expect(
      gapAfter,
      `Could not find gap AFTER "Section Heading".\nAll gaps: ${JSON.stringify(geo.gaps)}`,
    ).toBeDefined();

    expect(
      gapBefore!.gap_pt,
      `Gap before h2 (${gapBefore!.gap_pt}pt) should be greater than gap after h2 ` +
        `(${gapAfter!.gap_pt}pt) to convey visual hierarchy.\n` +
        `Current CSS: h2 { margin-top: 18pt; margin-bottom: 4pt; } — this should already pass.`,
    ).toBeGreaterThan(gapAfter!.gap_pt);
  });
});
