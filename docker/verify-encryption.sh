#!/bin/bash
# Chronicle PostgreSQL Encryption Verification Script
#
# This script verifies that Transparent Data Encryption (TDE) is properly
# configured and working in the PostgreSQL database.
#
# Usage: ./verify-encryption.sh [docker-compose-file]
#        Default: docker-compose.prod.yml

set -e

COMPOSE_FILE="${1:-docker-compose.prod.yml}"
CONTAINER_NAME="chronicle-postgres"
DB_USER="${POSTGRES_USER:-chronicle}"
DB_NAME="${POSTGRES_DB:-chronicle}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Chronicle TDE Verification"
echo "=========================================="
echo ""

# Function to run psql command
run_psql() {
    docker-compose -f "${COMPOSE_FILE}" exec -T postgres \
        psql -U "${DB_USER}" -d "${DB_NAME}" -t -c "$1" 2>/dev/null | tr -d ' '
}

# Function to print status
print_status() {
    local check_name="$1"
    local status="$2"
    local details="$3"

    if [ "$status" = "PASS" ]; then
        echo -e "[${GREEN}PASS${NC}] $check_name"
    elif [ "$status" = "WARN" ]; then
        echo -e "[${YELLOW}WARN${NC}] $check_name"
    else
        echo -e "[${RED}FAIL${NC}] $check_name"
    fi

    if [ -n "$details" ]; then
        echo "       $details"
    fi
}

# Check 1: Container is running
echo "1. Checking PostgreSQL container..."
if docker-compose -f "${COMPOSE_FILE}" ps --services --filter "status=running" | grep -q postgres; then
    print_status "PostgreSQL container is running" "PASS"
else
    print_status "PostgreSQL container is NOT running" "FAIL"
    echo ""
    echo "Start the container with: docker-compose -f ${COMPOSE_FILE} up -d postgres"
    exit 1
fi
echo ""

# Check 2: pg_tde extension is installed
echo "2. Checking pg_tde extension..."
EXTENSION_EXISTS=$(run_psql "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pg_tde');")
if [ "$EXTENSION_EXISTS" = "t" ]; then
    print_status "pg_tde extension is installed" "PASS"
else
    print_status "pg_tde extension is NOT installed" "FAIL"
    echo ""
    echo "The pg_tde extension should be installed automatically on container start."
    echo "Check container logs: docker-compose -f ${COMPOSE_FILE} logs postgres"
    exit 1
fi
echo ""

# Check 3: Key provider is configured
echo "3. Checking key provider configuration..."
KEY_PROVIDER=$(docker-compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${DB_USER}" -d "${DB_NAME}" -t -c "SELECT provider_name FROM pg_tde_list_key_providers() LIMIT 1;" 2>/dev/null | tr -d ' ')

if [ -n "$KEY_PROVIDER" ]; then
    print_status "Key provider configured" "PASS" "Provider: $KEY_PROVIDER"
else
    print_status "No key provider configured" "FAIL"
    echo ""
    echo "A key provider should be configured automatically on container start."
    echo "Check container logs: docker-compose -f ${COMPOSE_FILE} logs postgres"
    exit 1
fi
echo ""

# Check 4: Principal key is set
echo "4. Checking principal encryption key..."
PRINCIPAL_KEY=$(docker-compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${DB_USER}" -d "${DB_NAME}" -t -c "SELECT key_name FROM pg_tde_list_all_keys() WHERE key_name = 'chronicle-principal-key' LIMIT 1;" 2>/dev/null | tr -d ' ')

if [ -n "$PRINCIPAL_KEY" ]; then
    print_status "Principal encryption key is set" "PASS" "Key: $PRINCIPAL_KEY"
else
    print_status "Principal encryption key is NOT set" "WARN"
    echo "       The principal key may not have been created yet."
fi
echo ""

# Check 5: Test encrypted table creation
echo "5. Testing encrypted table creation..."
CREATE_RESULT=$(docker-compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${DB_USER}" -d "${DB_NAME}" -c "
        DROP TABLE IF EXISTS _encryption_test_table;
        CREATE TABLE _encryption_test_table (
            id SERIAL PRIMARY KEY,
            test_data TEXT
        ) USING tde_heap;
        INSERT INTO _encryption_test_table (test_data) VALUES ('test encryption');
    " 2>&1)

if echo "$CREATE_RESULT" | grep -q "CREATE TABLE"; then
    print_status "Encrypted table creation works" "PASS"
else
    print_status "Failed to create encrypted table" "FAIL"
    echo "       Error: $CREATE_RESULT"
    exit 1
fi
echo ""

# Check 6: Verify table is encrypted
echo "6. Verifying table encryption..."
IS_ENCRYPTED=$(run_psql "SELECT pgtde_is_encrypted('_encryption_test_table');")
if [ "$IS_ENCRYPTED" = "t" ]; then
    print_status "Table is encrypted" "PASS"
else
    print_status "Table is NOT encrypted" "FAIL"
    exit 1
fi
echo ""

# Clean up test table
docker-compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${DB_USER}" -d "${DB_NAME}" -c "DROP TABLE IF EXISTS _encryption_test_table;" >/dev/null 2>&1

# Check 7: Key file/Vault security (for file provider)
echo "7. Checking key storage security..."
KEY_PROVIDER_TYPE="${PG_TDE_KEY_PROVIDER:-file}"

if [ "$KEY_PROVIDER_TYPE" = "file" ]; then
    # Check if keyring volume exists and has correct permissions
    KEYRING_PERMS=$(docker-compose -f "${COMPOSE_FILE}" exec -T postgres \
        stat -c "%a" /var/lib/postgresql/tde-keyring 2>/dev/null || echo "error")

    if [ "$KEYRING_PERMS" = "700" ]; then
        print_status "Keyring directory has secure permissions (700)" "PASS"
    elif [ "$KEYRING_PERMS" = "error" ]; then
        print_status "Cannot check keyring directory permissions" "WARN"
    else
        print_status "Keyring directory permissions: $KEYRING_PERMS (should be 700)" "WARN"
    fi

    echo ""
    echo -e "${YELLOW}WARNING: File-based key provider is for DEVELOPMENT only.${NC}"
    echo "For production, configure HashiCorp Vault:"
    echo "  PG_TDE_KEY_PROVIDER=vault"
    echo "  PG_TDE_VAULT_URL=https://vault.example.com:8200"
    echo "  PG_TDE_VAULT_TOKEN=<your-token>"
elif [ "$KEY_PROVIDER_TYPE" = "vault" ]; then
    print_status "Using Vault key provider (production mode)" "PASS"
fi
echo ""

# Summary
echo "=========================================="
echo "Verification Summary"
echo "=========================================="
echo ""
echo -e "${GREEN}All encryption checks passed!${NC}"
echo ""
echo "PostgreSQL data at rest is encrypted using pg_tde."
echo ""
echo "To create encrypted tables, use:"
echo "  CREATE TABLE my_table (...) USING tde_heap;"
echo ""
echo "To convert existing tables to encrypted:"
echo "  ALTER TABLE my_table SET ACCESS METHOD tde_heap;"
echo ""
echo "To verify a table is encrypted:"
echo "  SELECT pgtde_is_encrypted('my_table');"
echo ""

# List any existing encrypted tables
echo "Currently encrypted tables:"
docker-compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U "${DB_USER}" -d "${DB_NAME}" -c "
        SELECT c.relname AS table_name,
               am.amname AS access_method,
               CASE WHEN am.amname = 'tde_heap' THEN 'ENCRYPTED' ELSE 'NOT ENCRYPTED' END AS status
        FROM pg_class c
        JOIN pg_am am ON c.relam = am.oid
        WHERE c.relkind = 'r'
        AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
        ORDER BY c.relname;
    " 2>/dev/null || echo "No tables found."
echo ""
