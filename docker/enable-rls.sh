#!/usr/bin/env bash
# enable-rls.sh — Apply Row-Level Security migration to chronicle database
# Usage: ./enable-rls.sh [--check]
#   --check   Only verify RLS status, don't apply migration
set -euo pipefail

CONTAINER="chronicle-postgres"
DB="${POSTGRES_DB:-chronicle}"
USER="${POSTGRES_USER:-chronicle}"
MIGRATION_FILE="$(dirname "$0")/../chronicle-server/src/main/resources/db/migration/V1__enable_row_level_security.sql"

if [ ! -f "$MIGRATION_FILE" ]; then
    echo "ERROR: Migration file not found: $MIGRATION_FILE"
    exit 1
fi

check_rls() {
    echo "=== RLS Status ==="
    docker exec "$CONTAINER" psql -U "$USER" -d "$DB" -c \
        "SELECT schemaname, tablename, rowsecurity FROM pg_tables WHERE schemaname = 'public' AND rowsecurity = true ORDER BY tablename;"
    echo ""
    echo "=== RLS Policies ==="
    docker exec "$CONTAINER" psql -U "$USER" -d "$DB" -c \
        "SELECT tablename, policyname FROM pg_policies WHERE schemaname = 'public' ORDER BY tablename;"
}

if [ "${1:-}" = "--check" ]; then
    check_rls
    exit 0
fi

echo "Applying Row-Level Security migration..."
docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 < "$MIGRATION_FILE"

echo ""
echo "Migration complete. Verifying..."
check_rls
