#!/bin/bash
# Chronicle Disaster Recovery Script
# Guided restoration from encrypted backups.
#
# Usage:
#   ./restore-chronicle.sh <backup-directory> [encryption-key-file]
#
# Examples:
#   ./restore-chronicle.sh /opt/chronicle/backups/20260225_020000
#   ./restore-chronicle.sh /opt/chronicle/backups/20260225_020000 /path/to/backup-key
#
# This script will:
#   1. Verify backup integrity (checksums)
#   2. Decrypt and restore config/secrets
#   3. Start postgres only
#   4. Decrypt and restore database
#   5. Restore TDE keyring
#   6. Re-enable TDE encryption
#   7. Start all services
#   8. Run health checks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_KEY="/opt/chronicle/backups/.backup-encryption-key"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.traefik.yml"
CONTAINER="chronicle-postgres"
DB_USER="chronicle"
DB_NAME="chronicle"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_ok() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}OK${NC} $*"; }
log_err() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}ERROR${NC} $*" >&2; }
log_warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}WARN${NC} $*"; }
log_step() { echo -e "\n${BOLD}=== Step $1: $2 ===${NC}"; }

decrypt_file() {
    local src="$1"
    local dst="$2"
    openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 100000 \
        -in "$src" -out "$dst" -pass "file:${KEY_FILE}" 2>/dev/null
}

sha256() {
    sha256sum "$1" | awk '{print $1}'
}

confirm() {
    local msg="$1"
    echo -e "\n${YELLOW}${msg}${NC}"
    read -rp "Continue? [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# Parse arguments
BACKUP_DIR="${1:-}"
KEY_FILE="${2:-$DEFAULT_KEY}"

if [ -z "$BACKUP_DIR" ]; then
    echo "Usage: $0 <backup-directory> [encryption-key-file]"
    echo ""
    echo "Available backups:"
    ls -d /opt/chronicle/backups/[0-9]*_[0-9]* 2>/dev/null | sort -r | while read -r d; do
        echo "  $(basename "$d")"
    done
    exit 1
fi

if [ ! -d "$BACKUP_DIR" ]; then
    log_err "Backup directory not found: $BACKUP_DIR"
    exit 1
fi

if [ ! -f "$KEY_FILE" ]; then
    log_err "Encryption key not found: $KEY_FILE"
    exit 1
fi

echo ""
echo -e "${BOLD}=========================================="
echo "Chronicle Disaster Recovery"
echo -e "==========================================${NC}"
echo ""
echo "  Backup: $(basename "$BACKUP_DIR")"
echo "  Key:    $KEY_FILE"
echo ""

# Show manifest info
if [ -f "${BACKUP_DIR}/manifest.json" ]; then
    echo "  Manifest:"
    cat "${BACKUP_DIR}/manifest.json" | sed 's/^/    /'
    echo ""
fi

# ================================================================
log_step 1 "Verify backup integrity"
# ================================================================

ERRORS=0
for F in "${BACKUP_DIR}"/*.enc; do
    [ -f "$F" ] || continue
    FNAME=$(basename "$F")
    ACTUAL=$(sha256 "$F")
    EXPECTED=$(grep -o "\"${FNAME}\":\"[a-f0-9]*\"" "${BACKUP_DIR}/manifest.json" 2>/dev/null | cut -d'"' -f4)
    if [ -n "$EXPECTED" ] && [ "$ACTUAL" = "$EXPECTED" ]; then
        log_ok "${FNAME} checksum OK"
    elif [ -z "$EXPECTED" ]; then
        log_warn "${FNAME} not in manifest (skipping checksum)"
    else
        log_err "${FNAME} checksum MISMATCH"
        ERRORS=$((ERRORS + 1))
    fi
done

if [ "$ERRORS" -gt 0 ]; then
    log_err "Backup integrity check failed with $ERRORS errors"
    exit 1
fi
log_ok "All checksums verified"

# ================================================================
log_step 2 "Restore config and secrets"
# ================================================================

if [ -f "${BACKUP_DIR}/config-secrets.tar.gz.enc" ]; then
    CONFIG_TMP=$(mktemp)
    decrypt_file "${BACKUP_DIR}/config-secrets.tar.gz.enc" "$CONFIG_TMP"

    if confirm "This will overwrite .env, rhizome-docker.yaml, auth0.yaml, and postgres-ssl/ in ${SCRIPT_DIR}"; then
        tar -xzf "$CONFIG_TMP" -C "$SCRIPT_DIR"
        log_ok "Config and secrets restored to ${SCRIPT_DIR}"
    else
        log_warn "Skipped config restore (using existing config files)"
    fi
    rm -f "$CONFIG_TMP"
else
    log_warn "config-secrets.tar.gz.enc not found in backup"
fi

# ================================================================
log_step 3 "Stop all services and start postgres only"
# ================================================================

if confirm "This will stop all Chronicle services and drop/recreate the database"; then
    log "Stopping all services..."
    docker compose -p chronicle -f "$COMPOSE_FILE" down 2>/dev/null || true

    log "Starting postgres only..."
    docker compose -p chronicle -f "$COMPOSE_FILE" up -d postgres
    log "Waiting for postgres to be healthy..."
    for i in $(seq 1 30); do
        if docker exec "$CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
            log_ok "PostgreSQL is ready"
            break
        fi
        if [ "$i" -eq 30 ]; then
            log_err "PostgreSQL did not become ready in time"
            exit 1
        fi
        sleep 2
    done
else
    log_err "Recovery cancelled"
    exit 1
fi

# ================================================================
log_step 4 "Restore database"
# ================================================================

log "Decrypting database dump..."
DUMP_TMP=$(mktemp)
decrypt_file "${BACKUP_DIR}/database.dump.enc" "$DUMP_TMP"

log "Dropping and recreating database..."
docker exec "$CONTAINER" psql -U "$DB_USER" -d postgres -c "
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();
    DROP DATABASE IF EXISTS ${DB_NAME};
    CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
" 2>&1

log "Restoring database from dump..."
docker cp "$DUMP_TMP" "${CONTAINER}:/tmp/restore.dump"
docker exec "$CONTAINER" pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner --no-acl /tmp/restore.dump 2>&1 || true
docker exec "$CONTAINER" rm -f /tmp/restore.dump
rm -f "$DUMP_TMP"

TABLE_COUNT=$(docker exec "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -A \
    -c "SELECT COUNT(*) FROM pg_class WHERE relkind='r' AND relnamespace=(SELECT oid FROM pg_namespace WHERE nspname='public');" 2>/dev/null)
log_ok "Database restored (${TABLE_COUNT} tables)"

# ================================================================
log_step 5 "Restore TDE keyring"
# ================================================================

if [ -f "${BACKUP_DIR}/tde-keyring.tar.gz.enc" ]; then
    log "Decrypting TDE keyring..."
    KEYRING_TMP=$(mktemp)
    decrypt_file "${BACKUP_DIR}/tde-keyring.tar.gz.enc" "$KEYRING_TMP"

    docker cp "$KEYRING_TMP" "${CONTAINER}:/tmp/tde-keyring.tar.gz"
    docker exec -u root "$CONTAINER" sh -c "
        rm -rf /var/lib/postgresql/tde-keyring/*
        tar -xzf /tmp/tde-keyring.tar.gz -C /var/lib/postgresql/
        chown -R postgres:postgres /var/lib/postgresql/tde-keyring
        chmod 700 /var/lib/postgresql/tde-keyring
        rm -f /tmp/tde-keyring.tar.gz
    "
    rm -f "$KEYRING_TMP"
    log_ok "TDE keyring restored"
else
    log_warn "tde-keyring.tar.gz.enc not found — TDE keys may be lost"
fi

# ================================================================
log_step 6 "Re-enable TDE encryption"
# ================================================================

log "Running TDE migration..."
if [ -x "${SCRIPT_DIR}/migrate-tde.sh" ]; then
    "${SCRIPT_DIR}/migrate-tde.sh"
    log_ok "TDE migration complete"
else
    log_warn "migrate-tde.sh not found or not executable"
    log_warn "Run manually: ./migrate-tde.sh"
fi

# ================================================================
log_step 7 "Start all services"
# ================================================================

log "Starting all Chronicle services..."
docker compose -p chronicle -f "$COMPOSE_FILE" up -d
log "Waiting for services to start..."
sleep 15

# ================================================================
log_step 8 "Health checks"
# ================================================================

HEALTH_OK=true

# Check postgres
if docker exec "$CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
    log_ok "PostgreSQL is healthy"
else
    log_err "PostgreSQL is not healthy"
    HEALTH_OK=false
fi

# Check backend
BACKEND_RUNNING=$(docker inspect chronicle-backend --format='{{.State.Running}}' 2>/dev/null || echo "false")
if [ "$BACKEND_RUNNING" = "true" ]; then
    log_ok "Backend is running"
else
    log_err "Backend is not running"
    HEALTH_OK=false
fi

# Check TDE
TDE_COUNT=$(docker exec "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -A \
    -c "SELECT COUNT(*) FROM pg_class c JOIN pg_am am ON c.relam=am.oid WHERE c.relkind='r' AND am.amname='tde_heap' AND c.relnamespace=(SELECT oid FROM pg_namespace WHERE nspname='public');" 2>/dev/null || echo "0")
if [ "$TDE_COUNT" -gt 0 ]; then
    log_ok "${TDE_COUNT} tables encrypted with TDE"
else
    log_warn "No tables encrypted — run migrate-tde.sh"
fi

echo ""
echo -e "${BOLD}=========================================="
if [ "$HEALTH_OK" = true ]; then
    echo -e "${GREEN}Recovery Complete${NC}"
else
    echo -e "${RED}Recovery completed with issues — check logs above${NC}"
fi
echo -e "${BOLD}==========================================${NC}"
echo ""

# Restore audit logs if present
if [ -f "${BACKUP_DIR}/audit-logs.tar.gz.enc" ]; then
    log "Note: Audit logs backup exists at ${BACKUP_DIR}/audit-logs.tar.gz.enc"
    log "  To restore: decrypt and extract to the audit_logs volume"
fi
