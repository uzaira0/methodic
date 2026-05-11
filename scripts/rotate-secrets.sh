#!/usr/bin/env bash
# rotate-secrets.sh — Comprehensive secret rotation for Chronicle production
#
# Rotates all secrets in docker/.env and restarts affected services in the
# correct dependency order.
#
# Usage:
#   ./scripts/rotate-secrets.sh                # interactive — prompts before each step
#   ./scripts/rotate-secrets.sh --auto         # non-interactive — rotates everything
#   ./scripts/rotate-secrets.sh --dry-run      # show what would change, touch nothing
#   ./scripts/rotate-secrets.sh --only <name>  # rotate a single secret by env var name
#
# Secrets that CANNOT be auto-rotated (require external coordination):
#   MOBILE_APP_KEY        — embedded in the Android APK; rotating requires a new app release
#   MOBILE_SIGNING_SECRET — shared with the Android APK signing process
#   PG_TDE_VAULT_TOKEN    — issued by external Vault cluster
#   SMTP_PASSWORD         — managed by the email provider (Office 365 admin)
#
# Pre-requisites:
#   - openssl, docker, docker compose
#   - Run from the repository root (or the script's parent dir)
#   - The docker stack must be running for service-level rotations (Postgres, CrowdSec, Grafana)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/docker/.env"
COMPOSE_FILE="$REPO_ROOT/docker/docker-compose.traefik.yml"
BACKUP_DIR="$REPO_ROOT/docker/.env-backups"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

DRY_RUN=false
AUTO=false
ONLY=""

# ── Argument parsing ────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --auto)    AUTO=true; shift ;;
    --only)    ONLY="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ─────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[rotate]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n'   "$*" >&2; }
err()  { printf '\033[1;31m[error]\033[0m %s\n'   "$*" >&2; exit 1; }

gen_b64()  { openssl rand -base64 "${1:-32}" | tr -d '\n'; }
gen_hex()  { openssl rand -hex "${1:-32}" | tr -d '\n'; }

confirm() {
  if $AUTO; then return 0; fi
  if [[ ! -t 0 ]]; then
    err "Non-interactive stdin detected. Use --auto for unattended rotation or run from a terminal."
  fi
  printf '\033[1;33m%s [y/N] \033[0m' "$1"
  read -r ans
  [[ "$ans" =~ ^[Yy] ]]
}

# Escape sed replacement strings (handles / & \ and the | delimiter)
sed_escape() { printf '%s' "$1" | sed 's/[&/\|]/\\&/g'; }

# Read current value of an env var from the .env file
env_val() { grep -E "^${1}=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

# Replace a value in .env (in-place) with verification
env_set() {
  local key="$1" new="$2"
  if $DRY_RUN; then
    log "[dry-run] Would set $key=<redacted, ${#new} chars>"
    return
  fi
  local escaped
  escaped="$(sed_escape "$new")"
  sed -i "s|^${key}=.*|${key}=${escaped}|" "$ENV_FILE" \
    || err "sed failed writing $key to $ENV_FILE — check file permissions and disk space"
  grep -qE "^${key}=" "$ENV_FILE" \
    || err "$key not found in $ENV_FILE after write — file may be corrupted"
  log "Rotated $key (${#new} chars)"
}

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

# ── Pre-flight ──────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || err "$ENV_FILE not found — run from the repository root"

if ! $DRY_RUN; then
  mkdir -p "$BACKUP_DIR"
  cp "$ENV_FILE" "$BACKUP_DIR/.env.$TIMESTAMP"
  log "Backed up .env → $BACKUP_DIR/.env.$TIMESTAMP"
fi

# Track which services need restart (keyed by docker compose SERVICE name)
declare -A RESTART_NEEDED

# ── Individual rotation functions ───────────────────────────────────

rotate_postgres_password() {
  local old new
  old="$(env_val POSTGRES_PASSWORD)"
  new="$(gen_b64 32)"
  log "Rotating POSTGRES_PASSWORD..."

  if ! $DRY_RUN; then
    local pg_user
    pg_user="$(env_val POSTGRES_USER)"
    if ! docker exec -e PGPASSWORD="$old" chronicle-postgres \
         psql -h 127.0.0.1 -U "$pg_user" -d "$(env_val POSTGRES_DB)" \
         -c "ALTER ROLE ${pg_user} WITH PASSWORD '${new}';" 2>/dev/null; then
      err "Failed to ALTER ROLE in Postgres — .env NOT changed. Database password unchanged."
    fi
    log "ALTER ROLE succeeded in Postgres"
  fi

  env_set POSTGRES_PASSWORD "$new"
  RESTART_NEEDED[chronicle-backend]=1
  RESTART_NEEDED[chronicle-postgres-exporter]=1
}

rotate_jwt_secret() {
  local new
  new="$(gen_b64 64)"
  log "Rotating JWT_SECRET (all active sessions will be invalidated)..."
  if ! $DRY_RUN && ! confirm "This invalidates ALL user sessions. Continue?"; then
    warn "Skipped JWT_SECRET rotation"
    return
  fi
  env_set JWT_SECRET "$new"
  RESTART_NEEDED[chronicle-backend]=1
}

rotate_hazelcast_passwords() {
  local new_server new_client
  new_server="$(gen_b64 32)"
  new_client="$(gen_b64 32)"
  log "Rotating HAZELCAST_SERVER_PASSWORD + HAZELCAST_CLIENT_PASSWORD..."
  env_set HAZELCAST_SERVER_PASSWORD "$new_server"
  env_set HAZELCAST_CLIENT_PASSWORD "$new_client"
  RESTART_NEEDED[chronicle-backend]=1
}

rotate_grafana_admin_password() {
  local new
  new="$(gen_b64 32)"
  log "Rotating GRAFANA_ADMIN_PASSWORD..."

  if ! $DRY_RUN; then
    if ! docker exec chronicle-grafana grafana-cli admin reset-admin-password "$new" 2>&1; then
      err "Could not reset Grafana admin password — .env NOT changed. Grafana password unchanged."
    fi
    log "Grafana admin password reset via grafana-cli"
  fi

  env_set GRAFANA_ADMIN_PASSWORD "$new"
  RESTART_NEEDED[grafana]=1
}

rotate_crowdsec_bouncer_key() {
  local new
  log "Rotating CROWDSEC_BOUNCER_API_KEY..."

  if ! $DRY_RUN; then
    if ! docker exec chronicle-crowdsec cscli bouncers delete traefik-bouncer 2>&1; then
      warn "Delete of old bouncer failed — may not exist yet, continuing"
    fi
    new=$(docker exec chronicle-crowdsec cscli bouncers add traefik-bouncer -o raw) || {
      err "Failed to create new CrowdSec bouncer key — .env NOT changed"
    }
    [[ -n "$new" ]] || err "cscli bouncers add returned empty key — .env NOT changed"
  else
    new="dry-run-placeholder-key"
  fi

  env_set CROWDSEC_BOUNCER_API_KEY "$new"
  RESTART_NEEDED[traefik]=1
}

rotate_mobile_signing_secret() {
  warn "MOBILE_SIGNING_SECRET is shared with the Android APK signing process."
  warn "Rotating it requires publishing a new app version with the updated secret."
  if ! $DRY_RUN && ! confirm "Rotate MOBILE_SIGNING_SECRET? (Breaks existing app installs until APK update)"; then
    warn "Skipped MOBILE_SIGNING_SECRET rotation"
    return
  fi
  local new
  new="$(gen_b64 32)"
  env_set MOBILE_SIGNING_SECRET "$new"
  RESTART_NEEDED[chronicle-backend]=1
  warn "ACTION REQUIRED: Update the Android app with the new MOBILE_SIGNING_SECRET and publish a new release."
}

rotate_mobile_app_key() {
  warn "MOBILE_APP_KEY is embedded in the Android APK."
  warn "Rotating it will reject ALL requests from existing app installs."
  if ! $DRY_RUN && ! confirm "Rotate MOBILE_APP_KEY? (Breaks ALL existing app installs)"; then
    warn "Skipped MOBILE_APP_KEY rotation"
    return
  fi
  local new
  new="$(gen_hex 32)"
  env_set MOBILE_APP_KEY "$new"
  RESTART_NEEDED[chronicle-backend]=1
  warn "ACTION REQUIRED: Update the Android app with the new MOBILE_APP_KEY and publish a new release."
}

# ── Determine what to rotate ───────────────────────────────────────

ROTATABLE_SECRETS=(
  POSTGRES_PASSWORD
  JWT_SECRET
  HAZELCAST_SERVER_PASSWORD
  HAZELCAST_CLIENT_PASSWORD
  GRAFANA_ADMIN_PASSWORD
  CROWDSEC_BOUNCER_API_KEY
)

DANGEROUS_SECRETS=(
  MOBILE_SIGNING_SECRET
  MOBILE_APP_KEY
)

if [[ -n "$ONLY" ]]; then
  case "$ONLY" in
    POSTGRES_PASSWORD)          rotate_postgres_password ;;
    JWT_SECRET)                 rotate_jwt_secret ;;
    HAZELCAST_SERVER_PASSWORD)  rotate_hazelcast_passwords ;;
    HAZELCAST_CLIENT_PASSWORD)  rotate_hazelcast_passwords ;;
    GRAFANA_ADMIN_PASSWORD)     rotate_grafana_admin_password ;;
    CROWDSEC_BOUNCER_API_KEY)   rotate_crowdsec_bouncer_key ;;
    MOBILE_SIGNING_SECRET)      rotate_mobile_signing_secret ;;
    MOBILE_APP_KEY)             rotate_mobile_app_key ;;
    *)
      err "Unknown secret: $ONLY. Rotatable: ${ROTATABLE_SECRETS[*]} ${DANGEROUS_SECRETS[*]}"
      ;;
  esac
else
  log "=== Starting full secret rotation ==="
  log "Secrets to rotate: ${ROTATABLE_SECRETS[*]}"
  log ""
  warn "Secrets that require manual coordination (will prompt individually):"
  warn "  MOBILE_SIGNING_SECRET, MOBILE_APP_KEY"
  log ""

  if ! $DRY_RUN && ! $AUTO && ! confirm "Proceed with rotation?"; then
    log "Aborted."
    exit 0
  fi

  rotate_postgres_password
  rotate_jwt_secret
  rotate_hazelcast_passwords
  rotate_grafana_admin_password
  rotate_crowdsec_bouncer_key

  if ! $AUTO; then
    rotate_mobile_signing_secret
    rotate_mobile_app_key
  else
    warn "Skipping MOBILE_SIGNING_SECRET and MOBILE_APP_KEY in --auto mode (require APK coordination)"
  fi
fi

# ── Restart affected services ──────────────────────────────────────

restart_services() {
  # Restart in dependency order (compose service names, not container names):
  # 1. traefik        — picks up new CrowdSec key via template rendering
  # 2. chronicle-backend — picks up new DB password, JWT secret, Hazelcast passwords
  # 3. chronicle-postgres-exporter — picks up new DB password
  # 4. grafana        — picks up new admin password
  local svc attempts
  local -a order=(traefik chronicle-backend chronicle-postgres-exporter grafana)
  for svc in "${order[@]}"; do
    if [[ -n "${RESTART_NEEDED[$svc]:-}" ]]; then
      log "Restarting $svc..."
      dc restart "$svc"
      attempts=0
      while [[ $attempts -lt 60 ]]; do
        if docker inspect -f '{{.State.Health.Status}}' "$(dc ps -q "$svc" 2>/dev/null)" 2>/dev/null | grep -q "healthy"; then
          log "$svc is healthy"
          break
        fi
        sleep 2
        ((attempts++))
      done
      if [[ $attempts -ge 60 ]]; then
        warn "$svc did not become healthy within 120s — check: docker compose -f $COMPOSE_FILE logs $svc"
      fi
    fi
  done
}

if [[ ${#RESTART_NEEDED[@]} -gt 0 ]]; then
  log ""
  log "Services needing restart: ${!RESTART_NEEDED[*]}"

  if $DRY_RUN; then
    log "[dry-run] Would restart: ${!RESTART_NEEDED[*]}"
  elif confirm "Restart affected services now?"; then
    restart_services
  else
    log "Services NOT restarted. Run manually:"
    log "  docker compose -f $COMPOSE_FILE restart ${!RESTART_NEEDED[*]}"
  fi
fi

# ── Summary ─────────────────────────────────────────────────────────

log ""
log "=== Rotation complete ==="
log "Backup: $BACKUP_DIR/.env.$TIMESTAMP"

if ! $DRY_RUN; then
  log ""
  log "Post-rotation checklist:"
  log "  1. Verify backend health:  curl -s http://localhost:40320/prometheus/ | head -1"
  log "  2. Verify Traefik health:  docker exec chronicle-traefik traefik healthcheck"
  log "  3. Verify Grafana login:   open https://\$(grep DOMAIN $ENV_FILE | cut -d= -f2)/grafana"
  log "  4. Verify mobile API:      curl -s -H 'X-Chronicle-App-Key: <new-key>' https://\$(grep DOMAIN $ENV_FILE | cut -d= -f2)/chronicle/v3/healthz"
  log "  5. Update HIPAA rotation log with today's date"
fi
