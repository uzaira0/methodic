#!/bin/bash
# rotate-secrets.sh — Automated secret rotation for Chronicle
#
# Usage:
#   ./rotate-secrets.sh jwt          # Rotate JWT_SECRET and regenerate tokens
#   ./rotate-secrets.sh db           # Rotate database password
#   ./rotate-secrets.sh grafana      # Rotate Grafana admin password
#   ./rotate-secrets.sh hazelcast    # Rotate Hazelcast passwords
#   ./rotate-secrets.sh all          # Rotate all secrets
#   ./rotate-secrets.sh --dry-run X  # Show what would change without doing it
#
# HIPAA §164.312(a)(2)(i) — Unique user identification
# HIPAA §164.312(d) — Authentication controls

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
DRY_RUN=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_ok() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}OK${NC} $*"; }
log_err() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}ERROR${NC} $*" >&2; }
log_warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}WARN${NC} $*"; }

generate_secret() {
    openssl rand -base64 64 | tr -d '\n'
}

generate_password() {
    openssl rand -base64 32 | tr -d '\n'
}

update_env() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

backup_env() {
    local backup="${ENV_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$ENV_FILE" "$backup"
    chmod 600 "$backup"
    log "Backed up .env to ${backup}"
}

rotate_jwt() {
    log "Rotating JWT_SECRET..."
    if [ "$DRY_RUN" = true ]; then
        log_warn "[DRY RUN] Would generate new JWT_SECRET and regenerate config.json"
        return
    fi

    backup_env
    local new_secret
    new_secret=$(generate_secret)
    update_env "JWT_SECRET" "$new_secret"

    # Regenerate JWT token
    JWT_SECRET="$new_secret" "${SCRIPT_DIR}/generate-jwt.sh" --write-config

    log_warn "JWT_SECRET rotated. You MUST restart chronicle-backend and chronicle-frontend:"
    log_warn "  docker compose -f docker-compose.traefik.yml -p chronicle restart chronicle-backend chronicle-frontend"
    log_warn "  All existing tokens are now invalid. Users must re-authenticate."
    log_ok "JWT_SECRET rotation complete"
}

rotate_db() {
    log "Rotating database password..."
    if [ "$DRY_RUN" = true ]; then
        log_warn "[DRY RUN] Would generate new POSTGRES_PASSWORD and ALTER USER"
        return
    fi

    backup_env
    local new_password
    new_password=$(generate_password)

    # Get current user from .env
    local db_user
    db_user=$(grep '^POSTGRES_USER=' "$ENV_FILE" | cut -d= -f2-)

    # Update .env first (reversible via backup), then change DB password.
    # If DB ALTER fails, restore .env from backup so they stay in sync.
    update_env "POSTGRES_PASSWORD" "$new_password"

    # Get current password to authenticate, then change it
    local old_password
    old_password=$(grep '^POSTGRES_PASSWORD=' "${ENV_FILE}.bak."* 2>/dev/null | tail -1 | cut -d= -f2-)
    if ! docker exec -e PGPASSWORD="$old_password" -e NEW_PW="$new_password" chronicle-postgres \
        sh -c "psql -h 127.0.0.1 -U $db_user -d chronicle -c \"ALTER USER $db_user WITH PASSWORD '\$NEW_PW';\""; then
        log_err "ALTER USER failed — restoring .env from backup"
        local latest_backup
        latest_backup=$(ls -t "${ENV_FILE}".bak.* 2>/dev/null | head -1)
        if [ -n "$latest_backup" ]; then
            cp "$latest_backup" "$ENV_FILE"
            log_err "Restored .env from ${latest_backup}"
        fi
        return 1
    fi

    log_warn "Database password rotated. Restart chronicle-backend:"
    log_warn "  docker compose -f docker-compose.traefik.yml -p chronicle restart chronicle-backend"
    log_ok "Database password rotation complete"
}

rotate_grafana() {
    log "Rotating Grafana admin password..."
    if [ "$DRY_RUN" = true ]; then
        log_warn "[DRY RUN] Would generate new GRAFANA_ADMIN_PASSWORD"
        return
    fi

    backup_env
    local new_password
    new_password=$(generate_password)
    update_env "GRAFANA_ADMIN_PASSWORD" "$new_password"

    # Update in running Grafana (if container is running)
    if docker exec chronicle-grafana grafana-cli admin reset-admin-password "$new_password" 2>/dev/null; then
        log_ok "Grafana live instance updated"
    else
        log_warn "Grafana container not running or update failed — .env updated, restart container to apply"
    fi

    log_warn "Grafana password rotated. New password is in .env"
    log_ok "Grafana password rotation complete"
}

rotate_hazelcast() {
    log "Rotating Hazelcast passwords..."
    if [ "$DRY_RUN" = true ]; then
        log_warn "[DRY RUN] Would generate new HAZELCAST_SERVER_PASSWORD and HAZELCAST_CLIENT_PASSWORD"
        return
    fi

    backup_env
    update_env "HAZELCAST_SERVER_PASSWORD" "$(generate_password)"
    update_env "HAZELCAST_CLIENT_PASSWORD" "$(generate_password)"

    log_warn "Hazelcast passwords rotated. Restart chronicle-backend:"
    log_warn "  docker compose -f docker-compose.traefik.yml -p chronicle restart chronicle-backend"
    log_ok "Hazelcast password rotation complete"
}

rotate_crowdsec() {
    log "Rotating CrowdSec bouncer API key..."
    if [ "$DRY_RUN" = true ]; then
        log_warn "[DRY RUN] Would delete and recreate CrowdSec bouncer"
        return
    fi

    backup_env

    if ! docker ps --filter name=chronicle-crowdsec --format '{{.Names}}' 2>/dev/null | grep -q chronicle-crowdsec; then
        log_err "CrowdSec container not running — cannot rotate bouncer key"
        return 1
    fi

    # Delete old bouncer and create new one
    docker exec chronicle-crowdsec cscli bouncers delete traefik-bouncer 2>/dev/null || true
    local new_key
    new_key=$(docker exec chronicle-crowdsec cscli bouncers add traefik-bouncer -o raw 2>/dev/null)

    if [ -z "$new_key" ]; then
        log_err "Failed to generate new CrowdSec bouncer key"
        return 1
    fi

    update_env "CROWDSEC_BOUNCER_API_KEY" "$new_key"

    log_warn "CrowdSec bouncer key rotated. Restart Traefik:"
    log_warn "  docker compose -f docker-compose.traefik.yml -p chronicle restart traefik"
    log_ok "CrowdSec bouncer key rotation complete"
}

# Parse args
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=true
    shift
fi

TARGET="${1:-}"

case "$TARGET" in
    jwt)       rotate_jwt ;;
    db)        rotate_db ;;
    grafana)   rotate_grafana ;;
    hazelcast) rotate_hazelcast ;;
    crowdsec)  rotate_crowdsec ;;
    all)
        rotate_jwt
        rotate_db
        rotate_grafana
        rotate_hazelcast
        rotate_crowdsec
        log ""
        log_warn "ALL secrets rotated. Full restart required:"
        log_warn "  docker compose -f docker-compose.traefik.yml -p chronicle restart"
        ;;
    *)
        echo "Usage: $0 [--dry-run] <jwt|db|grafana|hazelcast|crowdsec|all>"
        exit 1
        ;;
esac
