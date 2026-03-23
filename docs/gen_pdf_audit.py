#!/usr/bin/env python3
"""
gen_pdf_audit.py — visual + structural audit of docs/out/ai-gateway-docs.pdf

Pass A (structural):  analyse the standalone HTML that gen_pdf.py builds,
                      before any rendering happens.  Catches problems that
                      have deterministic fixes.

Pass B (visual):      rasterise every PDF page with pdftoppm (96 dpi) and
                      run pixel-level heuristics to find real rendering
                      artefacts — overflow, blank pages, oversized content.

Output:
    docs/out/audit-report.html   — annotated thumbnail gallery
    stdout                       — summary table

Usage:
    python3 gen_pdf_audit.py [--pdf PATH] [--dpi N] [--open]
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import html as html_module
from dataclasses import dataclass, field
from pathlib import Path

HERE    = Path(__file__).parent
IN_HTML = HERE / "out" / "print_page" / "index.html"
IN_PDF  = HERE / "out" / "ai-gateway-docs.pdf"
REPORT  = HERE / "out" / "audit-report.html"

# ── A4 at 96 dpi (matches WeasyPrint's internal resolution)
A4_W_PX = 794
A4_H_PX = 1123

# Margins must match print.css @page exactly.
MARGIN_LR_MM  = 20     # left and right  (@page margin: 23mm 20mm 26mm 20mm)
MARGIN_TOP_MM = 23
MARGIN_BOT_MM = 26

MARGIN_PX  = int(MARGIN_LR_MM / 25.4 * 96)
CONTENT_W  = A4_W_PX - 2 * MARGIN_PX
CONTENT_H  = A4_H_PX - int((MARGIN_TOP_MM + MARGIN_BOT_MM) / 25.4 * 96)


@dataclass
class Issue:
    page:     int
    kind:     str          # OVERFLOW | BLANK | NEAR_BLANK | TALL_CONTENT | LONG_LINE | WIDE_TABLE | WIDE_IMAGE | CLIPPED_BOTTOM
    detail:   str
    severity: str = "warn" # warn | error


@dataclass
class PageResult:
    page_no:   int
    img_path:  str = ""
    issues:    list[Issue] = field(default_factory=list)


# ─────────────────────────────────────────────────────────────────────────────
# Pass C — HTML structural checks
# ─────────────────────────────────────────────────────────────────────────────

def pass_c(html_path: Path) -> list[Issue]:
    issues: list[Issue] = []
    with open(html_path, encoding="utf-8") as f:
        raw = f.read()

    # Extract content block
    m = re.search(r'<div id="print-site-page"', raw)
    if not m:
        return issues
    start = raw.index('>', m.start()) + 1
    content = raw[start:]   # good enough for pattern scanning

    # ── Long lines in code blocks ──────────────────────────────────────────
    # Extract all <pre> inner text
    for pre_m in re.finditer(r'<pre[^>]*>(.*?)</pre>', content, re.DOTALL):
        text = re.sub(r'<[^>]+>', '', pre_m.group(1))
        for i, line in enumerate(text.splitlines(), 1):
            if len(line) > 110:
                issues.append(Issue(
                    page=0, kind="LONG_LINE",
                    detail=f"Code block line {i} is {len(line)} chars (>110) — may overflow or wrap badly"
                ))
                break  # one warning per block

    # ── Wide tables (many columns) ─────────────────────────────────────────
    for th_block in re.finditer(r'<thead[^>]*>(.*?)</thead>', content, re.DOTALL):
        cols = len(re.findall(r'<th[\s>]', th_block.group(1)))
        if cols >= 6:
            hdr_text = re.sub(r'<[^>]+>', '', th_block.group(1))[:60].strip()
            issues.append(Issue(
                page=0, kind="WIDE_TABLE",
                detail=f'{cols}-column table starting "{hdr_text}..." may overflow A4'
            ))

    # ── Images wider than the content column ──────────────────────────────
    for img_m in re.finditer(r'<img[^>]+>', content):
        tag = img_m.group(0)
        w_m = re.search(r'width="(\d+)"', tag)
        if w_m and int(w_m.group(1)) > CONTENT_W:
            src_s = re.search(r'src="([^"]+)"', tag) or re.search(r"src='([^']+)'", tag)
            src_str = src_s.group(1)[-40:] if src_s else "?"
            issues.append(Issue(
                page=0, kind="WIDE_IMAGE",
                detail=f"Image …{src_str} has width={w_m.group(1)}px > content column ({CONTENT_W}px)"
            ))

    # ── Mermaid blocks: check that PDF was rebuilt after source HTML ──────
    # gen_pdf.py pre-renders mermaid to SVG in-memory; the source HTML always
    # has raw <pre class="mermaid"> blocks.  We cannot check the in-memory
    # output, but we can warn if the PDF is older than the source HTML.
    raw_mermaid = len(re.findall(r'<pre[^>]+class="[^"]*\bmermaid\b', content))
    if raw_mermaid:
        pdf_path = html_path.parent.parent / "ai-gateway-docs.pdf"
        if pdf_path.exists() and html_path.exists():
            if pdf_path.stat().st_mtime < html_path.stat().st_mtime:
                issues.append(Issue(
                    page=0, kind="RAW_MERMAID",
                    severity="error",
                    detail=(
                        f"{raw_mermaid} Mermaid block(s) found and PDF is older than source HTML "
                        f"— run gen_pdf.py to pre-render diagrams"
                    )
                ))

    # ── foreignObject still in content (would make text invisible) ────────
    fo_count = content.count('<foreignObject')
    if fo_count:
        issues.append(Issue(
            page=0, kind="FOREIGN_OBJECT",
            severity="error",
            detail=f"{fo_count} <foreignObject> element(s) remain — text will be invisible in WeasyPrint"
        ))

    # ── Mermaid source label line-length check ─────────────────────────────
    # With wrappingWidth=150 and Trebuchet MS ~7.8 px/char at 14 px,
    # ~19 chars fit in a node box.  Flag lines > LABEL_LINE_THRESH chars
    # as likely to overflow even after wrapping.  This is a fast source-only
    # check; the accurate rendered check runs in pass_d().
    issues += _check_mermaid_source_labels(content)

    print(f"  Pass C: {len(issues)} structural issue(s) found")
    return issues


# ── Mermaid source-label helpers ──────────────────────────────────────────

# Only flag *explicitly* multi-line labels (those with <br/> breaks) whose
# individual lines are long enough to overflow even after adaptive font scaling.
# Single-line labels are auto-wrapped by mmdc via wrappingWidth=150; no flag needed.
#
# Threshold derivation:
#   adaptive font floor = 8px; Trebuchet MS ≈ 0.557em/char → 4.45 px/char at 8px
#   wrappingWidth 150px node box → max chars = 150 / 4.45 ≈ 34 chars
LABEL_LINE_THRESH = 34   # chars per explicit line before overflow is unavoidable

# Matches <pre class="mermaid"> blocks (HTML-entity-encoded inside)
_MERMAID_BLOCK_RE = re.compile(
    r'<pre[^>]+class="[^"]*\bmermaid\b[^"]*"[^>]*>\s*(?:<code[^>]*>)?(.*?)(?:</code>)?\s*</pre>',
    re.DOTALL | re.IGNORECASE,
)

# Extract text labels from Mermaid node/subgraph definitions
_LABEL_QUOTED_RE  = re.compile(r'\["(.*?)"\]|\("(.*?)"\)', re.DOTALL)
_LABEL_BARE_RE    = re.compile(r'(?:^|[\s>|])\[([^\[\]"<>\n]{2,})\]')
_LABEL_SUBGRAPH_RE = re.compile(r'subgraph\s+\w*\s*\["(.*?)"\]|subgraph\s+"(.*?)"', re.DOTALL)


def _mermaid_label_lines(raw_label: str) -> list[str]:
    """Split a Mermaid label on explicit breaks; strip tags; return non-empty lines."""
    parts = re.split(r'<br\s*/?>', raw_label, flags=re.IGNORECASE)
    lines: list[str] = []
    for p in parts:
        for seg in p.split('\\n'):
            seg = re.sub(r'<[^>]+>', '', seg).strip()
            if seg:
                lines.append(seg)
    return lines


def _check_mermaid_source_labels(content: str) -> list[Issue]:
    """Scan Mermaid source blocks for label lines that likely overflow node boxes."""
    import html as _html
    issues: list[Issue] = []
    seen: set[str] = set()   # deduplicate identical labels across diagrams

    for block_no, bm in enumerate(_MERMAID_BLOCK_RE.finditer(content), 1):
        src = _html.unescape(bm.group(1)).strip()

        raw_labels: list[str] = []
        for m in _LABEL_QUOTED_RE.finditer(src):
            raw_labels.append(m.group(1) or m.group(2) or "")
        for m in _LABEL_BARE_RE.finditer(src):
            raw_labels.append(m.group(1))
        for m in _LABEL_SUBGRAPH_RE.finditer(src):
            raw_labels.append(m.group(1) or m.group(2) or "")

        for raw in raw_labels:
            # Only check explicitly multi-line labels — single-line labels are
            # auto-wrapped by mmdc (wrappingWidth=150) so they never overflow.
            is_multiline = bool(re.search(r'<br\s*/?>', raw, re.IGNORECASE)
                                or '\\n' in raw)
            if not is_multiline:
                continue
            for line in _mermaid_label_lines(raw):
                key = f"{block_no}:{line}"
                if key in seen or len(line) <= LABEL_LINE_THRESH:
                    continue
                seen.add(key)
                issues.append(Issue(
                    page=0, kind="LABEL_OVERFLOW",
                    detail=(
                        f"Diagram {block_no}: label line {len(line)} chars "
                        f"> {LABEL_LINE_THRESH} threshold — may overflow node box: "
                        f"{line!r}"
                    )
                ))

    return issues


# ─────────────────────────────────────────────────────────────────────────────
# Pass D — Mermaid SVG rendering + text-overflow analysis
# ─────────────────────────────────────────────────────────────────────────────
#
# Renders each Mermaid block with mmdc (same config as gen_pdf.py) and parses
# the resulting SVG.  For every <text> element we estimate its pixel width and
# check whether it extends outside the SVG viewBox.  Text that falls outside
# the viewBox is clipped in the PDF; text that only overflows a node box (but
# stays inside the viewBox) is caught instead by the label-length check above.

# Trebuchet MS average char width at 14px (matches gen_pdf.py)
_SVG_CHAR_PX = 7.8


def _svg_viewbox_width(svg: str) -> float | None:
    """Return the SVG viewBox width, or the width= attribute, or None."""
    vb = re.search(r'\bviewBox="([^"]+)"', svg)
    if vb:
        parts = vb.group(1).split()
        if len(parts) == 4:
            try:
                return float(parts[2])
            except ValueError:
                pass
    w_m = re.search(r'<svg[^>]+\bwidth="([^"px]+)', svg)
    if w_m:
        try:
            return float(w_m.group(1))
        except ValueError:
            pass
    return None


def _check_svg_text_overflow(svg: str, diagram_no: int,
                              svg_w: float) -> list[Issue]:
    """Return LABEL_OVERFLOW issues for <text> elements outside the viewBox."""
    issues: list[Issue] = []
    TOLERANCE = 8.0   # px — allow slight anti-aliasing overhang
    seen: set[str] = set()

    for tm in re.finditer(r'<text([^>]*)>(.*?)</text>', svg, re.DOTALL):
        attrs, body = tm.group(1), tm.group(2)

        # x position of the text anchor
        x_m = re.search(r'\bx="([^"]+)"', attrs)
        if not x_m:
            continue
        try:
            x = float(x_m.group(1))
        except ValueError:
            continue

        # font-size
        fs_m = re.search(r'font-size="(\d+(?:\.\d+)?)', attrs)
        fs = float(fs_m.group(1)) if fs_m else 14.0

        # text-anchor
        ta_m = re.search(r'text-anchor="([^"]+)"', attrs)
        anchor = ta_m.group(1) if ta_m else "start"

        # Collect all text content (prefer longest tspan line for width estimate)
        tspan_texts = re.findall(r'<tspan[^>]*>([^<]*)</tspan>', body)
        all_texts = tspan_texts if tspan_texts else [re.sub(r'<[^>]+>', '', body)]
        label = max(all_texts, key=len).strip()
        if not label:
            continue

        est_w = len(label) * _SVG_CHAR_PX * (fs / 14.0)

        if anchor == "middle":
            right_x, left_x = x + est_w / 2, x - est_w / 2
        elif anchor == "end":
            right_x, left_x = x, x - est_w
        else:
            right_x, left_x = x + est_w, x

        overflow_px = max(right_x - svg_w - TOLERANCE, -left_x - TOLERANCE, 0.0)
        if overflow_px <= 0:
            continue

        key = f"{diagram_no}:{label}"
        if key in seen:
            continue
        seen.add(key)
        issues.append(Issue(
            page=0, kind="LABEL_OVERFLOW",
            severity="error",
            detail=(
                f"Diagram {diagram_no}: SVG text overflows viewBox by "
                f"{overflow_px:.0f}px — '{label[:45]}' "
                f"(x={x:.0f}, est_w={est_w:.0f}, svg_w={svg_w:.0f})"
            )
        ))

    return issues


def pass_d(html_path: Path) -> list[Issue]:
    """Render each Mermaid block with mmdc and check SVG text for viewBox overflow."""
    import json as _json

    with open(html_path, encoding="utf-8") as f:
        raw = f.read()
    m = re.search(r'<div id="print-site-page"', raw)
    if not m:
        return []
    content = raw[raw.index('>', m.start()) + 1:]

    blocks_raw = _MERMAID_BLOCK_RE.findall(content)
    if not blocks_raw:
        return []

    import html as _html
    blocks = [_html.unescape(b).strip() for b in blocks_raw]

    # Write shared mmdc config (identical to gen_pdf.py)
    cfg_data = {"flowchart": {"htmlLabels": False, "wrappingWidth": 150},
                "sequence":  {"htmlLabels": False}}
    cfg_f = tempfile.NamedTemporaryFile(suffix=".json", mode="w",
                                        delete=False, encoding="utf-8")
    _json.dump(cfg_data, cfg_f)
    cfg_f.close()

    issues: list[Issue] = []
    rendered = 0

    print(f"  Pass D: rendering {len(blocks)} Mermaid block(s) with mmdc …")

    for i, src in enumerate(blocks, 1):
        # Replace <br/> → \n for consistent mmdc input (same as gen_pdf.py)
        src = re.sub(r'<br\s*/?>', '\n', src, flags=re.IGNORECASE)

        in_f = tempfile.NamedTemporaryFile(suffix=".mmd", mode="w",
                                           delete=False, encoding="utf-8")
        in_f.write(src)
        in_f.close()
        out_path = in_f.name.replace(".mmd", ".svg")

        try:
            result = subprocess.run(
                ["npx", "--yes", "@mermaid-js/mermaid-cli",
                 "-i", in_f.name, "-o", out_path,
                 "-b", "transparent", "-c", cfg_f.name, "--quiet"],
                capture_output=True, text=True, timeout=60,
            )
            if result.returncode != 0 or not os.path.exists(out_path):
                print(f"    Warning: mmdc failed for diagram {i}", file=sys.stderr)
                continue

            with open(out_path, encoding="utf-8") as f:
                svg = f.read()

            svg_w = _svg_viewbox_width(svg)
            if svg_w is None:
                continue

            diag_issues = _check_svg_text_overflow(svg, i, svg_w)
            if diag_issues:
                print(f"    Diagram {i}: {len(diag_issues)} overflow issue(s)")
            else:
                print(f"    Diagram {i}: OK (viewBox width {svg_w:.0f}px)")
            issues.extend(diag_issues)
            rendered += 1

        except subprocess.TimeoutExpired:
            print(f"    Warning: mmdc timed out for diagram {i}", file=sys.stderr)
        except FileNotFoundError:
            print("    Warning: npx/mmdc not found — skipping Pass D", file=sys.stderr)
            break
        finally:
            for p in (in_f.name, out_path):
                try:
                    os.unlink(p)
                except OSError:
                    pass

    try:
        os.unlink(cfg_f.name)
    except OSError:
        pass

    print(f"  Pass D: {len(issues)} overflow issue(s) across {rendered} rendered diagram(s)")
    return issues


# ─────────────────────────────────────────────────────────────────────────────
# Pass A — visual / pixel analysis
# ─────────────────────────────────────────────────────────────────────────────

def rasterise(pdf_path: Path, dpi: int, out_dir: Path) -> list[Path]:
    """Render PDF pages to PNG files via pdftoppm."""
    prefix = str(out_dir / "pg")
    result = subprocess.run(
        ["pdftoppm", "-r", str(dpi), "-png", str(pdf_path), prefix],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"ERROR: pdftoppm failed: {result.stderr[:200]}", file=sys.stderr)
        sys.exit(1)
    pages = sorted(out_dir.glob("pg-*.png"))
    print(f"  Rasterised {len(pages)} pages at {dpi} dpi")
    return pages


def analyse_page(img_path: Path, page_no: int, dpi: int) -> list[Issue]:
    """Run pixel heuristics on a single page PNG."""
    from PIL import Image
    import struct

    issues: list[Issue] = []
    img = Image.open(img_path).convert("RGB")
    w, h = img.size
    pixels = img.load()

    # Scale margins to actual render dpi
    scale    = dpi / 96.0
    margin_x     = int(MARGIN_PX * scale)
    margin_y_top = int((MARGIN_TOP_MM / 25.4 * 96) * scale)
    margin_y_bot = int((MARGIN_BOT_MM / 25.4 * 96) * scale)

    total_pixels = w * h
    white_threshold = 240   # per channel

    def is_white(r, g, b):
        return r >= white_threshold and g >= white_threshold and b >= white_threshold

    # ── Count non-white pixels ─────────────────────────────────────────────
    content_y_start = margin_y_top + int(12 * scale)   # skip header rule
    content_y_end   = h - margin_y_bot - int(12 * scale)
    content_x_start = margin_x
    content_x_end   = w - margin_x

    content_area = max(1, (content_y_end - content_y_start) * (content_x_end - content_x_start))
    filled = 0
    for y in range(content_y_start, content_y_end, 2):       # stride 2 for speed
        for x in range(content_x_start, content_x_end, 2):
            r, g, b = pixels[x, y]
            if not is_white(r, g, b):
                filled += 1

    fill_ratio = filled * 4 / content_area  # ×4 because stride=2 in both axes

    if fill_ratio < 0.015:
        issues.append(Issue(page=page_no, kind="BLANK",
            severity="error",
            detail=f"Page is {100*fill_ratio:.1f}% filled — probably an orphaned page break"))
    elif fill_ratio < 0.06:
        issues.append(Issue(page=page_no, kind="NEAR_BLANK",
            detail=f"Page is only {100*fill_ratio:.1f}% filled — likely wasted space after a section break"))

    # ── Right-edge overflow: non-white pixels well past the content area ──
    # Add an 8px safety gap beyond the content edge so anti-aliased text
    # at the very right column edge never triggers a false positive.
    overflow_x_start = w - margin_x + int(8 * scale)
    overflow_count   = 0
    for y in range(content_y_start, content_y_end, 3):
        for x in range(overflow_x_start, min(overflow_x_start + int(20 * scale), w), 2):
            r, g, b = pixels[x, y]
            if not is_white(r, g, b):
                overflow_count += 1

    if overflow_count > 20:
        issues.append(Issue(page=page_no, kind="OVERFLOW",
            severity="error",
            detail=f"{overflow_count} non-white pixels beyond right margin — content overflows"))

    # ── Tall content block: single dark rectangle > 75% of page height ────
    # Detect by scanning the centre column for continuous dark bands
    cx = w // 2
    dark_run = 0
    max_run  = 0
    for y in range(content_y_start, content_y_end):
        r, g, b = pixels[cx, y]
        if not is_white(r, g, b):
            dark_run += 1
            max_run   = max(max_run, dark_run)
        else:
            dark_run  = 0

    tall_threshold = (content_y_end - content_y_start) * 0.78
    if max_run > tall_threshold:
        pct = 100 * max_run / (content_y_end - content_y_start)
        issues.append(Issue(page=page_no, kind="TALL_CONTENT",
            detail=f"A single content block spans {pct:.0f}% of page height — may need splitting"))

    # ── Bottom clip: non-white pixels within bottom margin ────────────────
    clip_y_start = h - margin_y_bot + int(4 * scale)
    clip_count   = 0
    for y in range(clip_y_start, min(clip_y_start + int(10 * scale), h), 2):
        for x in range(content_x_start, content_x_end, 3):
            r, g, b = pixels[x, y]
            if not is_white(r, g, b):
                clip_count += 1

    if clip_count > 15:
        issues.append(Issue(page=page_no, kind="CLIPPED_BOTTOM",
            detail=f"{clip_count} non-white pixels in bottom margin — content clipped"))

    return issues


# ─────────────────────────────────────────────────────────────────────────────
# Report
# ─────────────────────────────────────────────────────────────────────────────

def build_report(results: list[PageResult], c_issues: list[Issue],
                 d_issues: list[Issue],
                 out_path: Path, dpi: int) -> None:
    """Write an HTML audit report with thumbnails and issue annotations."""

    severity_colour = {"error": "#c0392b", "warn": "#d08000"}

    rows = ""

    # Pass C: structural source issues
    if c_issues:
        rows += "<tr><td colspan='3' style='background:#f8f0e0;font-weight:700;padding:8px'>Structural (Pass C)</td></tr>\n"
        for iss in c_issues:
            col = severity_colour.get(iss.severity, "#555")
            rows += (f"<tr><td style='color:{col};font-weight:700'>—</td>"
                     f"<td style='color:{col}'>{iss.kind}</td>"
                     f"<td>{html_module.escape(iss.detail)}</td></tr>\n")

    # Pass D: Mermaid SVG overflow issues
    if d_issues:
        rows += "<tr><td colspan='3' style='background:#fdf0f8;font-weight:700;padding:8px'>Mermaid SVG overflow (Pass D)</td></tr>\n"
        for iss in d_issues:
            col = severity_colour.get(iss.severity, "#555")
            rows += (f"<tr><td style='color:{col};font-weight:700'>—</td>"
                     f"<td style='color:{col}'>{iss.kind}</td>"
                     f"<td>{html_module.escape(iss.detail)}</td></tr>\n")

    # Per-page issues
    flagged = [r for r in results if r.issues]
    if flagged:
        rows += "<tr><td colspan='3' style='background:#f0f4f8;font-weight:700;padding:8px'>Visual (Pass A)</td></tr>\n"

    for pr in flagged:
        for iss in pr.issues:
            col = severity_colour.get(iss.severity, "#555")
            thumb = f'<img src="{pr.img_path}" style="height:120px;border:1px solid #ccc;vertical-align:middle;margin-right:8px">' if pr.img_path else ""
            rows += (f"<tr>"
                     f"<td style='color:{col};font-weight:700;white-space:nowrap'>pg {iss.page}</td>"
                     f"<td style='color:{col}'>{iss.kind}</td>"
                     f"<td>{thumb}{html_module.escape(iss.detail)}</td>"
                     f"</tr>\n")

    total_issues = len(c_issues) + len(d_issues) + sum(len(r.issues) for r in results)
    errors  = sum(1 for i in c_issues if i.severity == "error") + \
              sum(1 for r in results for i in r.issues if i.severity == "error")
    warnings = total_issues - errors

    html_out = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>PDF Audit Report</title>
<style>
  body {{ font-family: system-ui, sans-serif; font-size: 13px; margin: 32px; color: #222; }}
  h1   {{ color: #002b49; }}
  .summary {{ background: #f4f8fb; border-left: 4px solid #002b49; padding: 12px 16px;
              margin-bottom: 24px; border-radius: 0 4px 4px 0; }}
  table {{ border-collapse: collapse; width: 100%; }}
  th    {{ background: #002b49; color: #fff; padding: 8px 12px; text-align: left; }}
  td    {{ padding: 7px 12px; border-bottom: 1px solid #e0e8f0; vertical-align: middle; }}
  tr:hover td {{ background: #f8fbff; }}
</style>
</head>
<body>
<h1>PDF Audit Report — AI Gateway Documentation</h1>
<div class="summary">
  <strong>Total issues:</strong> {total_issues} &nbsp;|&nbsp;
  <strong style="color:#c0392b">Errors:</strong> {errors} &nbsp;|&nbsp;
  <strong style="color:#d08000">Warnings:</strong> {warnings} &nbsp;|&nbsp;
  Pages analysed: {len(results)} &nbsp;|&nbsp;
  Render DPI: {dpi}
</div>
<table>
  <thead><tr><th>Page</th><th>Issue type</th><th>Detail</th></tr></thead>
  <tbody>
{"<tr><td colspan='3' style='color:#888;padding:16px'>No issues found.</td></tr>" if not rows else rows}
  </tbody>
</table>
</body>
</html>"""

    out_path.write_text(html_out, encoding="utf-8")


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Audit the generated PDF")
    parser.add_argument("--pdf",  default=str(IN_PDF),  help="PDF to audit")
    parser.add_argument("--html", default=str(IN_HTML), help="Print-page HTML for structural checks")
    parser.add_argument("--dpi",  type=int, default=96, help="Raster DPI (96 is fast; 150 for accuracy)")
    parser.add_argument("--open", action="store_true",  help="Open the report in a browser when done")
    args = parser.parse_args()

    pdf_path  = Path(args.pdf)
    html_path = Path(args.html)

    if not pdf_path.exists():
        print(f"ERROR: PDF not found: {pdf_path}", file=sys.stderr)
        print("       Run python3 gen_pdf.py first.", file=sys.stderr)
        sys.exit(1)
    if not html_path.exists():
        print(f"ERROR: HTML not found: {html_path}", file=sys.stderr)
        print("       Run docs/gen_docs.sh first.", file=sys.stderr)
        sys.exit(1)

    # ── Pass C: structural ────────────────────────────────────────────────
    print("→ Pass C — structural HTML analysis …")
    c_issues = pass_c(html_path)

    # ── Pass D: Mermaid SVG rendering + overflow ──────────────────────────
    print("→ Pass D — Mermaid SVG overflow analysis …")
    d_issues = pass_d(html_path)

    # ── Pass A: visual ────────────────────────────────────────────────────
    print(f"→ Pass A — rasterising {pdf_path.name} at {args.dpi} dpi …")
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        page_imgs = rasterise(pdf_path, args.dpi, tmp_path)

        print(f"  Analysing {len(page_imgs)} pages …")
        results: list[PageResult] = []
        for i, img_path in enumerate(page_imgs, 1):
            issues = analyse_page(img_path, i, args.dpi)
            # Copy flagged page thumbnails to out/ so the report can embed them
            rel_path = ""
            if issues:
                thumb_name = f"audit-pg{i:04d}.png"
                thumb_dest = REPORT.parent / thumb_name
                import shutil
                shutil.copy(img_path, thumb_dest)
                rel_path = thumb_name
            results.append(PageResult(page_no=i, img_path=rel_path, issues=issues))

        # ── Report ────────────────────────────────────────────────────────
        print(f"→ Writing report → {REPORT}")
        build_report(results, c_issues, d_issues, REPORT, args.dpi)

    # ── Summary ───────────────────────────────────────────────────────────
    all_static = c_issues + d_issues
    total   = len(all_static) + sum(len(r.issues) for r in results)
    errors  = sum(1 for i in all_static if i.severity == "error") + \
              sum(1 for r in results for i in r.issues if i.severity == "error")
    flagged = [r for r in results if r.issues]

    print()
    print(f"✓ {total} issue(s) found  ({errors} errors, {total-errors} warnings)")
    if flagged:
        print()
        print(f"  {'Page':>5}  {'Kind':<18}  Detail")
        print(f"  {'----':>5}  {'----':<18}  ------")
        for pr in flagged:
            for iss in pr.issues:
                sev = "ERR " if iss.severity == "error" else "WARN"
                print(f"  {iss.page:>5}  {iss.kind:<18}  [{sev}] {iss.detail[:70]}")
    if all_static:
        print()
        for iss in all_static:
            sev = "ERR " if iss.severity == "error" else "WARN"
            src = "D" if iss in d_issues else "C"
            print(f"  {src:>5}  {iss.kind:<18}  [{sev}] {iss.detail[:70]}")

    print()
    print(f"  Report: {REPORT}")

    if args.open:
        import webbrowser
        webbrowser.open(REPORT.as_uri())


if __name__ == "__main__":
    main()
