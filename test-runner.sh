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

# ── Lua syntax check (loadfile via resty/LuaJIT on every src/*.lua) ───────────
run_lua_syntax() {
    local any_fail=0
    while IFS= read -r -d '' f; do
        local name="${f#"$REPO"/}"
        printf '  %-52s ' "$name"
        local err
        # Use resty (LuaJIT) rather than luac: luac is Lua 5.1 and rejects
        # goto statements used throughout the codebase; LuaJIT supports them.
        if err=$(resty -e "local fn,e=loadfile('$f'); if e then io.write(e); os.exit(1) end" 2>&1); then
            green OK
        else
            red FAIL
            echo "$err" | sed 's/^/    /'
            any_fail=1
        fi
    done < <(find "$REPO/src" -name "*.lua" -print0 | sort -z)
    return $any_fail
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
    local lr_path lr_inc
    lr_path="$(luarocks path --lr-path 2>/dev/null)" || true

    if [[ -z "$lr_path" ]]; then
        yellow "luarocks not found — skipping Lua coverage (install luarocks + luacov)"
        return 1
    fi

    # Build resty -I include path from the first luarocks dir (strip the /?.lua suffix).
    lr_inc="${lr_path%%/?.lua*}"

    bold "Running Lua unit tests under resty + luacov …"
    cd "$REPO"
    rm -f luacov.stats.out luacov.report.out

    local files=()
    for f in "$REPO/tests/unit"/test_*.lua; do
        files+=("$f")
    done

    yellow "Running ${#files[@]} unit test files with coverage …"
    local any_fail=0
    if COVERAGE=1 resty -I "$lr_inc" "$REPO/tests/runner.lua" "${files[@]}" 2>&1; then
        :
    else
        any_fail=1
    fi

    if [[ -s luacov.stats.out ]]; then
        LUA_PATH="${lr_path};;" lua5.1 -e "require('luacov.runner').run_report()" 2>/dev/null || true
        if [[ -f luacov.report.out ]]; then
            green "Coverage report → $REPO/luacov.report.out"
            grep -E "\.(lua)\s+[0-9]" luacov.report.out | tail -20 || true
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
    SUITES=(lua-syntax backend frontend playwright)
fi

echo ""
bold "AI Gateway — Test Runner"
echo "Suites: ${SUITES[*]}"
echo ""

for suite in "${SUITES[@]}"; do
    case "$suite" in
        lua-syntax)         run_suite "Lua syntax (luac -p)"          run_lua_syntax ;;
        backend)            run_suite "Backend  (Lua unit)"           run_backend ;;
        backend:coverage)   run_suite "Backend  (Lua coverage)"       run_backend_coverage ;;
        frontend)           run_suite "Frontend (Vitest unit)"         run_frontend ;;
        frontend:coverage)  run_suite "Frontend (Vitest coverage)"     run_frontend_coverage ;;
        playwright)         run_suite "Playwright (e2e)"               run_playwright ;;
        *)          yellow "Unknown suite: $suite"; yellow "  valid: lua-syntax backend backend:coverage frontend frontend:coverage playwright"; exit 1 ;;
    esac
done

# ── summary ───────────────────────────────────────────────────────────────────
bold "═══════════════════════════════════════════════════"
printf '  Suites passed: '; green  "$PASS"
if [[ $FAIL -gt 0 ]]; then
    printf '  Suites failed: '; red "$FAIL"
    exit 1
fi
