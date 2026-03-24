#!/usr/bin/env bash
# test-runner.sh — run backend unit, frontend unit, and/or Playwright e2e tests
#
# Usage:
#   ./test-runner.sh                       # all suites (no coverage)
#   ./test-runner.sh backend               # Lua unit tests only
#   ./test-runner.sh backend:coverage      # Lua unit tests + luacov report
#   ./test-runner.sh frontend              # Vitest unit tests only
#   ./test-runner.sh frontend:coverage     # Vitest unit tests + v8 coverage report
#   ./test-runner.sh backend frontend      # multiple suites
#   ./test-runner.sh playwright            # Playwright e2e only

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0

# ── colour helpers ─────────────────────────────────────────────────────────────
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

run_suite() {
    local name="$1"; shift
    bold "── $name ──────────────────────────────────────────────"
    if "$@"; then
        green "PASS: $name"
        PASS=$(( PASS + 1 ))
    else
        red   "FAIL: $name"
        FAIL=$(( FAIL + 1 ))
    fi
    echo ""
}

# ── backend: Lua unit tests via resty ─────────────────────────────────────────
run_backend() {
    local unit_dir="$REPO/tests/unit"
    local any_fail=0
    for f in "$unit_dir"/test_*.lua; do
        local name
        name="$(basename "$f" .lua)"
        printf '  %-42s ' "$name"
        if resty "$REPO/tests/runner.lua" "$f" 2>&1 | tail -1 | grep -q 'passed'; then
            green OK
        else
            red FAIL
            resty "$REPO/tests/runner.lua" "$f" 2>&1 | grep -v '^$' | sed 's/^/    /'
            any_fail=1
        fi
    done
    return $any_fail
}

# ── backend: Lua unit tests with luacov coverage ──────────────────────────────
run_backend_coverage() {
    local lr_path
    lr_path="$(luarocks path --lr-path 2>/dev/null)" || true

    if [[ -z "$lr_path" ]]; then
        yellow "luarocks not found — skipping Lua coverage (install luarocks + luacov)"
        return 1
    fi

    bold "Running Lua tests under lua5.1 + luacov …"
    cd "$REPO"
    rm -f luacov.stats.out luacov.report.out

    # Only include test files that run under plain lua5.1 (no OpenResty C extensions
    # like cjson.safe or resty.sha256). Tag a file as coverage-eligible by adding
    # the comment "-- lua5.1-compatible" on any line near the top.
    local files=()
    for f in "$REPO/tests/unit"/test_*.lua; do
        if head -5 "$f" | grep -q "lua5.1-compatible"; then
            files+=("$f")
        fi
    done

    if [[ ${#files[@]} -eq 0 ]]; then
        yellow "No lua5.1-compatible test files found."
        yellow "Add '-- lua5.1-compatible' in the first 5 lines of eligible test files."
        return 1
    fi

    yellow "Coverage files: ${files[*]##*/}"
    local any_fail=0
    if COVERAGE=1 LUA_PATH="${lr_path};;" lua5.1 "$REPO/tests/runner.lua" "${files[@]}" 2>&1; then
        :
    else
        any_fail=1
    fi

    if [[ -s luacov.stats.out ]]; then
        local luacov_bin
        luacov_bin="$(luarocks which luacov 2>/dev/null | head -1)" || true
        [[ -z "$luacov_bin" ]] && luacov_bin="$(luarocks path --lr-bin 2>/dev/null)/luacov" || true
        if [[ -n "$luacov_bin" && -x "$luacov_bin" ]]; then
            "$luacov_bin" 2>/dev/null || true
        else
            lua5.1 -e "require('luacov.reporter').report()" 2>/dev/null || true
        fi
        if [[ -f luacov.report.out ]]; then
            green "Coverage report → $REPO/luacov.report.out"
            grep -E "^src/" luacov.report.out | head -40 || true
        fi
    else
        yellow "No coverage stats written (luacov.stats.out is empty)"
    fi
    return $any_fail
}

# ── frontend: Vitest unit tests ────────────────────────────────────────────────
run_frontend() {
    cd "$REPO/frontend"
    npm test -- --reporter=verbose 2>&1
}

run_frontend_coverage() {
    cd "$REPO/frontend"
    bold "Running TypeScript tests under Vitest + v8 coverage …"
    npm run test:coverage -- --reporter=verbose 2>&1
    if [[ -d coverage ]]; then
        green "HTML report → $REPO/frontend/coverage/index.html"
    fi
}

# ── playwright: e2e tests ──────────────────────────────────────────────────────
run_playwright() {
    cd "$REPO/frontend"
    local filter="${PLAYWRIGHT_FILTER:-}"
    if [[ -n "$filter" ]]; then
        npx playwright test --grep "$filter" 2>&1
    else
        npx playwright test 2>&1
    fi
}

# ── suite selection ────────────────────────────────────────────────────────────
SUITES=("$@")
if [[ ${#SUITES[@]} -eq 0 ]]; then
    SUITES=(backend frontend playwright)
fi

echo ""
bold "AI Gateway — Test Runner"
echo "Suites: ${SUITES[*]}"
echo ""

for suite in "${SUITES[@]}"; do
    case "$suite" in
        backend)            run_suite "Backend  (Lua unit)"           run_backend ;;
        backend:coverage)   run_suite "Backend  (Lua coverage)"       run_backend_coverage ;;
        frontend)           run_suite "Frontend (Vitest unit)"         run_frontend ;;
        frontend:coverage)  run_suite "Frontend (Vitest coverage)"     run_frontend_coverage ;;
        playwright)         run_suite "Playwright (e2e)"               run_playwright ;;
        *)          yellow "Unknown suite: $suite"; yellow "  valid: backend backend:coverage frontend frontend:coverage playwright"; exit 1 ;;
    esac
done

# ── summary ───────────────────────────────────────────────────────────────────
bold "═══════════════════════════════════════════════════"
printf '  Suites passed: '; green  "$PASS"
if [[ $FAIL -gt 0 ]]; then
    printf '  Suites failed: '; red "$FAIL"
    exit 1
fi
