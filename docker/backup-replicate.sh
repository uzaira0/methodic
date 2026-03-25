#!/bin/bash
# backup-replicate.sh — Replicate encrypted backups to off-site storage
#
# Supports: rsync (SSH), S3-compatible (MinIO/AWS), local directory
#
# Usage:
#   ./backup-replicate.sh [--target rsync|s3|local]
#
# Configuration via environment or .env:
#   BACKUP_REMOTE_TYPE=rsync|s3|local
#   BACKUP_REMOTE_RSYNC=user@host:/path/to/backups
#   BACKUP_REMOTE_S3_BUCKET=s3://bucket-name/chronicle-backups
#   BACKUP_REMOTE_S3_ENDPOINT=https://s3.amazonaws.com  (or MinIO URL)
#   BACKUP_REMOTE_LOCAL=/mnt/nfs/chronicle-backups
#
# Cron: Run after backup completes
#   0 3 * * *   /opt/chronicle/docker/backup-replicate.sh >> /var/log/chronicle-backup-replicate.log 2>&1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_ROOT="/opt/chronicle/backups"

# Load config
if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
fi

REMOTE_TYPE="${BACKUP_REMOTE_TYPE:-}"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_ok() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}OK${NC} $*"; }
log_err() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}ERROR${NC} $*" >&2; }
log_warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}WARN${NC} $*"; }

check_source_not_empty() {
    local file_count
    file_count=$(find "${BACKUP_ROOT}" -maxdepth 2 -name '*.enc' 2>/dev/null | wc -l)
    if [ "$file_count" -lt 1 ]; then
        log_err "Source directory has no backup files — refusing to sync with --delete (would destroy remote backups)"
        exit 1
    fi
    log "Found ${file_count} encrypted backup files in source"
}

replicate_rsync() {
    local target="${BACKUP_REMOTE_RSYNC:?Set BACKUP_REMOTE_RSYNC in .env}"
    check_source_not_empty
    log "Replicating to rsync target: ${target}"
    rsync -avz --delete \
        --exclude='.backup-encryption-key' \
        "${BACKUP_ROOT}/" "${target}/"
    log_ok "rsync replication complete"
}

replicate_s3() {
    local bucket="${BACKUP_REMOTE_S3_BUCKET:?Set BACKUP_REMOTE_S3_BUCKET in .env}"
    local endpoint="${BACKUP_REMOTE_S3_ENDPOINT:-https://s3.amazonaws.com}"

    if ! command -v aws &>/dev/null; then
        log_err "AWS CLI not installed. Install with: pip install awscli"
        exit 1
    fi

    log "Replicating to S3: ${bucket}"
    aws s3 sync "${BACKUP_ROOT}/" "${bucket}/" \
        --endpoint-url "${endpoint}" \
        --exclude ".backup-encryption-key" \
        --storage-class STANDARD_IA
    log_ok "S3 replication complete"
}

replicate_local() {
    local target="${BACKUP_REMOTE_LOCAL:?Set BACKUP_REMOTE_LOCAL in .env}"
    if [ ! -d "$target" ]; then
        log_err "Local replication target does not exist: ${target}"
        exit 1
    fi

    check_source_not_empty
    log "Replicating to local path: ${target}"
    rsync -av --delete \
        --exclude='.backup-encryption-key' \
        "${BACKUP_ROOT}/" "${target}/"
    log_ok "Local replication complete"
}

# Parse args
TARGET="${1:-}"
if [ "$TARGET" = "--target" ]; then
    REMOTE_TYPE="${2:-${REMOTE_TYPE}}"
fi

if [ -z "$REMOTE_TYPE" ]; then
    log_err "No replication target configured."
    log_err "Set BACKUP_REMOTE_TYPE in .env to: rsync, s3, or local"
    log_err "  rsync: set BACKUP_REMOTE_RSYNC=user@host:/path"
    log_err "  s3:    set BACKUP_REMOTE_S3_BUCKET=s3://bucket and optionally BACKUP_REMOTE_S3_ENDPOINT"
    log_err "  local: set BACKUP_REMOTE_LOCAL=/mnt/nfs/path"
    exit 1
fi

case "$REMOTE_TYPE" in
    rsync) replicate_rsync ;;
    s3)    replicate_s3 ;;
    local) replicate_local ;;
    *)
        log_err "Unknown replication type: ${REMOTE_TYPE}"
        log_err "Supported: rsync, s3, local"
        exit 1
        ;;
esac
