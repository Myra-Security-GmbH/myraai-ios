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
import re

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
    return path.split('/')[-1].replace('.md', '').replace('-', ' ').replace('_', ' ').title()

# Parse nav_lines into sections grouped by "# Part N — Name" comments.
#
# Handled patterns (indented with spaces as in mkdocs.yml):
#   "  # Part N — Name"          → start a new topic-map section card
#   "  - Name:"                   → named sub-section; pages added to current Part card
#   "  - Title: file.md"          → top-level single page; added to current Part card
#   "  - file.md"                 → top-level single page (no title); added to current Part card
#   "    - SubName:"              → sub-section header at depth 2; skip
#   "    - Title: file.md"        → child page (depth 2)
#   "    - file.md"               → child page (depth 2, title from file)
#   "      - SubName:"            → sub-section header at depth 3; skip
#   "      - Title: file.md"      → grandchild page (depth 3); flattened into current Part card
#   "      - file.md"             → grandchild page (depth 3, title from file)

sections = []   # [(section_name, [(title, path), ...])]
cur_section = None
cur_pages   = []

def flush():
    if cur_section is not None:
        sections.append((cur_section, list(cur_pages)))

for line in nav_lines:
    # "  # Part N — Name"  →  new section card
    m = re.match(r'^\s+#\s+Part\s+\d+\s+[-\u2014]+\s+(.+)', line)
    if m:
        flush()
        cur_section = m.group(1).strip()
        cur_pages   = []
        continue

    # "  - Name:"  →  top-level named sub-section; don't flush, just continue adding to current Part
    if re.match(r'^  - [^:]+:\s*$', line):
        continue

    # "  - Title: file.md"  →  top-level single page with explicit title
    m = re.match(r'^  - ([^:]+):\s+(\S+\.md)\s*$', line)
    if m and cur_section is not None:
        cur_pages.append((page_title(m.group(2).strip(), m.group(1).strip()), m.group(2).strip()))
        continue

    # "  - file.md"  →  top-level single page, title from file
    m = re.match(r'^  - (\S+\.md)\s*$', line)
    if m and cur_section is not None:
        path = m.group(1).strip()
        cur_pages.append((page_title(path), path))
        continue

    if cur_section is None:
        continue

    # "    - SubName:"  or  "      - SubName:"  →  sub-section header, skip
    if re.match(r'^    - [^:]+:\s*$', line) or re.match(r'^      - [^:]+:\s*$', line):
        continue

    # "    - Title: file.md"  →  child with explicit title (depth 2)
    m = re.match(r'^    - ([^:]+):\s+(\S+\.md)\s*$', line)
    if m:
        cur_pages.append((page_title(m.group(2).strip(), m.group(1).strip()), m.group(2).strip()))
        continue

    # "    - file.md"  →  child without title (depth 2)
    m = re.match(r'^    - (\S+\.md)\s*$', line)
    if m:
        path = m.group(1).strip()
        cur_pages.append((page_title(path), path))
        continue

    # "      - Title: file.md"  →  grandchild with explicit title (depth 3)
    m = re.match(r'^      - ([^:]+):\s+(\S+\.md)\s*$', line)
    if m:
        cur_pages.append((page_title(m.group(2).strip(), m.group(1).strip()), m.group(2).strip()))
        continue

    # "      - file.md"  →  grandchild without title (depth 3)
    m = re.match(r'^      - (\S+\.md)\s*$', line)
    if m:
        path = m.group(1).strip()
        cur_pages.append((page_title(path), path))
        continue

flush()

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
