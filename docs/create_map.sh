#!/bin/sh
# create_map.sh — generate docs/docs.md/reference/topic-map.md from mkdocs.yml nav

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MKDOCS="$SCRIPT_DIR/mkdocs.yml"
MAPFILE="$SCRIPT_DIR/docs.md/reference/topic-map.md"
DOCSDIR="$SCRIPT_DIR/docs.md"

# ── 1. Add md_in_html extension if missing ──────────────────────────────────
if ! grep -q 'md_in_html' "$MKDOCS"; then
  sed -i 's/^  - tables$/  - tables\n  - md_in_html/' "$MKDOCS"
  echo "Added md_in_html to mkdocs.yml"
fi

# ── 2. Add Topic Map to nav if missing ──────────────────────────────────────
if ! grep -q 'topic-map.md' "$MKDOCS"; then
  sed -i 's|    - reference/glossary.md|    - reference/glossary.md\n    - Topic Map: reference/topic-map.md|' "$MKDOCS"
  echo "Added Topic Map to mkdocs.yml nav"
fi

# ── 3. Build topic-map.md dynamically from mkdocs.yml nav ───────────────────
python3 << PYEOF
import re, sys

mkdocs_file = "$MKDOCS"
docs_dir    = "$DOCSDIR"
out_file    = "$MAPFILE"

with open(mkdocs_file) as f:
    lines = f.read().splitlines()

# Extract the nav: block
in_nav, nav_lines = False, []
for line in lines:
    if line.rstrip() == 'nav:':
        in_nav = True
        continue
    if in_nav:
        if line and not line[0].isspace():
            break
        nav_lines.append(line)

def page_title(path, explicit=None):
    """Return explicit title if given, otherwise read first # heading from file."""
    if explicit:
        return explicit
    try:
        with open(f"{docs_dir}/{path}") as f:
            for line in f:
                m = re.match(r'^#\s+(.+)', line)
                if m:
                    return m.group(1).strip()
    except OSError:
        pass
    # fallback: humanise filename
    return path.split('/')[-1].replace('.md', '').replace('-', ' ').replace('_', ' ').title()

# Parse nav_lines into sections.
# Patterns (after stripping the nav: block):
#   "  - Name:"              top-level section (no file)
#   "  - Title: file.md"     top-level single page  → skip
#   "  - file.md"            top-level single page  → skip
#   "    - file.md"          child page, derive title from file
#   "    - Title: file.md"   child page with explicit title
#   "    - SubName:"         nested sub-section header → skip header, treat children as flat

sections = []   # [(section_name, [(title, path), ...])]
cur_section = None
cur_pages   = []

for line in nav_lines:
    # top-level section with children
    m = re.match(r'^  - ([^:]+):\s*$', line)
    if m:
        if cur_section is not None:
            sections.append((cur_section, cur_pages))
        cur_section = m.group(1).strip()
        cur_pages   = []
        continue

    # top-level single page (skip — not a section card)
    if re.match(r'^  - ', line):
        if cur_section is not None:
            sections.append((cur_section, cur_pages))
        cur_section = None
        cur_pages   = []
        continue

    if cur_section is None:
        continue

    # nested sub-section header (e.g. "    - SubName:") — skip the header line
    if re.match(r'^    - [^:]+:\s*$', line):
        continue

    # child with explicit title: "    - Title: path.md"
    m = re.match(r'^    - ([^:]+):\s+(\S+\.md)\s*$', line)
    if m:
        cur_pages.append((page_title(m.group(2).strip(), m.group(1).strip()), m.group(2).strip()))
        continue

    # child without explicit title: "    - path.md"
    m = re.match(r'^    - (\S+\.md)\s*$', line)
    if m:
        path = m.group(1).strip()
        cur_pages.append((page_title(path), path))
        continue

if cur_section is not None:
    sections.append((cur_section, cur_pages))

# Write topic-map.md
# topic-map.md lives in reference/, so relative links need ../
out = [
    "# Topic Map\n",
    "\n",
    "Browse all documentation topics by category.\n",
    "\n",
    '<div class="grid cards" markdown>\n',
    "\n",
]
for name, pages in sections:
    if not pages:
        continue
    out.append(f"-   **{name}**\n\n    ---\n\n")
    for title, path in pages:
        out.append(f"    - [{title}](../{path})\n")
    out.append("\n")
out.append("</div>\n")

with open(out_file, 'w') as f:
    f.writelines(out)
print(f"Written: {out_file}")
PYEOF

# (build is handled by gen_docs.sh, which calls this script first)
