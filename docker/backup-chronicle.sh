#!/bin/bash
# Chronicle Backup Script
# Automated, encrypted backups of database, TDE keyring, config/secrets, and audit logs.
#
# Usage:
#   ./backup-chronicle.sh [--full|--verify|--list|--prune]
#     --full    (default) Create a full encrypted backup
#     --verify  Decrypt and validate the latest backup
#     --list    List all backup directories with retention tags
#     --prune   Remove old backups per retention policy
#
# Cron setup:
#   0 2 * * *   /opt/chronicle/docker/backup-chronicle.sh >> /var/log/chronicle-backup.log 2>&1
#   0 3 * * 0   /opt/chronicle/docker/backup-chronicle.sh --verify >> /var/log/chronicle-backup.log 2>&1
#
# Retention: 7 daily, 4 weekly (Sunday), 3 monthly (1st of month)

set -euo pipefail

# Cleanup temp files on exit (especially important for unencrypted dumps)
TEMP_FILES=()
cleanup() { rm -f "${TEMP_FILES[@]}"; }
trap cleanup EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_ROOT="/opt/chronicle/backups"
# H-10: Store encryption key OUTSIDE the backup directory.
# Default location: /etc/chronicle/backup-encryption-key (root-only readable)
# Falls back to legacy location for backward compatibility.
KEY_FILE="${CHRONICLE_BACKUP_KEY:-/etc/chronicle/backup-encryption-key}"
CONTAINER="chronicle-postgres"
BACKEND_CONTAINER="chronicle-backend"
DB_USER="chronicle"
DB_NAME="chronicle"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.traefik.yml"

# Retention policy
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=3

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_ok() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}OK${NC} $*"; }
log_err() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}ERROR${NC} $*" >&2; }
log_warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}WARN${NC} $*"; }

# Legacy key location fallback (must be after function definitions)
if [ ! -f "$KEY_FILE" ] && [ -f "${BACKUP_ROOT}/.backup-encryption-key" ]; then
    log_warn "Backup key found in legacy location alongside backups. Move it:"
    log_warn "  sudo mkdir -p /etc/chronicle && sudo mv ${BACKUP_ROOT}/.backup-encryption-key /etc/chronicle/backup-encryption-key && sudo chmod 600 /etc/chronicle/backup-encryption-key"
    KEY_FILE="${BACKUP_ROOT}/.backup-encryption-key"
fi

check_prereqs() {
    if [ ! -f "$KEY_FILE" ]; then
        log_err "Backup encryption key not found: $KEY_FILE"
        log_err "Generate with: openssl rand -base64 64 > $KEY_FILE && chmod 600 $KEY_FILE"
        exit 1
    fi

    if ! docker inspect "$CONTAINER" --format='{{.State.Running}}' 2>/dev/null | grep -q true; then
        log_err "PostgreSQL container '$CONTAINER' is not running"
        exit 1
    fi
}

encrypt_file() {
    local src="$1"
    local dst="$2"
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -in "$src" -out "$dst" -pass "file:${KEY_FILE}"
}

decrypt_file() {
    local src="$1"
    local dst="$2"
    openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 100000 \
        -in "$src" -out "$dst" -pass "file:${KEY_FILE}"
}

sha256() {
    sha256sum "$1" | awk '{print $1}'
}

do_full_backup() {
    check_prereqs

    TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
    BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
    mkdir -p "$BACKUP_DIR"

    log "Starting full backup to ${BACKUP_DIR}"

    # 1. Database dump
    log "  Dumping database..."
    DUMP_TMP=$(mktemp); TEMP_FILES+=("$DUMP_TMP")
    docker exec "$CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc -Z6 > "$DUMP_TMP"
    encrypt_file "$DUMP_TMP" "${BACKUP_DIR}/database.dump.enc"
    rm -f "$DUMP_TMP"
    log_ok "database.dump.enc ($(du -h "${BACKUP_DIR}/database.dump.enc" | cut -f1))"

    # 2. TDE keyring
    log "  Backing up TDE keyring..."
    KEYRING_TMP=$(mktemp); TEMP_FILES+=("$KEYRING_TMP")
    docker exec "$CONTAINER" tar -czf - -C /var/lib/postgresql tde-keyring > "$KEYRING_TMP"
    encrypt_file "$KEYRING_TMP" "${BACKUP_DIR}/tde-keyring.tar.gz.enc"
    rm -f "$KEYRING_TMP"
    log_ok "tde-keyring.tar.gz.enc"

    # 3. Config/secrets
    log "  Backing up config and secrets..."
    for CONF_FILE in .env rhizome-docker.yaml auth0.yaml; do
        if [ ! -f "${SCRIPT_DIR}/${CONF_FILE}" ]; then
            log_err "Required config file missing: ${SCRIPT_DIR}/${CONF_FILE}"
            exit 1
        fi
    done
    CONFIG_TMP=$(mktemp); TEMP_FILES+=("$CONFIG_TMP")
    tar -czf "$CONFIG_TMP" \
        -C "$SCRIPT_DIR" \
        .env \
        rhizome-docker.yaml \
        auth0.yaml \
        postgres-ssl/
    encrypt_file "$CONFIG_TMP" "${BACKUP_DIR}/config-secrets.tar.gz.enc"
    rm -f "$CONFIG_TMP"
    log_ok "config-secrets.tar.gz.enc"

    # 4. Audit logs (from backend container, if running)
    log "  Backing up audit logs..."
    if docker inspect "$BACKEND_CONTAINER" --format='{{.State.Running}}' 2>/dev/null | grep -q true; then
        AUDIT_TMP=$(mktemp); TEMP_FILES+=("$AUDIT_TMP")
        if docker exec "$BACKEND_CONTAINER" tar -czf - -C /var/log chronicle > "$AUDIT_TMP" 2>&1; then
            if [ -s "$AUDIT_TMP" ]; then
                encrypt_file "$AUDIT_TMP" "${BACKUP_DIR}/audit-logs.tar.gz.enc"
                log_ok "audit-logs.tar.gz.enc"
            else
                log_warn "No audit logs found (empty archive)"
            fi
        else
            log_warn "Failed to backup audit logs (tar exit $?), continuing"
        fi
        rm -f "$AUDIT_TMP"
    else
        log_warn "Backend container not running, skipping audit logs"
    fi

    # 5. Manifest
    log "  Creating manifest..."

    DB_SIZE=$(docker exec "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -A \
        -c "SELECT pg_size_pretty(pg_database_size('${DB_NAME}'));" 2>/dev/null || echo "unknown")
    TABLE_COUNT=$(docker exec "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -A \
        -c "SELECT COUNT(*) FROM pg_class WHERE relkind='r' AND relnamespace=(SELECT oid FROM pg_namespace WHERE nspname='public');" 2>/dev/null || echo "0")
    TDE_COUNT=$(docker exec "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -A \
        -c "SELECT COUNT(*) FROM pg_class c JOIN pg_am am ON c.relam=am.oid WHERE c.relkind='r' AND am.amname='tde_heap' AND c.relnamespace=(SELECT oid FROM pg_namespace WHERE nspname='public');" 2>/dev/null || echo "0")

    # Build checksums
    CHECKSUMS="{"
    for F in "${BACKUP_DIR}"/*.enc; do
        [ -f "$F" ] || continue
        FNAME=$(basename "$F")
        HASH=$(sha256 "$F")
        CHECKSUMS="${CHECKSUMS}\"${FNAME}\":\"${HASH}\","
    done
    CHECKSUMS="${CHECKSUMS%,}}"

    # Retention tags
    DAY_OF_WEEK=$(date '+%u')  # 7=Sunday
    DAY_OF_MONTH=$(date '+%d')
    TAGS="[\"daily\""
    [ "$DAY_OF_WEEK" = "7" ] && TAGS="${TAGS},\"weekly\""
    [ "$DAY_OF_MONTH" = "01" ] && TAGS="${TAGS},\"monthly\""
    TAGS="${TAGS}]"

    cat > "${BACKUP_DIR}/manifest.json" <<MANIFEST
{
    "timestamp": "$(date -Iseconds)",
    "backup_dir": "${TIMESTAMP}",
    "database_size": "${DB_SIZE}",
    "table_count": ${TABLE_COUNT},
    "tde_encrypted_tables": ${TDE_COUNT},
    "retention_tags": ${TAGS},
    "checksums": ${CHECKSUMS}
}
MANIFEST

    log_ok "manifest.json"

    # Set permissions
    chmod 700 "$BACKUP_DIR"
    chmod 600 "${BACKUP_DIR}"/*

    log ""
    log "Backup complete: ${BACKUP_DIR}"
    log "  Database: ${DB_SIZE}, ${TABLE_COUNT} tables (${TDE_COUNT} encrypted)"
    log "  Retention: ${TAGS}"

    # Auto-prune after backup
    do_prune
}

do_verify() {
    check_prereqs

    # Find latest backup
    LATEST=$(ls -d "${BACKUP_ROOT}"/[0-9]*_[0-9]* 2>/dev/null | sort -r | head -1)
    if [ -z "$LATEST" ]; then
        log_err "No backups found in ${BACKUP_ROOT}"
        exit 1
    fi

    log "Verifying backup: $(basename "$LATEST")"
    ERRORS=0

    # Check manifest exists
    if [ ! -f "${LATEST}/manifest.json" ]; then
        log_err "manifest.json missing"
        exit 1
    fi
    log_ok "manifest.json present"

    # Verify checksums
    log "  Verifying checksums..."
    for F in "${LATEST}"/*.enc; do
        [ -f "$F" ] || continue
        FNAME=$(basename "$F")
        ACTUAL_HASH=$(sha256 "$F")
        # Extract expected hash from manifest (simple grep approach)
        EXPECTED_HASH=$(grep -o "\"${FNAME}\":\"[a-f0-9]*\"" "${LATEST}/manifest.json" | cut -d'"' -f4)
        if [ "$ACTUAL_HASH" = "$EXPECTED_HASH" ]; then
            log_ok "  ${FNAME} checksum matches"
        else
            log_err "  ${FNAME} checksum MISMATCH"
            ERRORS=$((ERRORS + 1))
        fi
    done

    # Decrypt and validate database dump (use pg_restore inside container)
    log "  Validating database dump..."
    DUMP_TMP=$(mktemp)
    if decrypt_file "${LATEST}/database.dump.enc" "$DUMP_TMP"; then
        docker cp "$DUMP_TMP" "${CONTAINER}:/tmp/verify.dump" 2>/dev/null
        docker exec -u root "$CONTAINER" chmod 644 /tmp/verify.dump 2>/dev/null
        TABLE_LIST=$(docker exec "$CONTAINER" pg_restore --list /tmp/verify.dump 2>/dev/null | grep -c "TABLE " || true)
        docker exec -u root "$CONTAINER" rm -f /tmp/verify.dump 2>/dev/null
        if [ "$TABLE_LIST" -gt 0 ]; then
            log_ok "  database.dump.enc decrypts OK (${TABLE_LIST} table entries)"
        else
            log_err "  database.dump.enc decrypted but pg_restore --list found no tables"
            ERRORS=$((ERRORS + 1))
        fi
    else
        log_err "  database.dump.enc decryption FAILED"
        ERRORS=$((ERRORS + 1))
    fi
    rm -f "$DUMP_TMP"

    # Decrypt and validate TDE keyring
    log "  Validating TDE keyring archive..."
    KEYRING_TMP=$(mktemp)
    if decrypt_file "${LATEST}/tde-keyring.tar.gz.enc" "$KEYRING_TMP"; then
        if tar -tzf "$KEYRING_TMP" >/dev/null 2>&1; then
            FILE_COUNT=$(tar -tzf "$KEYRING_TMP" 2>/dev/null | wc -l)
            log_ok "  tde-keyring.tar.gz.enc decrypts OK (${FILE_COUNT} entries)"
        else
            log_err "  tde-keyring.tar.gz.enc decrypted but tar is invalid"
            ERRORS=$((ERRORS + 1))
        fi
    else
        log_err "  tde-keyring.tar.gz.enc decryption FAILED"
        ERRORS=$((ERRORS + 1))
    fi
    rm -f "$KEYRING_TMP"

    echo ""
    if [ "$ERRORS" -eq 0 ]; then
        log_ok "Backup verification PASSED"
    else
        log_err "Backup verification FAILED ($ERRORS errors)"
        exit 1
    fi
}

do_list() {
    log "Backups in ${BACKUP_ROOT}:"
    echo ""
    printf "%-20s %-10s %-8s %-8s %s\n" "DIRECTORY" "DB SIZE" "TABLES" "TDE" "TAGS"
    printf "%-20s %-10s %-8s %-8s %s\n" "---------" "-------" "------" "---" "----"

    for DIR in $(ls -d "${BACKUP_ROOT}"/[0-9]*_[0-9]* 2>/dev/null | sort -r); do
        MANIFEST="${DIR}/manifest.json"
        if [ -f "$MANIFEST" ]; then
            DIRNAME=$(basename "$DIR")
            DB_SIZE=$(grep -o '"database_size"[[:space:]]*:[[:space:]]*"[^"]*"' "$MANIFEST" | cut -d'"' -f4)
            TABLES=$(grep -o '"table_count"[[:space:]]*:[[:space:]]*[0-9]*' "$MANIFEST" | grep -o '[0-9]*$')
            TDE=$(grep -o '"tde_encrypted_tables"[[:space:]]*:[[:space:]]*[0-9]*' "$MANIFEST" | grep -o '[0-9]*$')
            TAGS=$(grep -o '"retention_tags"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$MANIFEST" | sed 's/.*\[//;s/\]//;s/"//g')
            printf "%-20s %-10s %-8s %-8s %s\n" "$DIRNAME" "$DB_SIZE" "$TABLES" "$TDE" "$TAGS"
        fi
    done
    echo ""
}

do_prune() {
    log "Pruning old backups (keep: ${KEEP_DAILY}d, ${KEEP_WEEKLY}w, ${KEEP_MONTHLY}m)..."

    # Get all backup directories sorted newest first
    DIRS=($(ls -d "${BACKUP_ROOT}"/[0-9]*_[0-9]* 2>/dev/null | sort -r))
    TOTAL=${#DIRS[@]}

    if [ "$TOTAL" -eq 0 ]; then
        log "  No backups to prune"
        return
    fi

    DAILY_KEPT=0
    WEEKLY_KEPT=0
    MONTHLY_KEPT=0
    REMOVED=0

    for DIR in "${DIRS[@]}"; do
        MANIFEST="${DIR}/manifest.json"
        KEEP=false

        if [ -f "$MANIFEST" ]; then
            TAGS=$(grep -o '"retention_tags"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$MANIFEST" 2>/dev/null || echo "")

            # Check monthly tag
            if echo "$TAGS" | grep -q "monthly" && [ "$MONTHLY_KEPT" -lt "$KEEP_MONTHLY" ]; then
                KEEP=true
                MONTHLY_KEPT=$((MONTHLY_KEPT + 1))
            fi

            # Check weekly tag
            if echo "$TAGS" | grep -q "weekly" && [ "$WEEKLY_KEPT" -lt "$KEEP_WEEKLY" ]; then
                KEEP=true
                WEEKLY_KEPT=$((WEEKLY_KEPT + 1))
            fi

            # Daily: keep N most recent
            if [ "$DAILY_KEPT" -lt "$KEEP_DAILY" ]; then
                KEEP=true
                DAILY_KEPT=$((DAILY_KEPT + 1))
            fi
        else
            # No manifest — keep if within daily limit
            if [ "$DAILY_KEPT" -lt "$KEEP_DAILY" ]; then
                KEEP=true
                DAILY_KEPT=$((DAILY_KEPT + 1))
            fi
        fi

        if [ "$KEEP" = false ]; then
            log "  Removing: $(basename "$DIR")"
            rm -rf "$DIR"
            REMOVED=$((REMOVED + 1))
        fi
    done

    log "  Pruned $REMOVED of $TOTAL backups"
}

# Main
MODE="${1:---full}"

case "$MODE" in
    --full)
        do_full_backup
        ;;
    --verify)
        do_verify
        ;;
    --list)
        do_list
        ;;
    --prune)
        do_prune
        ;;
    *)
        echo "Usage: $0 [--full|--verify|--list|--prune]"
        exit 1
        ;;
esac
