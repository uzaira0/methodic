#!/bin/bash
# Chronicle PostgreSQL Encryption Initialization Script
# This script sets up Transparent Data Encryption (TDE) using Percona's pg_tde extension
#
# Usage: This script runs automatically as a Docker entrypoint script
#        Place it in /docker-entrypoint-initdb.d/ to run on first container start
#
# For HIPAA/GDPR compliance, data at rest must be encrypted.

set -euo pipefail

echo "=========================================="
echo "Chronicle PostgreSQL TDE Initialization"
echo "=========================================="

# Configuration from environment variables
PG_TDE_KEY_PROVIDER="${PG_TDE_KEY_PROVIDER:-file}"
PG_TDE_VAULT_URL="${PG_TDE_VAULT_URL:-}"
PG_TDE_VAULT_TOKEN="${PG_TDE_VAULT_TOKEN:-}"
PG_TDE_VAULT_MOUNT_PATH="${PG_TDE_VAULT_MOUNT_PATH:-secret}"
PG_TDE_VAULT_CA_PATH="${PG_TDE_VAULT_CA_PATH:-}"
POSTGRES_DB="${POSTGRES_DB:-chronicle}"

# Key file location (for file-based provider only, used in development/testing)
# In production, use HashiCorp Vault or another KMS
PG_TDE_KEYRING_DIR="/var/lib/postgresql/tde-keyring"
PG_TDE_KEYRING_FILE="${PG_TDE_KEYRING_DIR}/chronicle-keyring.per"

echo "[INFO] TDE Key Provider: ${PG_TDE_KEY_PROVIDER}"

# Function to wait for PostgreSQL to be ready
wait_for_postgres() {
    echo "[INFO] Waiting for PostgreSQL to be ready..."
    until pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB}"; do
        echo "[INFO] PostgreSQL is not ready yet. Waiting..."
        sleep 2
    done
    echo "[INFO] PostgreSQL is ready."
}

# Function to create pg_tde extension
create_extension() {
    echo "[INFO] Creating pg_tde extension in database: ${POSTGRES_DB}"
    psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname "${POSTGRES_DB}" <<-EOSQL
        -- Check if extension already exists
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_tde') THEN
                CREATE EXTENSION pg_tde;
                RAISE NOTICE 'pg_tde extension created successfully';
            ELSE
                RAISE NOTICE 'pg_tde extension already exists';
            END IF;
        END
        \$\$;
EOSQL
}

# Function to setup file-based key provider (for development/testing)
setup_file_key_provider() {
    echo "[INFO] Setting up file-based key provider (development mode)"
    echo "[WARNING] File-based key provider is for DEVELOPMENT/TESTING only!"
    echo "[WARNING] For production, configure HashiCorp Vault using PG_TDE_KEY_PROVIDER=vault"

    # Create keyring directory with secure permissions
    mkdir -p "${PG_TDE_KEYRING_DIR}"
    chmod 700 "${PG_TDE_KEYRING_DIR}"
    chown postgres:postgres "${PG_TDE_KEYRING_DIR}"

    psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname "${POSTGRES_DB}" <<-EOSQL
        -- Add file-based key provider
        DO \$\$
        BEGIN
            -- Check if key provider already exists
            IF NOT EXISTS (
                SELECT 1 FROM pg_tde_list_all_database_key_providers()
                WHERE provider_name = 'chronicle-file-vault'
            ) THEN
                PERFORM pg_tde_add_database_key_provider_file(
                    'chronicle-file-vault',
                    '${PG_TDE_KEYRING_FILE}'
                );
                RAISE NOTICE 'File key provider created';
            ELSE
                RAISE NOTICE 'Key provider already exists';
            END IF;
        END
        \$\$;

        -- Create and set the principal key if not exists
        DO \$\$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM pg_tde_list_all_keys()
                WHERE key_name = 'chronicle-principal-key'
            ) THEN
                PERFORM pg_tde_create_key_using_database_key_provider(
                    'chronicle-principal-key',
                    'chronicle-file-vault'
                );
                PERFORM pg_tde_set_key_using_database_key_provider(
                    'chronicle-principal-key',
                    'chronicle-file-vault'
                );
                RAISE NOTICE 'Principal encryption key created and set';
            ELSE
                RAISE NOTICE 'Principal key already exists';
            END IF;
        END
        \$\$;
EOSQL

    echo "[INFO] File-based key provider configured"
    echo "[INFO] Keyring file location: ${PG_TDE_KEYRING_FILE}"
}

# Function to setup HashiCorp Vault key provider (for production)
setup_vault_key_provider() {
    echo "[INFO] Setting up HashiCorp Vault key provider (production mode)"

    # Validate required environment variables
    if [ -z "${PG_TDE_VAULT_URL}" ]; then
        echo "[ERROR] PG_TDE_VAULT_URL is required for Vault key provider"
        exit 1
    fi

    if [ -z "${PG_TDE_VAULT_TOKEN}" ]; then
        echo "[ERROR] PG_TDE_VAULT_TOKEN is required for Vault key provider"
        exit 1
    fi

    # Build Vault connection options
    VAULT_OPTIONS="url '${PG_TDE_VAULT_URL}', token '${PG_TDE_VAULT_TOKEN}', mount_path '${PG_TDE_VAULT_MOUNT_PATH}'"

    if [ -n "${PG_TDE_VAULT_CA_PATH}" ]; then
        VAULT_OPTIONS="${VAULT_OPTIONS}, ca_path '${PG_TDE_VAULT_CA_PATH}'"
    fi

    psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname "${POSTGRES_DB}" <<-EOSQL
        -- Add Vault key provider
        DO \$\$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM pg_tde_list_all_database_key_providers()
                WHERE provider_name = 'chronicle-vault'
            ) THEN
                PERFORM pg_tde_add_database_key_provider_vault_v2(
                    'chronicle-vault',
                    '${PG_TDE_VAULT_URL}',
                    '${PG_TDE_VAULT_TOKEN}',
                    '${PG_TDE_VAULT_MOUNT_PATH}',
                    '${PG_TDE_VAULT_CA_PATH}'
                );
                RAISE NOTICE 'Vault key provider created';
            ELSE
                RAISE NOTICE 'Vault key provider already exists';
            END IF;
        END
        \$\$;

        -- Create and set the principal key if not exists
        DO \$\$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM pg_tde_list_all_keys()
                WHERE key_name = 'chronicle-principal-key'
            ) THEN
                PERFORM pg_tde_create_key_using_database_key_provider(
                    'chronicle-principal-key',
                    'chronicle-vault'
                );
                PERFORM pg_tde_set_key_using_database_key_provider(
                    'chronicle-principal-key',
                    'chronicle-vault'
                );
                RAISE NOTICE 'Principal encryption key created and set in Vault';
            ELSE
                RAISE NOTICE 'Principal key already exists in Vault';
            END IF;
        END
        \$\$;
EOSQL

    echo "[INFO] HashiCorp Vault key provider configured"
    echo "[INFO] Vault URL: ${PG_TDE_VAULT_URL}"
}

# Function to verify encryption is working
verify_encryption() {
    echo "[INFO] Verifying TDE configuration..."

    psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname "${POSTGRES_DB}" <<-EOSQL
        -- List key providers
        SELECT * FROM pg_tde_list_all_database_key_providers();

        -- List encryption keys
        SELECT * FROM pg_tde_list_all_keys();

        -- Create a test encrypted table to verify TDE works
        CREATE TABLE IF NOT EXISTS _tde_verification_test (
            id SERIAL PRIMARY KEY,
            test_data TEXT,
            created_at TIMESTAMP DEFAULT NOW()
        ) USING tde_heap;

        -- Insert test data
        INSERT INTO _tde_verification_test (test_data)
        VALUES ('TDE verification test - ' || NOW()::TEXT)
        ON CONFLICT DO NOTHING;

        -- Verify table is encrypted
        SELECT pg_tde_is_encrypted('_tde_verification_test'::regclass) AS is_encrypted;

        -- Clean up test table
        DROP TABLE IF EXISTS _tde_verification_test;
EOSQL

    echo "[INFO] TDE verification completed successfully"
}

# Function to enable encryption on existing tables (for migrations)
enable_encryption_on_table() {
    local table_name=$1
    echo "[INFO] Enabling encryption on table: ${table_name}"

    psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname "${POSTGRES_DB}" <<-EOSQL
        ALTER TABLE ${table_name} SET ACCESS METHOD tde_heap;
EOSQL
}

# Main execution
echo "[INFO] Starting PostgreSQL TDE initialization..."

# Setup key provider based on configuration
case "${PG_TDE_KEY_PROVIDER}" in
    "file")
        create_extension
        setup_file_key_provider
        ;;
    "vault")
        create_extension
        setup_vault_key_provider
        ;;
    "none")
        echo "[WARNING] TDE is disabled. Set PG_TDE_KEY_PROVIDER=file or vault to enable."
        exit 0
        ;;
    *)
        echo "[ERROR] Unknown key provider: ${PG_TDE_KEY_PROVIDER}"
        echo "[ERROR] Valid options: file, vault, none"
        exit 1
        ;;
esac

# Verify encryption is working
verify_encryption

# Convert sensitive tables to tde_heap (idempotent)
# These tables contain PII, research data, or audit trails
echo "[INFO] Converting sensitive tables to tde_heap..."

SENSITIVE_TABLES=(
    candidates
    study_participants
    devices
    sensor_data
    android_sensor_data
    chronicle_usage_events
    chronicle_usage_stats
    preprocessed_usage_events
    questionnaire_submissions
    time_use_diary_submissions
    app_usage_survey
    upload_buffer
    audit
    audit_buffer
    participant_stats
)

for TABLE in "${SENSITIVE_TABLES[@]}"; do
    # Only convert if table exists (it may not on first init before backend creates schema)
    TABLE_EXISTS=$(psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB}" -t -A -c \
        "SELECT EXISTS(SELECT 1 FROM pg_class WHERE relname = '${TABLE}' AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public'));")
    if [ "$TABLE_EXISTS" = "t" ]; then
        CURRENT_AM=$(psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB}" -t -A -c \
            "SELECT am.amname FROM pg_class c JOIN pg_am am ON c.relam = am.oid WHERE c.relname = '${TABLE}';")
        if [ "$CURRENT_AM" != "tde_heap" ]; then
            enable_encryption_on_table "$TABLE"
            echo "[INFO] Converted $TABLE to tde_heap"
        else
            echo "[INFO] $TABLE already uses tde_heap"
        fi
    else
        echo "[INFO] $TABLE does not exist yet (will be encrypted by migrate-tde.sh after backend creates schema)"
    fi
done

echo "=========================================="
echo "PostgreSQL TDE Initialization Complete"
echo "=========================================="
echo ""
echo "To create encrypted tables, use:"
echo "  CREATE TABLE my_table (...) USING tde_heap;"
echo ""
echo "To encrypt existing tables, use:"
echo "  ALTER TABLE my_table SET ACCESS METHOD tde_heap;"
echo ""
echo "To verify a table is encrypted, use:"
echo "  SELECT pg_tde_is_encrypted('my_table'::regclass);"
echo ""
