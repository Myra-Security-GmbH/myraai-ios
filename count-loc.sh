#!/usr/bin/env bash
# count-loc.sh — Lines of code breakdown for AI Gateway
# Counts non-blank, non-comment lines per language group, then doc lines separately.
# Usage: ./count-loc.sh [--verbose]

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

# ── helpers ────────────────────────────────────────────────────────────────────

# Count physical lines (all lines) for a list of files
total_lines() { wc -l "$@" 2>/dev/null | tail -1 | awk '{print $1}'; }

# Count non-blank lines
code_lines() {
    grep -ch '' "$@" 2>/dev/null | awk '{s+=$1} END {print s+0}'
}

# Count non-blank, non-comment lines (Lua: --, shell: #, TS/JS: // /* *)
loc_lua() {
    grep -v '^\s*--' "$@" 2>/dev/null | grep -c '[^[:space:]]' || true
}
loc_ts() {
    grep -v '^\s*//' "$@" 2>/dev/null | grep -v '^\s*/\*' | grep -v '^\s*\*' | grep -c '[^[:space:]]' || true
}
loc_scss() {
    grep -v '^\s*//' "$@" 2>/dev/null | grep -v '^\s*/\*' | grep -v '^\s*\*' | grep -c '[^[:space:]]' || true
}
loc_py() {
    grep -v '^\s*#' "$@" 2>/dev/null | grep -c '[^[:space:]]' || true
}
loc_conf() {
    grep -v '^\s*#' "$@" 2>/dev/null | grep -c '[^[:space:]]' || true
}

# Collect files by pattern, excluding generated/vendor paths
collect() {
    local dir="$1"; shift
    find "$dir" -type f "$@" \
        ! -path '*/node_modules/*' \
        ! -path '*/dist/*' \
        ! -path '*/.git/*' \
        ! -path '*/test-results/*' \
        2>/dev/null | sort
}

# Print a section row
row() { printf "  %-36s %6d lines\n" "$1" "$2"; }

# Print a group total
total_row() { printf "  %-36s %6d lines  ←\n" "$1" "$2"; }

# ── collect file lists ─────────────────────────────────────────────────────────

LUA_SRC=$(collect   "$REPO/src"     -name '*.lua')
LUA_TEST=$(collect  "$REPO/tests"   -name '*.lua')
LUA_CFG=$(          find "$REPO/config" -maxdepth 1 -name '*.lua' 2>/dev/null | sort)

TS_SRC=$(collect    "$REPO/frontend/src" \( -name '*.ts' -o -name '*.tsx' \) ! -name '*.d.ts' ! -name 'setupTests.ts' ! -name 'vite-env.d.ts')
SCSS_SRC=$(collect  "$REPO/frontend/src" -name '*.scss')

PY_SRC=$( { collect "$REPO/config" -name '*.py'; collect "$REPO/tests" -name '*.py'; } | sort )
CONF_SRC=$(         find "$REPO/config" -maxdepth 1 \( -name '*.conf' \) 2>/dev/null | sort)
SQL_SRC=$(collect   "$REPO/src"     -name '*.sql')

DOC_MD=$(collect    "$REPO/docs"    -name '*.md')
ROOT_MD=$(          find "$REPO" -maxdepth 1 -name '*.md' 2>/dev/null | sort)

# ── compute counts ─────────────────────────────────────────────────────────────

# Lua: subdivide by subdirectory within src/
declare -A LUA_BY_DIR
while IFS= read -r f; do
    rel="${f#$REPO/src/}"
    dir="${rel%%/*}"
    LUA_BY_DIR[$dir]=$(( ${LUA_BY_DIR[$dir]:-0} + $(wc -l < "$f") ))
done <<< "$LUA_SRC"

LUA_SRC_TOTAL=0
for d in "${!LUA_BY_DIR[@]}"; do
    LUA_SRC_TOTAL=$(( LUA_SRC_TOTAL + LUA_BY_DIR[$d] ))
done

LUA_TEST_TOTAL=$(echo "$LUA_TEST" | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
LUA_CFG_TOTAL=0
[[ -n "$LUA_CFG" ]] && LUA_CFG_TOTAL=$(echo "$LUA_CFG" | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')

TS_TOTAL=$(echo "$TS_SRC"   | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
SCSS_TOTAL=$(echo "$SCSS_SRC" | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')

PY_TOTAL=0
[[ -n "$PY_SRC" ]]   && PY_TOTAL=$(echo "$PY_SRC"   | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
CONF_TOTAL=0
[[ -n "$CONF_SRC" ]] && CONF_TOTAL=$(echo "$CONF_SRC" | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
SQL_TOTAL=0
[[ -n "$SQL_SRC" ]]  && SQL_TOTAL=$(echo "$SQL_SRC"  | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')

DOC_TOTAL=$(echo "$DOC_MD"  | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
ROOT_MD_TOTAL=0
[[ -n "$ROOT_MD" ]] && ROOT_MD_TOTAL=$(echo "$ROOT_MD" | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')

DOC_FILES=$(echo "$DOC_MD" | grep -c '.' || true)
ROOT_MD_FILES=$(echo "$ROOT_MD" | grep -c '.' 2>/dev/null || true)

# ── file counts ────────────────────────────────────────────────────────────────

LUA_SRC_FILES=$(echo "$LUA_SRC"   | grep -c '.' || true)
LUA_TEST_FILES=$(echo "$LUA_TEST" | grep -c '.' || true)
TS_FILES=$(echo "$TS_SRC"         | grep -c '.' || true)
SCSS_FILES=$(echo "$SCSS_SRC"     | grep -c '.' || true)
PY_FILES=0;   [[ -n "$PY_SRC" ]]   && PY_FILES=$(echo "$PY_SRC"   | grep -c '.' || true)
CONF_FILES=0; [[ -n "$CONF_SRC" ]] && CONF_FILES=$(echo "$CONF_SRC" | grep -c '.' || true)
SQL_FILES=0;  [[ -n "$SQL_SRC" ]]  && SQL_FILES=$(echo "$SQL_SRC"  | grep -c '.' || true)

# ── totals ─────────────────────────────────────────────────────────────────────

SRC_TOTAL=$(( LUA_SRC_TOTAL + LUA_TEST_TOTAL + LUA_CFG_TOTAL + TS_TOTAL + SCSS_TOTAL + PY_TOTAL + CONF_TOTAL + SQL_TOTAL ))
GRAND_TOTAL=$(( SRC_TOTAL + DOC_TOTAL + ROOT_MD_TOTAL ))

# ── output ─────────────────────────────────────────────────────────────────────

echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  AI Gateway — Lines of Code                                 │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""
echo "── Lua source  ($LUA_SRC_FILES files) ─────────────────────────────────"

# Print per-subdirectory breakdown, sorted by line count descending
for dir in $(for d in "${!LUA_BY_DIR[@]}"; do echo "${LUA_BY_DIR[$d]} $d"; done | sort -rn | awk '{print $2}'); do
    row "  src/$dir/" "${LUA_BY_DIR[$dir]}"
done

printf "  %-36s %6d lines  ←\n" "  subtotal" "$LUA_SRC_TOTAL"
echo ""

echo "── Lua tests   ($LUA_TEST_FILES files) ─────────────────────────────────"
row "  tests/" "$LUA_TEST_TOTAL"
echo ""

if [[ $LUA_CFG_TOTAL -gt 0 ]]; then
echo "── Lua config  ──────────────────────────────────────────────────"
row "  config/*.lua" "$LUA_CFG_TOTAL"
echo ""
fi

echo "── Frontend TypeScript/TSX  ($TS_FILES files) ──────────────────────────"
row "  frontend/src/" "$TS_TOTAL"
echo ""

echo "── Frontend SCSS  ($SCSS_FILES files) ──────────────────────────────────"
row "  frontend/src/" "$SCSS_TOTAL"
echo ""

if [[ $SQL_TOTAL -gt 0 ]]; then
echo "── SQL schema  ($SQL_FILES files) ───────────────────────────────────────"
row "  src/storage/" "$SQL_TOTAL"
echo ""
fi

if [[ $CONF_TOTAL -gt 0 || $PY_TOTAL -gt 0 ]]; then
echo "── Config / infra ────────────────────────────────────────────────"
[[ $CONF_TOTAL -gt 0 ]] && row "  config/*.conf (nginx)" "$CONF_TOTAL"
[[ $PY_TOTAL   -gt 0 ]] && row "  Python (config + test scripts)" "$PY_TOTAL"
echo ""
fi

echo "═══════════════════════════════════════════════════════════════"
printf "  %-36s %6d lines\n" "SOURCE CODE TOTAL" "$SRC_TOTAL"
echo ""

echo "── Documentation  ($DOC_FILES files + $ROOT_MD_FILES root md) ─────────────"
row "  docs/docs.md/" "$DOC_TOTAL"
[[ $ROOT_MD_TOTAL -gt 0 ]] && row "  /*.md (root)" "$ROOT_MD_TOTAL"
echo ""
printf "  %-36s %6d lines\n" "DOCS TOTAL" "$(( DOC_TOTAL + ROOT_MD_TOTAL ))"
echo ""

echo "═══════════════════════════════════════════════════════════════"
printf "  %-36s %6d lines\n" "GRAND TOTAL" "$GRAND_TOTAL"
echo ""

# ── verbose: per-file breakdown ────────────────────────────────────────────────

if [[ $VERBOSE -eq 1 ]]; then
    echo ""
    echo "── Verbose: Lua source files ─────────────────────────────────"
    echo "$LUA_SRC" | xargs wc -l 2>/dev/null | sort -rn | grep -v '^ *0 ' | grep -v total | \
        awk -v repo="$REPO/src/" '{sub(repo,"",$2); printf "  %5d  %s\n", $1, $2}'
    echo ""
    echo "── Verbose: TypeScript/TSX files ────────────────────────────"
    echo "$TS_SRC" | xargs wc -l 2>/dev/null | sort -rn | grep -v '^ *0 ' | grep -v total | \
        awk -v repo="$REPO/frontend/src/" '{sub(repo,"",$2); printf "  %5d  %s\n", $1, $2}'
    echo ""
    echo "── Verbose: documentation files ────────────────────────────"
    echo "$DOC_MD" | xargs wc -l 2>/dev/null | sort -rn | grep -v '^ *0 ' | grep -v total | \
        awk -v repo="$REPO/docs/docs.md/" '{sub(repo,"",$2); printf "  %5d  %s\n", $1, $2}'
fi
