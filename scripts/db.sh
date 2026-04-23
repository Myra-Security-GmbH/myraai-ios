#!/usr/bin/env bash
# scripts/db.sh — Database migration helper for AI Gateway
#
# Usage:
#   ./scripts/db.sh status  [prod|int]        Show applied and pending migrations
#   ./scripts/db.sh migrate [prod|int]        Apply pending migrations directly via CLI
#   ./scripts/db.sh new     DESCRIPTION       Create the next numbered migration file
#
# 'prod' (default) sources .env.production; 'int' sources .env.integration.
# Credentials from those files: AIG_MYSQL_PASS / AIG_MYSQL_PASS_INT.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MIGRATIONS_DIR="$REPO/src/storage/migrations"
MYSQL_LUA="$REPO/src/storage/mysql.lua"

# ---------------------------------------------------------------------------
# Config resolution
# ---------------------------------------------------------------------------

resolve_env() {
    local env="${1:-prod}"
    if [[ "$env" == "int" ]]; then
        local env_file="$REPO/.env.integration"
        [[ -f "$env_file" ]] || { echo "ERROR: .env.integration not found" >&2; exit 1; }
        # shellcheck disable=SC1090
        source "$env_file"
        DB_HOST="${AIG_MYSQL_HOST:-172.17.0.1}"
        DB_PORT="${AIG_MYSQL_PORT:-3306}"
        DB_NAME="${AIG_MYSQL_DB:-ai_gateway_int}"
        DB_USER="${AIG_MYSQL_USER:-gateway_int}"
        DB_PASS="${AIG_MYSQL_PASS_INT:-}"
    else
        local env_file="$REPO/.env.production"
        [[ -f "$env_file" ]] || { echo "ERROR: .env.production not found" >&2; exit 1; }
        # shellcheck disable=SC1090
        source "$env_file"
        DB_HOST="${AIG_MYSQL_HOST:-172.17.0.1}"
        DB_PORT="${AIG_MYSQL_PORT:-3306}"
        DB_NAME="${AIG_MYSQL_DB:-ai_gateway}"
        DB_USER="${AIG_MYSQL_USER:-gateway}"
        DB_PASS="${AIG_MYSQL_PASS:-}"
    fi
}

mysql_cmd() {
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" "$@"
}

# ---------------------------------------------------------------------------
# Parse MIGRATIONS registry from mysql.lua
# ---------------------------------------------------------------------------

parse_migrations() {
    # Extract lines like: { version = "NNNN", file = "...", description = "..." }
    grep -oP '(?<=version = ")[^"]+' "$MYSQL_LUA" | grep -E '^[0-9]{4}$'
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_status() {
    local env="${1:-prod}"
    resolve_env "$env"

    echo "=== Migration status ($env: $DB_NAME on $DB_HOST) ==="
    echo ""

    # Get applied versions from DB (schema_migrations may not exist yet)
    local applied
    applied=$(mysql_cmd -sN -e "SELECT version FROM schema_migrations ORDER BY version" 2>/dev/null || echo "")

    local all_versions
    all_versions=$(parse_migrations)

    local pending=0
    while IFS= read -r ver; do
        if echo "$applied" | grep -qx "$ver"; then
            echo "  [applied]  $ver"
        else
            echo "  [PENDING]  $ver"
            ((pending++)) || true
        fi
    done <<< "$all_versions"

    echo ""
    if [[ $pending -eq 0 ]]; then
        echo "All migrations applied."
    else
        echo "$pending migration(s) pending. Run '$0 migrate $env' or restart the container."
    fi
}

cmd_migrate() {
    local env="${1:-prod}"
    resolve_env "$env"

    echo "=== Applying pending migrations ($env: $DB_NAME on $DB_HOST) ==="

    # Ensure tracking table exists
    mysql_cmd -e "
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version     VARCHAR(16)  NOT NULL,
            applied_at  BIGINT       NOT NULL,
            description VARCHAR(255) NOT NULL DEFAULT '',
            PRIMARY KEY (version)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    "

    local applied
    applied=$(mysql_cmd -sN -e "SELECT version FROM schema_migrations ORDER BY version")

    local all_versions
    all_versions=$(parse_migrations)

    while IFS= read -r ver; do
        if echo "$applied" | grep -qx "$ver"; then
            echo "  [skip]     $ver (already applied)"
            continue
        fi

        # Find the file for this version
        local file
        file=$(grep -oP "(?<=version = \"$ver\".*?file = \")[^\"]+|(?<=file = \")[^\"]+(?=\".*version = \"$ver\")" \
               "$MYSQL_LUA" 2>/dev/null | head -1 || \
               ls "$MIGRATIONS_DIR/${ver}_"*.sql 2>/dev/null | head -1 | xargs basename || true)

        local path="$MIGRATIONS_DIR/$file"
        if [[ ! -f "$path" ]]; then
            # Try glob
            path=$(ls "$MIGRATIONS_DIR/${ver}_"*.sql 2>/dev/null | head -1 || true)
        fi

        if [[ -z "$path" || ! -f "$path" ]]; then
            echo "  ERROR: migration file for $ver not found in $MIGRATIONS_DIR" >&2
            exit 1
        fi

        echo "  [apply]    $ver — $(basename "$path")"
        mysql_cmd < "$path"
        mysql_cmd -e "INSERT IGNORE INTO schema_migrations (version, applied_at, description) VALUES ('$ver', UNIX_TIMESTAMP(), '$(basename "$path")')"
        echo "  [done]     $ver"
    done <<< "$all_versions"

    echo ""
    echo "Done."
}

cmd_new() {
    local desc="${1:-}"
    [[ -n "$desc" ]] || { echo "Usage: $0 new DESCRIPTION" >&2; exit 1; }

    # Determine next version number
    local last
    last=$(ls "$MIGRATIONS_DIR"/*.sql 2>/dev/null | grep -oP '^\d+' | sort -n | tail -1 || echo "0000")
    # last is basename, so extract from filenames
    last=$(ls "$MIGRATIONS_DIR"/*.sql 2>/dev/null | xargs -I{} basename {} | grep -oP '^\d+' | sort -n | tail -1 || echo "0000")
    local next
    next=$(printf "%04d" $(( 10#$last + 1 )))

    local slug
    slug=$(echo "$desc" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
    local filename="${next}_${slug}.sql"
    local filepath="$MIGRATIONS_DIR/$filename"

    cat > "$filepath" <<EOF
-- Migration: $next
-- Description: $desc

EOF

    echo "Created: $filepath"
    echo ""
    echo "Next steps:"
    echo "  1. Add your SQL to $filepath"
    echo "  2. Add to MIGRATIONS registry in src/storage/mysql.lua:"
    echo "     { version = \"$next\", file = \"$filename\", description = \"$desc\" },"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

CMD="${1:-}"
shift || true

case "$CMD" in
    status)  cmd_status  "${1:-prod}" ;;
    migrate) cmd_migrate "${1:-prod}" ;;
    new)     cmd_new     "$@" ;;
    *)
        echo "Usage: $0 <command> [env]"
        echo ""
        echo "Commands:"
        echo "  status  [prod|int]   Show applied and pending migrations"
        echo "  migrate [prod|int]   Apply pending migrations via CLI"
        echo "  new     DESCRIPTION  Create the next migration file"
        echo ""
        echo "env defaults to prod. Credentials sourced from .env.production or .env.integration."
        exit 1
        ;;
esac
