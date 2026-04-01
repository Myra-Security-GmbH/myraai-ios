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
# Compact terminal-section rendering
# ---------------------------------------------------------------------------
#
# WeasyPrint 68 does not honour page-break-before:avoid on block elements, so
# wrapping See Also sections in a div (our earlier approach) does not prevent
# them from being pushed onto their own near-blank page.
#
# Instead we convert each trailing section into compact inline form:
#
#   ## API                          →  <div class="terminal-block">
#   <p>…one sentence…</p>               <p class="api-note"><strong>API:</strong> …</p>
#   ## See also                         <p class="see-also-compact">
#   - Link1                               <strong>See also:</strong> Link1 · Link2
#   - Link2                             </p>
#                                     </div>
#
# The entire block is ~8–14 mm tall vs the original 35–50 mm, so it fits in
# the remaining whitespace on the preceding page.  page-break-inside:avoid on
# the wrapper ensures the block is never split across pages.

_LI_RE = re.compile(r'<li[^>]*>(.*?)</li>', re.DOTALL)

def _ul_to_inline(ul_html: str) -> str:
    """Convert <ul>…</ul> items to "item1 · item2 · item3" inline HTML."""
    items = [m.group(1).strip() for m in _LI_RE.finditer(ul_html)]
    return ' &nbsp;·&nbsp; '.join(items)


# Matches an optional short API h2+p, then the See Also / Next steps h2+ul.
# Group 1: API h2 tag (with id)
# Group 2: API paragraph text (content inside <p>…</p>)
# Group 3: See Also h2 tag (with id, any case of "also"; or "Next steps")
# Group 4: See Also ul inner HTML
_TERMINAL_RE = re.compile(
    r'(?:'
    r'(?P<api_h2><h2[^>]*>API</h2>)\s*'
    r'<p>(?P<api_body>.*?)</p>\s*'
    r')?'
    r'(?P<sa_h2><h2[^>]*>(?:See [Aa]lso|Next steps|Siehe auch)</h2>)\s*'
    r'<ul>(?P<sa_ul>.*?)</ul>',
    re.DOTALL,
)


def compact_terminal_sections(content: str) -> str:
    """
    Convert trailing See Also (and optional API) sections to compact inline form.

    The compact block uses ~8–14 mm of vertical space instead of ~35–50 mm,
    dramatically increasing the chance that it stays on the preceding page.
    """
    n_sa = 0
    n_api = 0

    def _replace(m: re.Match) -> str:
        nonlocal n_sa, n_api
        n_sa += 1

        parts: list[str] = []

        api_body = m.group('api_body')
        if api_body:
            n_api += 1
            parts.append(
                f'<p class="api-note"><strong>API:</strong> {api_body.strip()}</p>'
            )

        # Extract the heading text to use as the compact label
        sa_h2_html = m.group('sa_h2')
        label_m = re.search(r'>([^<]+)</h2>', sa_h2_html)
        label = label_m.group(1).strip() if label_m else 'See also'

        inline_links = _ul_to_inline(m.group('sa_ul'))
        parts.append(
            f'<p class="see-also-compact">'
            f'<strong>{label}:</strong> {inline_links}'
            f'</p>'
        )

        return (
            '<div class="terminal-block">'
            + ''.join(parts)
            + '</div>'
        )

    content = _TERMINAL_RE.sub(_replace, content)
    if n_sa:
        print(f"  Compacted {n_sa} See Also section(s) to inline ({n_api} with API note)")
    return content


# ---------------------------------------------------------------------------
# Small-table marking
# ---------------------------------------------------------------------------

# Tables with few rows risk orphaning a single row on a blank page.
# We mark tables with ≤ _SMALL_TABLE_MAX_ROWS as class="small-table" so CSS
# can apply page-break-inside:avoid to them.
_SMALL_TABLE_MAX_ROWS = 8
_TABLE_BLOCK_RE = re.compile(r'<table>(.*?)</table>', re.DOTALL | re.IGNORECASE)

def mark_small_tables(content: str) -> str:
    """Add class="small-table" to table elements with ≤ _SMALL_TABLE_MAX_ROWS rows."""
    count = 0

    def _repl(m: re.Match) -> str:
        nonlocal count
        rows = m.group(0).count('<tr')
        if rows <= _SMALL_TABLE_MAX_ROWS:
            count += 1
            return '<table class="small-table">' + m.group(1) + '</table>'
        return m.group(0)

    content = _TABLE_BLOCK_RE.sub(_repl, content)
    if count:
        print(f"  Marked {count} small table(s) with page-break-inside:avoid")
    return content


# ---------------------------------------------------------------------------
# Static ToC injection — dynamic group loading from mkdocs.yml
# ---------------------------------------------------------------------------
#
# _TOC_GROUPS used to be a hardcoded list.  It is now derived at render time
# from the mkdocs.yml nav so that adding, renaming, or reordering nav sections
# automatically flows through to the PDF Table of Contents without any changes
# to this file.
#
# Each nav entry is mapped to a (key, label) tuple:
#   • Standalone page ("Label: file.md")  → key = exact section slug, label = None
#   • Group          ("Label: [...]")     → key = directory prefix of every file
#                                            in the group (recursively), label = group name
#
# The section slug for a file path is:  path/to/file.md → path-to-file
# The directory prefix for a file path: path/to/file.md → path  (first segment)
#
# Matching in build_toc_html:
#   sec_id == key            → exact match   (standalone pages)
#   sec_id.startswith(key+"-") → prefix match (grouped pages)
#
# Consecutive toc_groups entries that share the same label are merged into a
# single ToC block so "admin-ui" + "observability" → one "Views" section.

_MKDOCS_YML = os.path.join(HERE, "mkdocs.yml")


def _nav_path_to_slug(path: str) -> str:
    """Convert a nav file path to the MkDocs print-plugin section slug."""
    path = path.replace("\\", "/").rstrip("/")
    if path in ("README.md", "index.md", "README.html", "index.html"):
        return "index"
    path = re.sub(r"\.(md|html)$", "", path, flags=re.IGNORECASE)
    return path.replace("/", "-")


def _nav_path_to_dir_prefix(path: str) -> str:
    """Return the first path segment (directory) of a nav file path."""
    path = path.replace("\\", "/").rstrip("/")
    if path in ("README.md", "index.md"):
        return "index"
    segments = path.split("/")
    if len(segments) == 1:
        return re.sub(r"\.(md|html)$", "", segments[0], flags=re.IGNORECASE)
    return segments[0]


def _collect_nav_prefixes(items: list) -> list[str]:
    """Recursively collect unique directory prefixes from a nav item list."""
    prefixes: list[str] = []
    seen: set[str] = set()

    def _visit(node) -> None:
        if isinstance(node, str):
            p = _nav_path_to_dir_prefix(node)
            if p not in seen:
                seen.add(p)
                prefixes.append(p)
        elif isinstance(node, dict):
            for _key, val in node.items():
                if isinstance(val, str):
                    p = _nav_path_to_dir_prefix(val)
                    if p not in seen:
                        seen.add(p)
                        prefixes.append(p)
                elif isinstance(val, list):
                    for child in val:
                        _visit(child)
        elif isinstance(node, list):
            for child in node:
                _visit(child)

    for item in items:
        _visit(item)
    return prefixes


def _load_toc_groups() -> list[tuple[str, str | None]]:
    """
    Build the ToC groups list from mkdocs.yml nav at render time.

    Returns a list of (key, label) tuples in nav order.  key is either an
    exact section slug (for standalone pages) or a directory prefix (for
    grouped pages).  label is the nav group name, or None for standalone pages.
    """
    try:
        import yaml
    except ImportError:
        print("  Warning: PyYAML not installed — ToC will have no group headers",
              file=sys.stderr)
        return []

    if not os.path.exists(_MKDOCS_YML):
        print(f"  Warning: {_MKDOCS_YML} not found — ToC will have no group headers",
              file=sys.stderr)
        return []

    # mkdocs.yml may contain !!python/name: tags (e.g. for pymdownx superfences)
    # that yaml.safe_load rejects.  We only need the 'nav' key, so we load with
    # a permissive loader that returns None for any unrecognised Python tag.
    class _NavLoader(yaml.SafeLoader):
        pass
    _NavLoader.add_multi_constructor(
        "tag:yaml.org,2002:python/",
        lambda loader, tag_suffix, node: None,
    )

    with open(_MKDOCS_YML, encoding="utf-8") as f:
        config = yaml.load(f, Loader=_NavLoader)

    nav = config.get("nav", [])
    groups: list[tuple[str, str | None]] = []

    for item in nav:
        if isinstance(item, str):
            # Bare file path at top level (unusual)
            groups.append((_nav_path_to_slug(item), None))
        elif isinstance(item, dict):
            for label, children in item.items():
                if isinstance(children, str):
                    # Standalone page: "Side map: reference/site-map.md"
                    # Use exact slug so it doesn't collide with prefix-matched
                    # sections that share the same directory (e.g. reference/).
                    groups.append((_nav_path_to_slug(children), None))
                elif isinstance(children, list):
                    # Group: "Getting started: [...]"
                    # Every unique directory prefix under this group maps to
                    # the group label.
                    for prefix in _collect_nav_prefixes(children):
                        groups.append((prefix, label))

    return groups


_SECTION_H1_RE = re.compile(
    r'<section[^>]+\bid="([^"]+)"[^>]*>.*?'
    r'<h1(?:[^>]+\bid="([^"]*)")?[^>]*>(.*?)</h1>',
    re.DOTALL | re.IGNORECASE,
)


def build_toc_html(content: str) -> str:
    """
    Generate a static ToC <ul> from section headings in *content*.
    Groups are derived dynamically from mkdocs.yml.
    Consecutive entries that share the same group label are merged into a
    single <li> block so that e.g. admin-ui + observability → one "Views" entry.
    Returns the HTML string for the list (without the <h1>Contents</h1>).
    """
    toc_groups = _load_toc_groups()

    # Collect all sections from the rendered HTML
    entries = []
    for m in _SECTION_H1_RE.finditer(content):
        sec_id    = m.group(1)
        h1_id     = m.group(2) or sec_id
        title_raw = m.group(3)
        title = re.sub(r"<[^>]+>", "", title_raw).strip()
        title = html_module.unescape(title)
        if sec_id == "print-site-cover-page":
            continue
        entries.append((sec_id, h1_id, title))

    if not entries:
        return ""

    # Map each section to the first matching key in toc_groups
    key_to_items: dict[str, list] = {key: [] for key, _ in toc_groups}
    for sec_id, h1_id, title in entries:
        matched = False
        for key, _label in toc_groups:
            if sec_id == key or sec_id.startswith(key + "-"):
                key_to_items[key].append((sec_id, h1_id, title))
                matched = True
                break
        if not matched:
            key_to_items.setdefault("__other__", []).append((sec_id, h1_id, title))

    # Render — merge consecutive entries with the same label into one block
    lines = ['<ul class="print-site-toc">']
    current_label: str | None = "__unset__"

    def _close_group() -> None:
        if current_label not in (None, "__unset__"):
            lines.append("    </ul>")
            lines.append("  </li>")

    for key, label in toc_groups:
        items = key_to_items.get(key, [])
        if not items:
            continue

        if label is None:
            # Standalone entry — close any open group first
            _close_group()
            current_label = None
            for sec_id, h1_id, title in items:
                lines.append(
                    f'  <li><a href="#{sec_id}">{html_module.escape(title)}</a></li>'
                )
        else:
            if label != current_label:
                # New group — close previous, open this one
                _close_group()
                lines.append(f'  <li><strong>{html_module.escape(label)}</strong>')
                lines.append("    <ul>")
                current_label = label
            # Append entries into the currently open group
            for sec_id, h1_id, title in items:
                lines.append(
                    f'      <li><a href="#{sec_id}">{html_module.escape(title)}</a></li>'
                )

    _close_group()
    lines.append("</ul>")
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


# ---------------------------------------------------------------------------
# Missing-image stripping
# ---------------------------------------------------------------------------
#
# Screenshot placeholder images are referenced in the source markdown but the
# actual PNG files do not exist yet.  WeasyPrint cannot load them and renders
# each missing image as an empty box that still consumes the CSS margin/border
# space defined for img elements.  On short sections this produces near-blank
# or completely blank PDF pages.
#
# We strip every <img> whose resolved src path does not exist on disk before
# passing the HTML to WeasyPrint.  The site_dir parameter should be the
# directory that WeasyPrint uses as its base URL (docs/out/print_page/).

_IMG_TAG_RE = re.compile(r"<img[^>]+>", re.IGNORECASE)
_IMG_SRC_RE = re.compile(r'\bsrc=["\']([^"\']+)["\']', re.IGNORECASE)


def strip_missing_images(content: str, site_dir: str) -> str:
    """
    Remove <img> tags whose src file is not present on disk.

    Only local file paths are checked; data: URIs and http(s): URLs are
    left untouched.  Paths are resolved relative to *site_dir* (the
    WeasyPrint base-URL directory).
    """
    removed = 0

    def _check(m: re.Match) -> str:
        nonlocal removed
        tag = m.group(0)
        src_m = _IMG_SRC_RE.search(tag)
        if not src_m:
            return tag
        src = src_m.group(1)
        if src.startswith(("data:", "http:", "https:", "//")):
            return tag
        resolved = os.path.normpath(os.path.join(site_dir, src))
        if not os.path.exists(resolved):
            removed += 1
            return ""
        return tag

    result = _IMG_TAG_RE.sub(_check, content)
    if removed:
        print(f"  Stripped {removed} missing image(s) from content")
    return result


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
# Two-pass orphan detection — remove terminal blocks that land on blank pages
# ---------------------------------------------------------------------------
# WeasyPrint 68 does not honour page-break-before:avoid, so compact terminal
# blocks sometimes end up alone on a near-blank page.  We detect this after a
# first-pass render and remove the orphaned divs before the final render.
# ---------------------------------------------------------------------------

_TERMINAL_PREFIXES = ('See also:', 'See Also:', 'Next steps:', 'Siehe auch:', 'API:')
_SKIP_PDF_LINES    = frozenset({'AI Gateway by Myra Security', 'Documentation'})


def _detect_orphaned_terminal_blocks(pdf_path: str,
                                     threshold: float = 2.0) -> list[str]:
    """
    Scan *pdf_path* for near-blank pages (< threshold % pixel fill) that
    contain an orphaned compact terminal block (See-also / API-note div).

    Returns a list of normalised text snippets — one per orphaned block —
    that _remove_terminal_blocks_by_snippets() can use to locate the divs.
    """
    try:
        import fitz                       # PyMuPDF
        from PIL import Image
        import io
        import numpy as np
    except ImportError:
        print("  (skipping orphan detection — pip install pymupdf pillow numpy)",
              file=sys.stderr)
        return []

    doc    = fitz.open(pdf_path)
    found: list[str] = []

    for pg in doc:
        # ── Quick fill check ─────────────────────────────────────────────
        mat = fitz.Matrix(0.5, 0.5)
        pix = pg.get_pixmap(matrix=mat, colorspace=fitz.csGRAY)
        img = Image.open(io.BytesIO(pix.tobytes('png'))).convert('L')
        arr = np.array(img)
        pct = (arr < 240).sum() / arr.size * 100
        if pct >= threshold:
            continue

        # ── Near-blank page: extract meaningful lines ─────────────────────
        lines = []
        for raw in pg.get_text().split('\n'):
            s = raw.strip()
            if not s:
                continue
            if s in _SKIP_PDF_LINES:
                continue
            if re.match(r'^v\d{8}', s):       # version stamp
                continue
            if re.match(r'^\d{1,5}$', s):     # page number
                continue
            lines.append(s)

        if not lines:
            continue

        # Only act on pages whose first content line starts with a known
        # terminal-block prefix — regular content paragraphs are left alone.
        if any(lines[0].startswith(p) for p in _TERMINAL_PREFIXES):
            snippet = ' '.join(lines[:3])   # use up to 3 lines for a distinctive key
            # Normalise non-breaking spaces and middle dots
            snippet = snippet.replace('\xa0', ' ').replace('\u00b7', '·')
            found.append(snippet)

    return found


def _remove_terminal_blocks_by_snippets(content: str,
                                        snippets: list[str]) -> tuple[str, int]:
    """
    Remove every <div class="terminal-block">…</div> whose stripped plain-text
    starts with one of the supplied *snippets*.

    Returns (modified_content, n_removed).
    """
    _OPEN  = '<div class="terminal-block">'
    _CLOSE = '</div>'
    n_removed = 0

    for snippet in snippets:
        key = re.sub(r'\s+', ' ',
                     snippet.replace('\xa0', ' ')).strip()[:80]
        if not key:
            continue

        start = 0
        while True:
            tb_start = content.find(_OPEN, start)
            if tb_start == -1:
                break

            # terminal-block divs contain only <p> elements — no nested <div>
            tb_end_pos = content.find(_CLOSE, tb_start)
            if tb_end_pos == -1:
                break
            tb_end = tb_end_pos + len(_CLOSE)
            block_html = content[tb_start:tb_end]

            # Strip tags and normalise for comparison
            block_text = re.sub(r'<[^>]+>', '',
                                html_module.unescape(block_html))
            block_text = block_text.replace('\xa0', ' ').replace('\u00b7', '·')
            block_norm = re.sub(r'\s+', ' ', block_text).strip()

            if key[:60] and (block_norm.startswith(key[:60])
                             or key[:60] in block_norm[:90]):
                # Also remove the <hr /> separator immediately before the
                # terminal block — it's the markdown --- divider before
                # "## See also" and creates a trailing orphan without the block.
                remove_from = tb_start
                for hr_pat in ('<hr />', '<hr/>', '<hr>'):
                    hr_pos = content.rfind(hr_pat, max(0, tb_start - 80), tb_start)
                    if hr_pos != -1:
                        between = content[hr_pos + len(hr_pat):tb_start]
                        if not between.strip():   # only whitespace between hr and block
                            remove_from = hr_pos
                            break

                content = content[:remove_from] + content[tb_end:]
                n_removed += 1
                break          # move on to next snippet

            start = tb_end

    return content, n_removed


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
    content = strip_missing_images(content, os.path.join(HERE, "out", "print_page"))
    content = inject_toc(content)
    content = strip_nav_section_dividers(content)
    content = strip_inline_toc(content)
    content = compact_terminal_sections(content)
    content = mark_small_tables(content)
    content = inject_version_into_cover(content, _version)
    content = render_mermaid_diagrams(content)

    # Base URL so WeasyPrint resolves relative image paths (../assets/screenshots/...)
    base_url = "file://" + os.path.join(HERE, "out", "print_page") + os.sep
    css_url  = "file://" + os.path.join(HERE, "out", "stylesheets", "print.css")

    standalone = build_standalone_html(content, css_url, base_url, version=_version)

    # ── Render (iterative orphan removal, then final render) ─────────────────
    # WeasyPrint 68 does not honour page-break-before:avoid, so compact
    # terminal blocks can land on their own blank page.  We detect them
    # after a detection pass and remove them before the final render.
    # Removing blocks may shift page boundaries, creating new orphans, so we
    # iterate until stable (usually 2–3 passes).
    import logging
    logging.getLogger("weasyprint").setLevel(logging.ERROR)
    a4_css = weasyprint.CSS(string="@page { size: A4 portrait; }")

    t0              = time.monotonic()
    pass_num        = 0
    total_removed   = 0
    max_passes      = 8   # safety limit against pathological layouts

    while pass_num < max_passes:
        pass_num += 1
        tmp_pdf = args.out + f".detect_p{pass_num}.tmp"
        print(f"→ Detection pass {pass_num} …")
        weasyprint.HTML(string=standalone, base_url=base_url).write_pdf(
            tmp_pdf, stylesheets=[a4_css]
        )
        t_pass = time.monotonic() - t0
        print(f"  Pass {pass_num} done in {t_pass:.1f}s")

        orphan_snippets = _detect_orphaned_terminal_blocks(tmp_pdf)
        try:
            os.unlink(tmp_pdf)
        except OSError:
            pass

        if not orphan_snippets:
            print(f"  No orphaned terminal blocks — stable after {pass_num} pass(es)")
            break

        content, n_removed = _remove_terminal_blocks_by_snippets(
            content, orphan_snippets
        )
        total_removed += n_removed
        print(f"  Removed {n_removed}/{len(orphan_snippets)} orphaned "
              f"terminal block(s) (total: {total_removed})")
        if n_removed == 0:
            # Snippets detected but none matched — accept as irreducible
            print("  No HTML matches for detected orphans — accepting as irreducible")
            break
        standalone = build_standalone_html(
            content, css_url, base_url, version=_version
        )

    # ── Final render ─────────────────────────────────────────────────────────
    print(f"→ Final render → {args.out}")
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
