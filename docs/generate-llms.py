#!/usr/bin/env python3
"""
Generate llms.txt from docs.md/ following the llms.txt specification.
https://llmstxt.org/

The output is written to the site_dir (out/) directory.
Pass --full to also write out/llms-full.txt with complete page content.

Usage:
    python3 generate-llms.py [--full]

Requires PyYAML:
    pip install pyyaml   or   uv add pyyaml
"""

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("Error: PyYAML is required.  pip install pyyaml", file=sys.stderr)
    sys.exit(1)

# Base URL for the published docs site (no trailing slash).
DOCS_BASE_URL = "https://docs.ai-gateway.dev"


# ---------------------------------------------------------------------------
# Markdown helpers
# ---------------------------------------------------------------------------

def extract_title(text: str) -> str:
    """Return the first H1 heading, or empty string."""
    for line in text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return ""


def extract_description(text: str) -> str:
    """Return the first plain paragraph (≤120 chars), stripping markdown."""
    in_code = False
    buf: list[str] = []

    for line in text.splitlines():
        if line.startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        if line.startswith("#") or line.startswith("|") or line.startswith("!"):
            if buf:
                break
            continue
        if line.startswith(">"):
            stripped = line.lstrip("> ").strip()
            if stripped:
                buf.append(stripped)
                break
            continue
        if line.strip():
            buf.append(line.strip())
        else:
            if buf:
                break

    desc = " ".join(buf)
    desc = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', desc)
    desc = re.sub(r'\*{1,2}([^*]+)\*{1,2}', r'\1', desc)
    desc = re.sub(r'`([^`]+)`', r'\1', desc)
    desc = re.sub(r'\s+', ' ', desc).strip()
    if len(desc) > 120:
        desc = desc[:117].rstrip() + "..."
    return desc


def page_url(rel_path: str) -> str:
    """Convert a relative .md path to a docs URL."""
    url = rel_path.replace("\\", "/")
    if url == "README.md":
        return DOCS_BASE_URL + "/"
    url = re.sub(r'\.md$', '/', url)
    return DOCS_BASE_URL + "/" + url


# ---------------------------------------------------------------------------
# Nav walker
# ---------------------------------------------------------------------------

def walk_nav(items: list, docs_dir: Path, top_section: str = "") -> list[tuple[str, str, Path]]:
    """
    Recursively walk a mkdocs nav list and yield (section, title, md_path).

    The section is always the *top-level* section name so that all nested
    pages group together under one heading in llms.txt.
    """
    pages = []
    for item in items:
        if isinstance(item, str):
            if item.startswith("http"):
                continue
            md_path = docs_dir / item
            pages.append((top_section, None, md_path))
        elif isinstance(item, dict):
            for key, value in item.items():
                if isinstance(value, str):
                    if value.startswith("http"):
                        continue
                    md_path = docs_dir / value
                    pages.append((top_section, key, md_path))
                elif isinstance(value, list):
                    effective_section = key if not top_section else top_section
                    pages.extend(walk_nav(value, docs_dir, effective_section))
    return pages


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    generate_full = "--full" in sys.argv

    script_dir = Path(__file__).parent
    output_dir = script_dir / "out"
    mkdocs_path = script_dir / "mkdocs.yml"
    if not mkdocs_path.exists():
        print(f"Error: mkdocs.yml not found at {mkdocs_path}", file=sys.stderr)
        sys.exit(1)

    config = yaml.safe_load(mkdocs_path.read_text(encoding="utf-8"))
    site_name = config.get("site_name", "Documentation")
    site_description = config.get("site_description", "")
    docs_dir = script_dir / config.get("docs_dir", "docs")
    nav = config.get("nav", [])

    pages = walk_nav(nav, docs_dir)

    # ----- llms.txt -----
    lines: list[str] = []
    lines.append(f"# {site_name}")
    lines.append("")
    if site_description:
        lines.append(f"> {site_description}")
        lines.append("")

    current_section = object()  # sentinel
    for section, title, md_path in pages:
        if not md_path.exists():
            continue
        content = md_path.read_text(encoding="utf-8", errors="replace")
        page_title = title or extract_title(content) or md_path.stem
        description = extract_description(content)
        url = page_url(md_path.relative_to(docs_dir).as_posix())

        if section != current_section:
            if current_section is not object():
                lines.append("")
            if section:
                lines.append(f"## {section}")
                lines.append("")
            current_section = section

        entry = f"- [{page_title}]({url})"
        if description:
            entry += f": {description}"
        lines.append(entry)

    lines.append("")

    output_dir.mkdir(parents=True, exist_ok=True)
    out_path = output_dir / "llms.txt"
    out_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"Written {out_path}  ({len(pages)} pages)")

    # ----- llms-full.txt -----
    if generate_full:
        full_lines: list[str] = []
        for section, title, md_path in pages:
            if not md_path.exists():
                continue
            content = md_path.read_text(encoding="utf-8", errors="replace")
            page_title = title or extract_title(content) or md_path.stem
            rel = md_path.relative_to(docs_dir).as_posix()
            full_lines.append(f"<!-- {page_title} — {rel} -->")
            full_lines.append(content.strip())
            full_lines.append("\n---\n")

        full_path = output_dir / "llms-full.txt"
        full_path.write_text("\n".join(full_lines), encoding="utf-8")
        print(f"Written {full_path}")


if __name__ == "__main__":
    main()
