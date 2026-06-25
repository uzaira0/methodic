#!/bin/bash
# Chronicle TDE Migration Script
# Idempotent script to enable Transparent Data Encryption on sensitive tables.
#
# Usage: ./migrate-tde.sh
# Runs via docker exec against the running chronicle-postgres container.
#
# Prerequisites:
#   - chronicle-postgres container running
#   - shared_preload_libraries includes pg_tde (set in docker-compose.traefik.yml)
#
# pg_tde version: 2.0.0 (Percona PostgreSQL 17.5)

set -euo pipefail

CONTAINER="chronicle-postgres"
DB_USER="chronicle"
DB_NAME="chronicle"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

KEYRING_DIR="/var/lib/postgresql/tde-keyring"
KEYRING_FILE="${KEYRING_DIR}/chronicle-keyring.per"
PROVIDER_NAME="chronicle-file-vault"
KEY_NAME="chronicle-principal-key"

# Public application tables to encrypt. Populated dynamically after pg_tde is ready
# so the inventory cannot drift when schema migrations add tables.
SENSITIVE_TABLES=()

run_psql() {
    docker exec "$CONTAINER" bash -lc \
        "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U \"\${POSTGRES_USER:-$DB_USER}\" -d \"\${POSTGRES_DB:-$DB_NAME}\" -t -A -c \"$1\""
}

run_psql_verbose() {
    docker exec "$CONTAINER" bash -lc \
        "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U \"\${POSTGRES_USER:-$DB_USER}\" -d \"\${POSTGRES_DB:-$DB_NAME}\" -c \"$1\"" \
        2>&1
}

discover_sensitive_tables() {
    SENSITIVE_TABLES=()
    local table_output
    table_output=$(run_psql "
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'r'
        AND n.nspname = 'public'
        ORDER BY c.relname;
    ")
    while IFS= read -r TABLE; do
        if [ -n "$TABLE" ]; then
            SENSITIVE_TABLES+=("$TABLE")
        fi
    done <<< "$table_output"
}

echo "=========================================="
echo "Chronicle TDE Migration"
echo "=========================================="
echo ""

# Step 1: Verify container is running
echo "1. Checking container..."
if ! docker inspect "$CONTAINER" --format='{{.State.Running}}' 2>/dev/null | grep -q true; then
    echo -e "${RED}ABORT: Container $CONTAINER is not running${NC}"
    exit 1
fi
echo -e "   ${GREEN}Container is running${NC}"
echo ""

# Step 2: Verify pg_tde is in shared_preload_libraries
echo "2. Checking shared_preload_libraries..."
SPL=$(run_psql "SHOW shared_preload_libraries;")
if ! echo "$SPL" | grep -q "pg_tde"; then
    echo -e "${RED}ABORT: pg_tde is NOT in shared_preload_libraries${NC}"
    echo "   Current value: $SPL"
    echo "   Add to docker-compose.traefik.yml postgres command:"
    echo "     -c shared_preload_libraries=pg_tde,percona_pg_telemetry"
    exit 1
fi
echo -e "   ${GREEN}pg_tde is loaded: $SPL${NC}"
echo ""

# Step 3: Create extension if needed
echo "3. Creating pg_tde extension..."
EXT_EXISTS=$(run_psql "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pg_tde');")
if [ "$EXT_EXISTS" = "t" ]; then
    echo -e "   ${GREEN}pg_tde extension already exists${NC}"
else
    run_psql_verbose "CREATE EXTENSION pg_tde;"
    echo -e "   ${GREEN}pg_tde extension created${NC}"
fi
echo ""

# Step 4: Setup keyring directory (needs root for chown on named volume)
echo "4. Setting up TDE keyring directory..."
docker exec -u root "$CONTAINER" sh -c "mkdir -p ${KEYRING_DIR} && chown postgres:postgres ${KEYRING_DIR} && chmod 700 ${KEYRING_DIR}" 2>&1
echo -e "   ${GREEN}Keyring directory ready${NC}"
echo ""

# Step 5: Add file-based key provider if not exists
# pg_tde 2.0.0 uses pg_tde_list_all_database_key_providers()
echo "5. Configuring key provider..."
PROVIDER_EXISTS=$(run_psql "SELECT COUNT(*) FROM pg_tde_list_all_database_key_providers() WHERE name = '${PROVIDER_NAME}';")
if [ "$PROVIDER_EXISTS" -gt 0 ]; then
    echo -e "   ${GREEN}Key provider '${PROVIDER_NAME}' already exists${NC}"
else
    run_psql_verbose "SELECT pg_tde_add_database_key_provider_file('${PROVIDER_NAME}', '${KEYRING_FILE}');"
    echo -e "   ${GREEN}Key provider created${NC}"
fi
echo ""

# Step 6: Create and set principal key if not exists
# pg_tde 2.0.0: try to create key; if it already exists, just ensure it's set
echo "6. Setting principal key..."
KEY_EXISTS=$(run_psql "SELECT COUNT(*) FROM pg_tde_key_info() WHERE key_name = '${KEY_NAME}';")
if [ "$KEY_EXISTS" -gt 0 ]; then
    echo -e "   ${GREEN}Principal key '${KEY_NAME}' already exists${NC}"
else
    run_psql_verbose "SELECT pg_tde_create_key_using_database_key_provider('${KEY_NAME}', '${PROVIDER_NAME}');"
    echo -e "   ${GREEN}Principal key created${NC}"
fi
run_psql_verbose "SELECT pg_tde_set_key_using_database_key_provider('${KEY_NAME}', '${PROVIDER_NAME}');" >/dev/null
echo -e "   ${GREEN}Principal key set${NC}"
echo ""

# Step 7: Convert public application tables to tde_heap
echo "7. Discovering and converting public application tables to tde_heap..."
echo ""
discover_sensitive_tables
if [ "${#SENSITIVE_TABLES[@]}" -eq 0 ]; then
    echo -e "   ${RED}ABORT${NC} No public application tables found; table discovery failed or migrations have not run"
    exit 1
fi

CONVERTED=0
SKIPPED=0
FAILED=0

for TABLE in "${SENSITIVE_TABLES[@]}"; do
    # Check if table exists
    TABLE_EXISTS=$(run_psql "SELECT EXISTS(SELECT 1 FROM pg_class WHERE relname = '$TABLE' AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public'));")
    if [ "$TABLE_EXISTS" != "t" ]; then
        echo -e "   ${YELLOW}SKIP${NC} $TABLE (table does not exist)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Check current access method
    CURRENT_AM=$(run_psql "SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam = am.oid WHERE c.relname = '$TABLE' AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');")
    if [ "$CURRENT_AM" = "tde_heap" ]; then
        echo -e "   ${GREEN}OK${NC}   $TABLE (already tde_heap)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Convert table
    OUTPUT=$(run_psql_verbose "ALTER TABLE public.\"$TABLE\" SET ACCESS METHOD tde_heap;" 2>&1)
    if echo "$OUTPUT" | grep -q "ALTER TABLE"; then
        echo -e "   ${GREEN}DONE${NC} $TABLE (heap -> tde_heap)"
        CONVERTED=$((CONVERTED + 1))
    else
        echo -e "   ${RED}FAIL${NC} $TABLE: $OUTPUT"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "   Converted: $CONVERTED | Skipped: $SKIPPED | Failed: $FAILED"
echo ""

# Step 8: Verification summary
echo "8. Verification summary:"
echo ""
echo "   Public application table encryption status:"
run_psql_verbose "
SELECT c.relname AS table_name,
       am.amname AS access_method,
       CASE WHEN am.amname = 'tde_heap' THEN 'ENCRYPTED' ELSE 'NOT ENCRYPTED' END AS status
FROM pg_class c
JOIN pg_am am ON c.relam = am.oid
WHERE c.relkind = 'r'
AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
ORDER BY c.relname;
"

echo ""
echo "=========================================="
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}TDE Migration Complete${NC}"
else
    echo -e "${RED}TDE Migration completed with $FAILED failures${NC}"
    exit 1
fi
echo "=========================================="
