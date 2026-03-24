#!/usr/bin/env python3
"""
gen_pdf.py — generate docs/out/ai-gateway-docs.pdf from the print-site HTML.

Usage:
    python3 gen_pdf.py [--out PATH]

Prerequisites:
    pip install weasyprint pikepdf
    npm install -g @mermaid-js/mermaid-cli   (or: npx works too)
    Run docs/gen_docs.sh first so docs/out/print_page/index.html exists.

Strategy:
    The Material theme CSS is incompatible with WeasyPrint (JS-driven layout,
    CSS variables, custom properties).  We extract the raw content block from
    #print-site-page, wrap it in a minimal standalone HTML that only loads our
    own print.css, and render that.  This gives clean A4 output with brand
    colours, tables, code blocks, and screenshots — without Material baggage.

    Before rendering we:
      • Pre-render Mermaid diagrams to inline SVG via mmdc (Mermaid CLI),
        because WeasyPrint does not execute JavaScript.
      • Strip __codelineno anchor elements that MkDocs embeds in every code
        line (they only serve web line-linking; in PDF they add 1,700+ noise
        annotations).
"""

import argparse
import datetime
import glob
import html as html_module
import os
import re
import subprocess
import sys
import tempfile
import time

HERE     = os.path.dirname(os.path.abspath(__file__))
IN_HTML  = os.path.join(HERE, "out", "print_page", "index.html")
_now     = datetime.datetime.now()
_ts      = _now.strftime("%Y%m%d-%H%M%S")
_version = _now.strftime("%Y%m%d %H%M%S")
OUT_PDF  = os.path.join(HERE, "out", f"ai-gateway-docs-{_ts}.pdf")


# ---------------------------------------------------------------------------
# HTML extraction
# ---------------------------------------------------------------------------

def extract_print_section(html: str) -> str:
    """Return the inner HTML of #print-site-page."""
    marker = '<div id="print-site-page"'
    start_tag = html.index(marker)
    tag_end = html.index('>', start_tag) + 1
    depth = 1
    i = tag_end
    while i < len(html) and depth > 0:
        if html[i] == '<':
            if html[i:i+4] == '<div':
                depth += 1
            elif html[i:i+6] == '</div>':
                depth -= 1
                if depth == 0:
                    return html[tag_end:i]
        i += 1
    raise ValueError("Could not find closing </div> for #print-site-page")


# ---------------------------------------------------------------------------
# HTML clean-up passes
# ---------------------------------------------------------------------------

# Matches __codelineno anchor elements added by MkDocs for per-line web links.
_CODELINENO_RE = re.compile(
    r'<a\s[^>]*id="__codelineno-[^"]*"[^>]*></a>', re.IGNORECASE
)

def strip_codelineno_anchors(content: str) -> str:
    """Remove MkDocs per-line anchor tags from code blocks."""
    before = len(re.findall(_CODELINENO_RE, content))
    content = _CODELINENO_RE.sub('', content)
    if before:
        print(f"  Stripped {before} __codelineno anchor elements from code blocks")
    return content


# Matches nav-section wrapper elements like:
#   <section class="print-page md-section" ...><h1>Core Concepts</h1></section>
# These are MkDocs nav section labels with no body — they produce blank divider
# pages in the PDF.  We unwrap them (keep their child sections) rather than
# deleting the h1 entirely, so the section name still appears as part of the
# following page.
_MD_SECTION_RE = re.compile(
    r"<section[^>]+\bmd-section\b[^>]*>"
    r"\s*<h1[^>]*>[^<]*(?:<[^>]+>[^<]*)*</h1>\s*"
    r"</section>",
    re.DOTALL | re.IGNORECASE,
)

def strip_nav_section_dividers(content: str) -> str:
    """Remove empty nav-section <section class='md-section'> wrappers."""
    before = len(_MD_SECTION_RE.findall(content))
    content = _MD_SECTION_RE.sub('', content)
    if before:
        print(f"  Stripped {before} empty nav-section divider(s) (md-section)")
    return content


# Matches the hand-written "Table of Contents" section on the index/home page.
# In the PDF this duplicates the injected static ToC; we strip it here while
# leaving the web docs unchanged.
_INLINE_TOC_RE = re.compile(
    r'<h2[^>]+id="index-table-of-contents"[^>]*>.*?(?=</section>)',
    re.DOTALL | re.IGNORECASE,
)

def strip_inline_toc(content: str) -> str:
    """Remove the hand-written ToC section from the index page."""
    content, n = _INLINE_TOC_RE.subn('', content)
    if n:
        print(f"  Stripped inline Table of Contents from index page (duplicates injected ToC)")
    return content


# ---------------------------------------------------------------------------
# Static ToC injection
# ---------------------------------------------------------------------------

# Map from section-id prefix → human-readable group label for ToC grouping.
_TOC_GROUPS = [
    ("index",           None),           # standalone — no group header
    ("getting-started", "Getting Started"),
    ("concepts",        "Core Concepts"),
    ("configuration",   "Configuration"),
    ("security",        "Security"),
    ("routing",         "Routing"),
    ("providers",       "Providers"),
    ("observability",   "Observability"),
    ("features",        "Features"),
    ("api-reference",   "API Reference"),
    ("reference",       "Reference"),
]

_SECTION_H1_RE = re.compile(
    r'<section[^>]+\bid="([^"]+)"[^>]*>.*?'
    r'<h1(?:[^>]+\bid="([^"]*)")?[^>]*>(.*?)</h1>',
    re.DOTALL | re.IGNORECASE,
)


def build_toc_html(content: str) -> str:
    """
    Generate a static ToC <ul> from section headings in *content*.
    Returns the HTML string for the list (without the <h1>Contents</h1>).
    """
    entries = []
    for m in _SECTION_H1_RE.finditer(content):
        sec_id   = m.group(1)
        h1_id    = m.group(2) or sec_id
        title_raw = m.group(3)
        title = re.sub(r'<[^>]+>', '', title_raw).strip()
        title = html_module.unescape(title)
        if sec_id == "print-site-cover-page":
            continue   # skip cover
        entries.append((sec_id, h1_id, title))

    if not entries:
        return ""

    # Group entries by prefix
    groups: dict[str, list] = {prefix: [] for prefix, _ in _TOC_GROUPS}
    for sec_id, h1_id, title in entries:
        matched = False
        for prefix, _label in _TOC_GROUPS:
            if sec_id == prefix or sec_id.startswith(prefix + "-"):
                groups[prefix].append((sec_id, h1_id, title))
                matched = True
                break
        if not matched:
            groups.setdefault("__other__", []).append((sec_id, h1_id, title))

    lines = ['<ul class="print-site-toc">']
    for prefix, label in _TOC_GROUPS:
        items = groups.get(prefix, [])
        if not items:
            continue
        if label is None:
            # Standalone entry (Home)
            for sec_id, h1_id, title in items:
                lines.append(f'  <li><a href="#{sec_id}">{html_module.escape(title)}</a></li>')
        else:
            lines.append(f'  <li><strong>{label}</strong>')
            lines.append('    <ul>')
            for sec_id, h1_id, title in items:
                lines.append(f'      <li><a href="#{sec_id}">{html_module.escape(title)}</a></li>')
            lines.append('    </ul>')
            lines.append('  </li>')
    lines.append('</ul>')
    return "\n".join(lines)


_TOC_NAV_RE = re.compile(
    r'(<nav[^>]+class=["\'][^"\']*print-page-toc-nav[^"\']*["\'][^>]*>)'
    r'(\s*<h1[^>]*class=["\'][^"\']*print-page-toc-title[^"\']*["\'][^>]*>.*?</h1>)\s*'
    r'(</nav>)',
    re.DOTALL | re.IGNORECASE,
)


def inject_toc(content: str) -> str:
    """Replace the empty JS-driven ToC nav with a statically generated one."""
    toc_html = build_toc_html(content)
    if not toc_html:
        print("  Warning: no sections found for ToC — leaving nav empty", file=sys.stderr)
        return content

    def replacer(m: re.Match) -> str:
        return m.group(1) + m.group(2) + "\n" + toc_html + "\n" + m.group(3)

    new_content, n = _TOC_NAV_RE.subn(replacer, content)
    if n:
        print(f"  Injected static ToC with {toc_html.count('<li>')} entries")
    else:
        print("  Warning: ToC nav element not found — ToC not injected", file=sys.stderr)
    return new_content


# Matches <pre class="mermaid"><code>…</code></pre> (entities inside).
def _fo_to_svgtext(match: re.Match) -> str:
    """
    Convert a single <foreignObject> element to a native SVG <text> element.
    WeasyPrint silently drops foreignObject; this preserves all node labels.
    """
    fo_html = match.group(0)

    width_m  = re.search(r'\bwidth="([^"]+)"',  fo_html)
    height_m = re.search(r'\bheight="([^"]+)"', fo_html)
    opening = re.match(r'<foreignObject[^>]*>', fo_html)
    opening_tag = opening.group(0) if opening else ''
    x_m      = re.search(r'\bx="([^"]+)"', opening_tag)
    y_m      = re.search(r'\by="([^"]+)"', opening_tag)

    w = float(width_m.group(1))  if width_m  else 100.0
    h = float(height_m.group(1)) if height_m else 20.0
    x = float(x_m.group(1))      if x_m      else 0.0
    y = float(y_m.group(1))      if y_m      else 0.0

    # Extract inner HTML, decode entities
    inner_m = re.search(r'<foreignObject[^>]*>(.*)</foreignObject>', fo_html, re.DOTALL)
    inner = html_module.unescape(inner_m.group(1)) if inner_m else ""

    # Collect text lines: split each <p> on <br/> BEFORE stripping tags so
    # multi-line labels are not concatenated into a single overflowing line.
    raw_lines: list[str] = []
    for p in re.findall(r'<p[^>]*>(.*?)</p>', inner, re.DOTALL):
        for part in re.split(r'<br\s*/?>', p, flags=re.IGNORECASE):
            clean = re.sub(r'<[^>]+>', '', part).strip()
            if clean:
                raw_lines.append(clean)
    lines = raw_lines
    if not lines:
        raw = re.sub(r'<[^>]+>', ' ', inner)
        lines = [ln.strip() for ln in re.split(r'[\n\r]+', raw) if ln.strip()]
    lines = [ln for ln in lines if ln]
    if not lines:
        return fo_html  # nothing useful — keep original

    # Adaptive font-size: scale down if the widest line exceeds the box width.
    # Trebuchet MS at 14 px ≈ 7.8 px/char; floor at 8 px so text stays legible.
    fs = 14            # px, matches Mermaid default
    _CHAR_PX = 7.8
    if lines and w > 0:
        max_chars = max(len(ln) for ln in lines)
        if max_chars * _CHAR_PX > w:
            fs = max(8, int(fs * w / (max_chars * _CHAR_PX)))
    lh = fs * 1.5      # line height
    cx = x + w / 2
    total_h  = len(lines) * lh
    first_y  = y + h / 2 - total_h / 2 + fs   # baseline of first line

    tspans = []
    for i, line in enumerate(lines):
        esc = (line.replace('&', '&amp;')
                   .replace('<', '&lt;')
                   .replace('>', '&gt;'))
        dy = '0' if i == 0 else f'{lh:.1f}'
        tspans.append(f'<tspan x="{cx:.2f}" dy="{dy}">{esc}</tspan>')

    return (f'<text x="{cx:.2f}" y="{first_y:.2f}" text-anchor="middle" '
            f'font-family="trebuchet ms,verdana,arial,sans-serif" '
            f'font-size="{fs}px" fill="#333">'
            + ''.join(tspans) + '</text>')


_FO_RE = re.compile(r'<foreignObject[^>]*>.*?</foreignObject>', re.DOTALL)

def convert_foreignobject(svg: str) -> str:
    """Replace all foreignObject label elements with native SVG text."""
    before = len(_FO_RE.findall(svg))
    svg = _FO_RE.sub(_fo_to_svgtext, svg)
    remaining = len(_FO_RE.findall(svg))
    if before:
        converted = before - remaining
        note = f" ({remaining} unconverted)" if remaining else ""
        print(f"    Converted {converted}/{before} foreignObject → SVG text{note}")
    return svg


_MERMAID_RE = re.compile(
    r'<pre[^>]+class="[^"]*\bmermaid\b[^"]*"[^>]*>\s*(?:<code[^>]*>)?(.*?)(?:</code>)?\s*</pre>',
    re.DOTALL | re.IGNORECASE,
)

def render_mermaid_diagrams(content: str) -> str:
    """Replace Mermaid code blocks with inline SVG rendered by mmdc."""
    matches = list(_MERMAID_RE.finditer(content))
    if not matches:
        return content

    print(f"  Found {len(matches)} Mermaid diagram(s) — pre-rendering with mmdc …")

    # Write a shared mmdc config: disable htmlLabels so nodes use SVG <text>
    # instead of <foreignObject> where possible (remaining FOs are post-processed).
    import json as _json
    cfg_data = {"flowchart": {"htmlLabels": False, "wrappingWidth": 150},
                "sequence":  {"htmlLabels": False}}
    cfg_tmp = tempfile.NamedTemporaryFile(suffix=".json", mode="w",
                                          delete=False, encoding="utf-8")
    _json.dump(cfg_data, cfg_tmp)
    cfg_tmp.close()
    cfg_path = cfg_tmp.name

    def mmdc_cmd(in_path: str, out_path: str) -> list[str]:
        return ["npx", "--yes", "@mermaid-js/mermaid-cli",
                "-i", in_path, "-o", out_path,
                "-b", "transparent", "-c", cfg_path,
                "--quiet"]

    rendered = 0
    parts: list[str] = []
    last_end = 0

    for m in matches:
        parts.append(content[last_end:m.start()])
        last_end = m.end()

        src = html_module.unescape(m.group(1)).strip()
        # Replace <br/> with newlines so htmlLabels:false produces <text> not <foreignObject>
        src = re.sub(r'<br\s*/?>', '\n', src, flags=re.IGNORECASE)

        with tempfile.NamedTemporaryFile(suffix=".mmd", mode="w",
                                         delete=False, encoding="utf-8") as f:
            f.write(src)
            in_path = f.name
        out_path = in_path.replace(".mmd", ".svg")

        try:
            result = subprocess.run(
                mmdc_cmd(in_path, out_path),
                capture_output=True, text=True, timeout=60,
            )
            if result.returncode == 0 and os.path.exists(out_path):
                with open(out_path, encoding="utf-8") as f:
                    svg = f.read()
                # Strip XML declaration / DOCTYPE — not valid inside HTML body
                svg = re.sub(r'<\?xml[^?]*\?>\s*', '', svg)
                svg = re.sub(r'<!DOCTYPE[^>]*>\s*', '', svg)
                svg = convert_foreignobject(svg)
                parts.append(f'<div class="mermaid-diagram">{svg.strip()}</div>')
                rendered += 1
            else:
                err = (result.stderr or result.stdout or "").strip()[:200]
                print(f"  Warning: mmdc failed for diagram {rendered+1}: {err}",
                      file=sys.stderr)
                parts.append(m.group(0))   # keep original as fallback
        except subprocess.TimeoutExpired:
            print(f"  Warning: mmdc timed out for diagram {rendered+1}",
                  file=sys.stderr)
            parts.append(m.group(0))
        except FileNotFoundError:
            print("  Warning: npx/mmdc not found — Mermaid diagrams will not be rendered.",
                  file=sys.stderr)
            print("  Install with: npm install -g @mermaid-js/mermaid-cli",
                  file=sys.stderr)
            parts.append(m.group(0))
        finally:
            for p in (in_path, out_path):
                try:
                    os.unlink(p)
                except OSError:
                    pass

    parts.append(content[last_end:])
    print(f"  Rendered {rendered}/{len(matches)} Mermaid diagram(s) to SVG")
    try:
        os.unlink(cfg_path)
    except OSError:
        pass
    return "".join(parts)


def inject_version_into_cover(content: str, version: str) -> str:
    """
    Append a Version row to the cover-page table inside #print-site-cover-page.
    Inserts <tr><td>Version</td><td>{version}</td></tr> before the first </table>
    found within the cover section.
    """
    cover_marker = 'id="print-site-cover-page"'
    cover_start = content.find(cover_marker)
    if cover_start == -1:
        print("  Warning: #print-site-cover-page not found — version row not added",
              file=sys.stderr)
        return content

    table_end = content.find("</table>", cover_start)
    if table_end == -1:
        print("  Warning: </table> not found in cover page — version row not added",
              file=sys.stderr)
        return content

    version_row = (
        f'<tr><td>Version</td><td>{html_module.escape(version)}</td></tr>'
    )
    content = content[:table_end] + version_row + content[table_end:]
    print(f"  Injected Version row into cover page table: {version}")
    return content


def build_standalone_html(content: str, css_path: str, base_url: str,
                          version: str = "") -> str:
    """Wrap extracted content in minimal HTML referencing only print.css."""
    version_css = ""
    if version:
        version_css = f"""
  <style>
    /* Version stamp in footer on all pages except the cover */
    @page {{
      @bottom-right {{
        content: "v{version}";
        font-size: 7pt;
        color: #888;
        font-family: system-ui, -apple-system, sans-serif;
      }}
    }}
    @page :first {{
      @bottom-right {{ content: none; }}
    }}
  </style>"""
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="version" content="{version}">
  <title>AI Gateway by Myra Security — Documentation</title>
  <base href="{base_url}">
  <style>
    /* ── Reset ── */
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{ font-family: system-ui, -apple-system, sans-serif; }}
  </style>
  <link rel="stylesheet" href="{css_path}">{version_css}
</head>
<body>
{content}
</body>
</html>"""


# ---------------------------------------------------------------------------
# PDF post-processing — viewer preferences
# ---------------------------------------------------------------------------

def set_open_action(pdf_path: str) -> None:
    """
    Embed viewer preferences so the PDF opens with page 1 fit to window:
      • OpenAction  — /Fit destination on page 1 (zoom-to-fit on open)
      • FitWindow   — ask the viewer to resize its window to the page
      • DisplayDocTitle — show the document title in the title bar
    Requires pikepdf (pip install pikepdf).
    """
    try:
        import pikepdf
    except ImportError:
        print("  (skipping viewer prefs — pip install pikepdf)", file=sys.stderr)
        return

    with pikepdf.open(pdf_path, allow_overwriting_input=True) as pdf:
        pdf.Root.OpenAction = pikepdf.Array([
            pdf.pages[0].obj,
            pikepdf.Name("/Fit"),
        ])
        pdf.Root.ViewerPreferences = pdf.make_indirect(pikepdf.Dictionary(
            FitWindow=pikepdf.Boolean(True),
            DisplayDocTitle=pikepdf.Boolean(True),
        ))
        pdf.save(pdf_path)

    print("✓ Viewer preferences set (fit-to-page on open)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Generate PDF documentation")
    parser.add_argument("--out", default=OUT_PDF, help="Output PDF path")
    args = parser.parse_args()

    # ── Delete previous PDF builds ───────────────────────────────────────────
    old_pdfs = glob.glob(os.path.join(HERE, "out", "ai-gateway-docs-*.pdf"))
    for old in old_pdfs:
        try:
            os.unlink(old)
            print(f"  Deleted old PDF: {os.path.basename(old)}")
        except OSError as e:
            print(f"  Warning: could not delete {old}: {e}", file=sys.stderr)

    # ── Pre-flight checks ────────────────────────────────────────────────────
    try:
        import weasyprint
    except ImportError:
        print("ERROR: weasyprint is not installed.", file=sys.stderr)
        print("       pip install weasyprint", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(IN_HTML):
        print(f"ERROR: print page not found: {IN_HTML}", file=sys.stderr)
        print("       Run docs/gen_docs.sh first.", file=sys.stderr)
        sys.exit(1)

    # ── Extract content ──────────────────────────────────────────────────────
    print(f"→ Source : {IN_HTML}  ({os.path.getsize(IN_HTML) // 1024} KB)")
    with open(IN_HTML, encoding="utf-8") as f:
        raw_html = f.read()

    content = extract_print_section(raw_html)
    print(f"  Content: {len(content) // 1024} KB extracted from #print-site-page")

    # ── Clean up & pre-render ────────────────────────────────────────────────
    print("→ Pre-processing HTML …")
    content = strip_codelineno_anchors(content)
    content = inject_toc(content)
    content = strip_nav_section_dividers(content)
    content = strip_inline_toc(content)
    content = inject_version_into_cover(content, _version)
    content = render_mermaid_diagrams(content)

    # Base URL so WeasyPrint resolves relative image paths (../assets/screenshots/...)
    base_url = "file://" + os.path.join(HERE, "out", "print_page") + os.sep
    css_url  = "file://" + os.path.join(HERE, "out", "stylesheets", "print.css")

    standalone = build_standalone_html(content, css_url, base_url, version=_version)

    # ── Render ───────────────────────────────────────────────────────────────
    print(f"→ Output : {args.out}")
    print("→ Rendering … (this takes 10–30 seconds)")

    t0 = time.monotonic()

    import logging
    logging.getLogger("weasyprint").setLevel(logging.ERROR)

    a4_css = weasyprint.CSS(string="@page { size: A4 portrait; }")

    weasyprint.HTML(string=standalone, base_url=base_url).write_pdf(
        args.out, stylesheets=[a4_css]
    )

    elapsed = time.monotonic() - t0
    size_kb = os.path.getsize(args.out) // 1024
    print(f"✓ Done in {elapsed:.1f}s — {size_kb} KB → {args.out}")

    # ── Set PDF open action (fit first page to window) ───────────────────────
    set_open_action(args.out)


if __name__ == "__main__":
    main()
