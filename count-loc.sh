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

TS_SRC=$(collect    "$REPO/frontend/src" \( -name '*.ts' -o -name '*.tsx' \) ! -name '*.d.ts' ! -name 'setupTests.ts' ! -name 'vite-env.d.ts' ! -name '*.test.ts' ! -name '*.test.tsx')
TS_UNIT_TEST=$(collect "$REPO/frontend/src" \( -name '*.test.ts' -o -name '*.test.tsx' \))
TS_E2E_TEST=$(collect  "$REPO/frontend/tests" \( -name '*.spec.ts' -o -name '*.test.ts' \))
SCSS_SRC=$(collect  "$REPO/frontend/src" -name '*.scss')

PY_SRC=$( { collect "$REPO/config" -name '*.py'; collect "$REPO/tests" -name '*.py'; } | sort )
PY_SVC=$(collect    "$REPO/src"     -name '*.py')
CONF_SRC=$(         find "$REPO/config" -maxdepth 1 \( -name '*.conf' \) 2>/dev/null | sort)
SQL_SRC=$(collect   "$REPO/src"     -name '*.sql')

# Mobile — iOS
SWIFT_APP=$(collect "$REPO/src/mobile/ios/MYRAai/Sources" -name '*.swift')
SWIFT_TEST=$(collect "$REPO/src/mobile/ios/MYRAai/Tests"  -name '*.swift')
IOS_RES=$( { find "$REPO/src/mobile/ios" -maxdepth 6 -type f \
    \( -name 'Info.plist' -o -name '*.entitlements' \
       -o -name 'project.pbxproj' -o -name '*.xcscheme' \
       -o -name 'codemagic.yaml' \) 2>/dev/null; } | sort )

# Mobile — Android
KOTLIN_SRC=$(collect "$REPO/src/mobile/android/app/src/main" \( -name '*.kt' -o -name '*.java' \))
ANDROID_XML=$(collect "$REPO/src/mobile/android/app/src/main" -name '*.xml')
ANDROID_GRADLE=$( { find "$REPO/src/mobile/android" -maxdepth 4 -type f \
    \( -name '*.gradle' -o -name 'proguard-rules.pro' -o -name 'gradle.properties' \) \
    ! -path '*/.gradle/*' ! -path '*/build/*' 2>/dev/null; } | sort )

# Infra
ROOT_SHELL=$(find "$REPO" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort)
CI_CONFIG=$( { find "$REPO" -maxdepth 1 -type f \
    \( -name '.gitlab-ci.yml' -o -name 'Dockerfile' -o -name 'docker-compose*.yml' \) 2>/dev/null; } | sort )

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
TS_UNIT_TEST_TOTAL=0
[[ -n "$TS_UNIT_TEST" ]] && TS_UNIT_TEST_TOTAL=$(echo "$TS_UNIT_TEST" | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
TS_E2E_TEST_TOTAL=0
[[ -n "$TS_E2E_TEST" ]]  && TS_E2E_TEST_TOTAL=$(echo "$TS_E2E_TEST"  | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
SCSS_TOTAL=$(echo "$SCSS_SRC" | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')

PY_TOTAL=0
[[ -n "$PY_SRC" ]]   && PY_TOTAL=$(echo "$PY_SRC"   | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
PY_SVC_TOTAL=0
[[ -n "$PY_SVC" ]]   && PY_SVC_TOTAL=$(echo "$PY_SVC" | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
CONF_TOTAL=0
[[ -n "$CONF_SRC" ]] && CONF_TOTAL=$(echo "$CONF_SRC" | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
SQL_TOTAL=0
[[ -n "$SQL_SRC" ]]  && SQL_TOTAL=$(echo "$SQL_SRC"  | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')

# Mobile — iOS
SWIFT_APP_TOTAL=0
[[ -n "$SWIFT_APP" ]]  && SWIFT_APP_TOTAL=$(echo "$SWIFT_APP"  | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
SWIFT_TEST_TOTAL=0
[[ -n "$SWIFT_TEST" ]] && SWIFT_TEST_TOTAL=$(echo "$SWIFT_TEST" | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
IOS_RES_TOTAL=0
[[ -n "$IOS_RES" ]]    && IOS_RES_TOTAL=$(echo "$IOS_RES"     | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')

# Mobile — Android
KOTLIN_TOTAL=0
[[ -n "$KOTLIN_SRC" ]]    && KOTLIN_TOTAL=$(echo "$KOTLIN_SRC"     | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
ANDROID_XML_TOTAL=0
[[ -n "$ANDROID_XML" ]]   && ANDROID_XML_TOTAL=$(echo "$ANDROID_XML"   | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
ANDROID_GRADLE_TOTAL=0
[[ -n "$ANDROID_GRADLE" ]] && ANDROID_GRADLE_TOTAL=$(echo "$ANDROID_GRADLE" | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')

# Infra
ROOT_SHELL_TOTAL=0
[[ -n "$ROOT_SHELL" ]] && ROOT_SHELL_TOTAL=$(echo "$ROOT_SHELL" | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
CI_CONFIG_TOTAL=0
[[ -n "$CI_CONFIG" ]]  && CI_CONFIG_TOTAL=$(echo "$CI_CONFIG"  | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')

DOC_TOTAL=$(echo "$DOC_MD"  | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
DOC_WORDS=$(echo "$DOC_MD"  | xargs wc -w 2>/dev/null | tail -1 | awk '{print $1}')
ROOT_MD_TOTAL=0
ROOT_MD_WORDS=0
[[ -n "$ROOT_MD" ]] && ROOT_MD_TOTAL=$(echo "$ROOT_MD" | xargs wc -l 2>/dev/null | tail -1 | awk '{print $1}')
[[ -n "$ROOT_MD" ]] && ROOT_MD_WORDS=$(echo "$ROOT_MD" | xargs wc -w 2>/dev/null | tail -1 | awk '{print $1}')

DOC_FILES=$(echo "$DOC_MD" | grep -c '.' || true)
ROOT_MD_FILES=$(echo "$ROOT_MD" | grep -c '.' 2>/dev/null || true)

# ── file counts ────────────────────────────────────────────────────────────────

LUA_SRC_FILES=$(echo "$LUA_SRC"   | grep -c '.' || true)
LUA_TEST_FILES=$(echo "$LUA_TEST" | grep -c '.' || true)
TS_FILES=$(echo "$TS_SRC"              | grep -c '.' || true)
TS_UNIT_TEST_FILES=0
[[ -n "$TS_UNIT_TEST" ]] && TS_UNIT_TEST_FILES=$(echo "$TS_UNIT_TEST" | grep -c '.' || true)
TS_E2E_TEST_FILES=0
[[ -n "$TS_E2E_TEST" ]]  && TS_E2E_TEST_FILES=$(echo "$TS_E2E_TEST"  | grep -c '.' || true)
SCSS_FILES=$(echo "$SCSS_SRC"     | grep -c '.' || true)
PY_FILES=0;   [[ -n "$PY_SRC" ]]   && PY_FILES=$(echo "$PY_SRC"   | grep -c '.' || true)
PY_SVC_FILES=0; [[ -n "$PY_SVC" ]] && PY_SVC_FILES=$(echo "$PY_SVC" | grep -c '.' || true)
CONF_FILES=0; [[ -n "$CONF_SRC" ]] && CONF_FILES=$(echo "$CONF_SRC" | grep -c '.' || true)
SQL_FILES=0;  [[ -n "$SQL_SRC" ]]  && SQL_FILES=$(echo "$SQL_SRC"  | grep -c '.' || true)

SWIFT_APP_FILES=0;  [[ -n "$SWIFT_APP" ]]    && SWIFT_APP_FILES=$(echo "$SWIFT_APP"    | grep -c '.' || true)
SWIFT_TEST_FILES=0; [[ -n "$SWIFT_TEST" ]]   && SWIFT_TEST_FILES=$(echo "$SWIFT_TEST"  | grep -c '.' || true)
IOS_RES_FILES=0;    [[ -n "$IOS_RES" ]]      && IOS_RES_FILES=$(echo "$IOS_RES"       | grep -c '.' || true)
KOTLIN_FILES=0;     [[ -n "$KOTLIN_SRC" ]]   && KOTLIN_FILES=$(echo "$KOTLIN_SRC"     | grep -c '.' || true)
ANDROID_XML_FILES=0; [[ -n "$ANDROID_XML" ]] && ANDROID_XML_FILES=$(echo "$ANDROID_XML" | grep -c '.' || true)
ANDROID_GRADLE_FILES=0; [[ -n "$ANDROID_GRADLE" ]] && ANDROID_GRADLE_FILES=$(echo "$ANDROID_GRADLE" | grep -c '.' || true)
ROOT_SHELL_FILES=0; [[ -n "$ROOT_SHELL" ]]   && ROOT_SHELL_FILES=$(echo "$ROOT_SHELL" | grep -c '.' || true)
CI_CONFIG_FILES=0;  [[ -n "$CI_CONFIG" ]]    && CI_CONFIG_FILES=$(echo "$CI_CONFIG"   | grep -c '.' || true)

# ── totals ─────────────────────────────────────────────────────────────────────

SRC_TOTAL=$(( LUA_SRC_TOTAL + LUA_TEST_TOTAL + LUA_CFG_TOTAL \
            + TS_TOTAL + TS_UNIT_TEST_TOTAL + TS_E2E_TEST_TOTAL + SCSS_TOTAL \
            + PY_TOTAL + PY_SVC_TOTAL + CONF_TOTAL + SQL_TOTAL \
            + SWIFT_APP_TOTAL + SWIFT_TEST_TOTAL + IOS_RES_TOTAL \
            + KOTLIN_TOTAL + ANDROID_XML_TOTAL + ANDROID_GRADLE_TOTAL \
            + ROOT_SHELL_TOTAL + CI_CONFIG_TOTAL ))
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

if [[ $LUA_CFG_TOTAL -gt 0 ]]; then
echo "── Lua config  ──────────────────────────────────────────────────"
row "  config/*.lua" "$LUA_CFG_TOTAL"
echo ""
fi

echo "── Lua tests   ($LUA_TEST_FILES files) ─────────────────────────────────"
row "  tests/" "$LUA_TEST_TOTAL"
LUA_SRC_CFG=$(( LUA_SRC_TOTAL + LUA_CFG_TOTAL ))
LUA_RATIO=$(awk "BEGIN {printf \"%.2f\", ($LUA_SRC_CFG == 0 ? 0 : $LUA_TEST_TOTAL / $LUA_SRC_CFG)}")
printf "  %-36s %6s\n" "  tests / src+cfg ratio" "${LUA_RATIO}×"
echo ""

echo "── Frontend TypeScript/TSX  ($TS_FILES files) ──────────────────────────"
row "  frontend/src/" "$TS_TOTAL"
echo ""

echo "── Frontend SCSS  ($SCSS_FILES files) ──────────────────────────────────"
row "  frontend/src/" "$SCSS_TOTAL"
echo ""

TS_TEST_TOTAL=$(( TS_UNIT_TEST_TOTAL + TS_E2E_TEST_TOTAL ))
TS_TEST_FILES=$(( TS_UNIT_TEST_FILES + TS_E2E_TEST_FILES ))

if [[ $TS_UNIT_TEST_TOTAL -gt 0 ]]; then
echo "── Frontend TS unit tests  ($TS_UNIT_TEST_FILES files) ─────────────────────────"
row "  frontend/src/**/*.test.*" "$TS_UNIT_TEST_TOTAL"
echo ""
fi

if [[ $TS_E2E_TEST_TOTAL -gt 0 ]]; then
echo "── Frontend TS e2e/Playwright  ($TS_E2E_TEST_FILES files) ──────────────────────"
row "  frontend/tests/" "$TS_E2E_TEST_TOTAL"
fi

if [[ $TS_TEST_TOTAL -gt 0 ]]; then
TS_SRC_SCSS=$(( TS_TOTAL + SCSS_TOTAL ))
TS_RATIO=$(awk "BEGIN {printf \"%.2f\", ($TS_SRC_SCSS == 0 ? 0 : $TS_TEST_TOTAL / $TS_SRC_SCSS)}")
printf "  %-36s %6s\n" "  tests / ts+scss ratio" "${TS_RATIO}×"
fi
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

if [[ $PY_SVC_TOTAL -gt 0 ]]; then
echo "── Python services  ($PY_SVC_FILES files) ──────────────────────────────"
row "  src/" "$PY_SVC_TOTAL"
echo ""
fi

if [[ $SWIFT_APP_TOTAL -gt 0 || $SWIFT_TEST_TOTAL -gt 0 ]]; then
SWIFT_FILES=$(( SWIFT_APP_FILES + SWIFT_TEST_FILES ))
echo "── iOS Swift  ($SWIFT_FILES files) ──────────────────────────────────────"
[[ $SWIFT_APP_TOTAL  -gt 0 ]] && row "  src/mobile/ios/.../Sources/" "$SWIFT_APP_TOTAL"
[[ $SWIFT_TEST_TOTAL -gt 0 ]] && row "  src/mobile/ios/.../Tests/"   "$SWIFT_TEST_TOTAL"
if [[ $SWIFT_TEST_TOTAL -gt 0 && $SWIFT_APP_TOTAL -gt 0 ]]; then
    SWIFT_RATIO=$(awk "BEGIN {printf \"%.2f\", $SWIFT_TEST_TOTAL / $SWIFT_APP_TOTAL}")
    printf "  %-36s %6s\n" "  tests / app ratio" "${SWIFT_RATIO}×"
fi
echo ""
fi

if [[ $IOS_RES_TOTAL -gt 0 ]]; then
echo "── iOS resources  ($IOS_RES_FILES files) ───────────────────────────────"
row "  Info.plist / entitlements / pbxproj / scheme / codemagic.yaml" "$IOS_RES_TOTAL"
echo ""
fi

if [[ $KOTLIN_TOTAL -gt 0 ]]; then
echo "── Android Kotlin  ($KOTLIN_FILES files) ───────────────────────────────"
row "  src/mobile/android/.../java/" "$KOTLIN_TOTAL"
echo ""
fi

if [[ $ANDROID_XML_TOTAL -gt 0 || $ANDROID_GRADLE_TOTAL -gt 0 ]]; then
ANDROID_RES_FILES=$(( ANDROID_XML_FILES + ANDROID_GRADLE_FILES ))
echo "── Android resources / Gradle  ($ANDROID_RES_FILES files) ──────────────"
[[ $ANDROID_XML_TOTAL    -gt 0 ]] && row "  res/ + AndroidManifest.xml"     "$ANDROID_XML_TOTAL"
[[ $ANDROID_GRADLE_TOTAL -gt 0 ]] && row "  *.gradle / proguard-rules.pro"  "$ANDROID_GRADLE_TOTAL"
echo ""
fi

if [[ $ROOT_SHELL_TOTAL -gt 0 ]]; then
echo "── Repo-root shell  ($ROOT_SHELL_FILES files) ──────────────────────────"
row "  ./*.sh" "$ROOT_SHELL_TOTAL"
echo ""
fi

if [[ $CI_CONFIG_TOTAL -gt 0 ]]; then
echo "── CI / build config  ($CI_CONFIG_FILES files) ─────────────────────────"
row "  .gitlab-ci.yml / Dockerfile / docker-compose*.yml" "$CI_CONFIG_TOTAL"
echo ""
fi

echo "═══════════════════════════════════════════════════════════════"
printf "  %-36s %6d lines\n" "SOURCE CODE TOTAL" "$SRC_TOTAL"
echo ""

echo "── Documentation  ($DOC_FILES files + $ROOT_MD_FILES root md) ─────────────"
printf "  %-36s %6d lines  %7d words\n" "  docs/docs.md/" "$DOC_TOTAL" "$DOC_WORDS"
[[ $ROOT_MD_TOTAL -gt 0 ]] && printf "  %-36s %6d lines  %7d words\n" "  /*.md (root)" "$ROOT_MD_TOTAL" "$ROOT_MD_WORDS"
echo ""
printf "  %-36s %6d lines  %7d words\n" "DOCS TOTAL" "$(( DOC_TOTAL + ROOT_MD_TOTAL ))" "$(( DOC_WORDS + ROOT_MD_WORDS ))"
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
    echo "── Verbose: TypeScript/TSX source files ─────────────────────"
    echo "$TS_SRC" | xargs wc -l 2>/dev/null | sort -rn | grep -v '^ *0 ' | grep -v total | \
        awk -v repo="$REPO/frontend/src/" '{sub(repo,"",$2); printf "  %5d  %s\n", $1, $2}'
    echo ""
    if [[ -n "$TS_UNIT_TEST" ]]; then
    echo "── Verbose: TypeScript unit test files ──────────────────────"
    echo "$TS_UNIT_TEST" | xargs wc -l 2>/dev/null | sort -rn | grep -v '^ *0 ' | grep -v total | \
        awk -v repo="$REPO/frontend/src/" '{sub(repo,"",$2); printf "  %5d  %s\n", $1, $2}'
    echo ""
    fi
    if [[ -n "$TS_E2E_TEST" ]]; then
    echo "── Verbose: TypeScript e2e/Playwright files ─────────────────"
    echo "$TS_E2E_TEST" | xargs wc -l 2>/dev/null | sort -rn | grep -v '^ *0 ' | grep -v total | \
        awk -v repo="$REPO/frontend/src/" '{sub(repo,"",$2); printf "  %5d  %s\n", $1, $2}'
    echo ""
    fi
    echo "── Verbose: documentation files ────────────────────────────"
    echo "$DOC_MD" | xargs wc -l 2>/dev/null | sort -rn | grep -v '^ *0 ' | grep -v total | \
        awk -v repo="$REPO/docs/docs.md/" '{sub(repo,"",$2); printf "  %5d  %s\n", $1, $2}'
fi
