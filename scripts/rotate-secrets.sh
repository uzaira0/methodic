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
# Secrets that CANNOT be auto-rotated by THIS script (require external coordination):
#   MOBILE_APP_KEY        — controlled legacy compatibility only; public apps do not carry it
#   MOBILE_SIGNING_SECRET — shared-HMAC key for an explicitly controlled legacy fleet only
#   PG_TDE_VAULT_TOKEN    — Vault AUTH token, issued by the external Vault cluster
#   SMTP_PASSWORD         — managed by the email provider (Office 365 admin)
#
# The TDE principal KEY itself IS rotatable (distinct from PG_TDE_VAULT_TOKEN
# above): rotate it via scripts/rotate-tde-principal-key.sh, invoked here by the
# rotate_tde_principal_key helper. It creates a new principal-key version under
# the active pg_tde provider and re-wraps the internal keys (no table rewrite).
#
# Pre-requisites:
#   - openssl, docker, docker compose
#   - Run from the repository root (or the script's parent dir)
#   - The docker stack must be running for service-level rotations (Postgres, CrowdSec, Grafana)

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${CHRONICLE_ENV_FILE:-$REPO_ROOT/docker/.env}"
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

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

require_private_file() {
  local path="$1" description="$2" mode
  [[ -f "$path" && ! -L "$path" ]] || err "$description must be a regular, non-symlink file: $path"
  mode="$(file_mode "$path")" || err "Could not inspect permissions for $description: $path"
  [[ "$mode" == "600" ]] || err "$description must have mode 0600 (found $mode): $path"
  [[ -O "$path" ]] || err "$description must be owned by the current user: $path"
}

declare -a PRIVATE_FILES=()
cleanup_private_files() {
  local path
  for path in "${PRIVATE_FILES[@]}"; do
    [[ -n "$path" && -f "$path" ]] && rm -f -- "$path"
  done
}
trap cleanup_private_files EXIT

new_private_file() {
  local _target_name="$1" _created_path
  _created_path="$(mktemp "$BACKUP_DIR/.rotation-secret.XXXXXX")"
  chmod 600 "$_created_path"
  PRIVATE_FILES+=("$_created_path")
  printf -v "$_target_name" '%s' "$_created_path"
}

generate_secret_file() {
  local target_var="$1" encoding="$2" bytes="$3" generated raw
  new_private_file generated
  case "$encoding" in
    base64)
      new_private_file raw
      openssl rand "$bytes" -out "$raw"
      openssl base64 -A -in "$raw" -out "$generated"
      rm -f -- "$raw"
      ;;
    hex)
      openssl rand -hex "$bytes" -out "$generated"
      ;;
    *) err "Unsupported secret encoding: $encoding" ;;
  esac
  require_private_file "$generated" "generated secret"
  printf -v "$target_var" '%s' "$generated"
}

prepare_secret_file() {
  local target_var="$1" encoding="$2" bytes="$3"
  if $DRY_RUN; then
    printf -v "$target_var" ''
  else
    generate_secret_file "$target_var" "$encoding" "$bytes"
  fi
}

confirm() {
  if $AUTO; then return 0; fi
  if [[ ! -t 0 ]]; then
    err "Non-interactive stdin detected. Use --auto for unattended rotation or run from a terminal."
  fi
  printf '\033[1;33m%s [y/N] \033[0m' "$1"
  read -r ans
  [[ "$ans" =~ ^[Yy] ]]
}

# Read current value of an env var from the .env file
env_val() { grep -E "^${1}=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

# Replace a value in .env atomically without putting it in process arguments.
env_set() {
  local key="$1" secret_file="$2" length tmp_file
  if $DRY_RUN; then
    log "[dry-run] Would set $key=<redacted>"
    return
  fi
  require_private_file "$secret_file" "$key replacement secret"
  length="$(wc -c < "$secret_file" | tr -d '[:space:]')"
  tmp_file="$(mktemp "$ENV_FILE.tmp.XXXXXX")"
  chmod 600 "$tmp_file"
  PRIVATE_FILES+=("$tmp_file")
  if ! python3 - "$ENV_FILE" "$key" "$secret_file" "$tmp_file" <<'PY'
import pathlib
import sys

env_path, key, secret_path, output_path = map(pathlib.Path, sys.argv[1:])
secret = secret_path.read_text(encoding="utf-8").rstrip("\r\n")
if not secret or "\n" in secret or "\r" in secret:
    raise SystemExit("replacement secret must be one non-empty line")
prefix = f"{key}="
lines = env_path.read_text(encoding="utf-8").splitlines(keepends=True)
found = False
rewritten = []
for line in lines:
    if line.startswith(prefix) and not found:
        ending = "\n" if line.endswith("\n") else ""
        rewritten.append(f"{prefix}{secret}{ending}")
        found = True
    else:
        rewritten.append(line)
if not found:
    raise SystemExit(f"{key} is missing from the environment file")
pathlib.Path(output_path).write_text("".join(rewritten), encoding="utf-8")
PY
  then
    err "Failed writing $key to $ENV_FILE — original file unchanged"
  fi
  chmod 600 "$tmp_file"
  mv -- "$tmp_file" "$ENV_FILE"
  grep -qE "^${key}=" "$ENV_FILE" \
    || err "$key not found in $ENV_FILE after write"
  log "Rotated $key ($length chars)"
}

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

# ── Pre-flight ──────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || err "$ENV_FILE not found — run from the repository root"
require_private_file "$ENV_FILE" "Chronicle environment file"

if ! $DRY_RUN; then
  mkdir -p "$BACKUP_DIR"
  [[ -d "$BACKUP_DIR" && ! -L "$BACKUP_DIR" && -O "$BACKUP_DIR" ]] \
    || err "Secret backup directory must be a current-user-owned, non-symlink directory: $BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  install -m 0600 "$ENV_FILE" "$BACKUP_DIR/.env.$TIMESTAMP"
  log "Backed up .env → $BACKUP_DIR/.env.$TIMESTAMP"
fi

# Do not let ambient copies of old credentials propagate to docker/openssl
# children. Secret values read by this script remain unexported shell data.
export -n POSTGRES_PASSWORD JWT_SECRET GRAFANA_ADMIN_PASSWORD \
  CROWDSEC_BOUNCER_API_KEY HAZELCAST_SERVER_PASSWORD \
  HAZELCAST_CLIENT_PASSWORD MOBILE_SIGNING_SECRET MOBILE_APP_KEY 2>/dev/null || true

# Track which services need restart (keyed by docker compose SERVICE name)
declare -A RESTART_NEEDED

# ── Individual rotation functions ───────────────────────────────────

rotate_postgres_password() {
  local new_file pg_input pg_user pg_db
  prepare_secret_file new_file base64 32
  log "Rotating POSTGRES_PASSWORD..."

  if ! $DRY_RUN; then
    pg_user="$(env_val POSTGRES_USER)"
    pg_db="$(env_val POSTGRES_DB)"
    new_private_file pg_input
    python3 - "$ENV_FILE" "$new_file" "$pg_input" <<'PY'
import pathlib
import sys

env_path, new_secret_path, output_path = map(pathlib.Path, sys.argv[1:])
old = b""
for line in env_path.read_bytes().splitlines():
    if line.startswith(b"POSTGRES_PASSWORD="):
        old = line.split(b"=", 1)[1]
        break
new = new_secret_path.read_bytes().rstrip(b"\r\n")
if not old or not new or b"'" in new or b"\n" in new or b"\r" in new:
    raise SystemExit("invalid Postgres password rotation input")
payload = (
    old
    + b"\n\\set new_password '"
    + new
    + b"'\nALTER ROLE :\"role_name\" WITH PASSWORD :'new_password';\n"
)
output_path.write_bytes(payload)
PY
    chmod 600 "$pg_input"
    if ! docker exec -i chronicle-postgres sh -ceu '
           IFS= read -r PGPASSWORD
           export PGPASSWORD
           exec psql -v ON_ERROR_STOP=1 --set=role_name="$1" -h 127.0.0.1 -U "$1" -d "$2"
         ' sh "$pg_user" "$pg_db" < "$pg_input" 2>/dev/null; then
      err "Failed to ALTER ROLE in Postgres — .env NOT changed. Database password unchanged."
    fi
    rm -f -- "$pg_input"
    log "ALTER ROLE succeeded in Postgres"
  fi

  env_set POSTGRES_PASSWORD "$new_file"
  RESTART_NEEDED[chronicle-backend]=1
  RESTART_NEEDED[chronicle-postgres-exporter]=1
}

rotate_jwt_secret() {
  local new_file
  prepare_secret_file new_file base64 64
  log "Rotating JWT_SECRET (all active sessions will be invalidated)..."
  if ! $DRY_RUN && ! confirm "This invalidates ALL user sessions. Continue?"; then
    warn "Skipped JWT_SECRET rotation"
    return
  fi
  env_set JWT_SECRET "$new_file"
  RESTART_NEEDED[chronicle-backend]=1
}

rotate_hazelcast_passwords() {
  local new_server_file new_client_file
  prepare_secret_file new_server_file base64 32
  prepare_secret_file new_client_file base64 32
  log "Rotating HAZELCAST_SERVER_PASSWORD + HAZELCAST_CLIENT_PASSWORD..."
  env_set HAZELCAST_SERVER_PASSWORD "$new_server_file"
  env_set HAZELCAST_CLIENT_PASSWORD "$new_client_file"
  RESTART_NEEDED[chronicle-backend]=1
}

rotate_grafana_admin_password() {
  local new_file
  prepare_secret_file new_file base64 32
  log "Rotating GRAFANA_ADMIN_PASSWORD..."

  if ! $DRY_RUN; then
    if ! docker exec -i chronicle-grafana \
         grafana cli admin reset-admin-password --password-from-stdin \
         < "$new_file" >/dev/null; then
      err "Could not reset Grafana admin password — .env NOT changed. Grafana password unchanged."
    fi
    log "Grafana admin password reset via grafana-cli"
  fi

  env_set GRAFANA_ADMIN_PASSWORD "$new_file"
  RESTART_NEEDED[grafana]=1
}

rotate_crowdsec_bouncer_key() {
  local new_file container_key_file
  log "Rotating CROWDSEC_BOUNCER_API_KEY..."

  if ! $DRY_RUN; then
    if ! docker exec chronicle-crowdsec cscli bouncers delete traefik-bouncer >/dev/null 2>&1; then
      warn "Delete of old bouncer failed — may not exist yet, continuing"
    fi
    container_key_file="/var/lib/crowdsec/data/.chronicle-bouncer-key-${TIMESTAMP}-$$"
    if ! docker exec chronicle-crowdsec sh -ceu '
           umask 077
           cscli bouncers add "$1" -o raw > "$2"
         ' sh traefik-bouncer "$container_key_file" >/dev/null 2>&1; then
      docker exec chronicle-crowdsec rm -f -- "$container_key_file" >/dev/null 2>&1 || true
      err "Failed to create new CrowdSec bouncer key — .env NOT changed"
    fi
    new_private_file new_file
    if ! docker cp "chronicle-crowdsec:$container_key_file" "$new_file" >/dev/null; then
      docker exec chronicle-crowdsec rm -f -- "$container_key_file" >/dev/null 2>&1 || true
      err "Failed to copy the protected CrowdSec bouncer key — .env NOT changed"
    fi
    docker exec chronicle-crowdsec rm -f -- "$container_key_file" >/dev/null 2>&1 \
      || warn "Could not remove protected CrowdSec key handoff file from the container"
    chmod 600 "$new_file"
    [[ -s "$new_file" ]] || err "cscli bouncers add returned an empty key — .env NOT changed"
  else
    new_file=""
  fi

  env_set CROWDSEC_BOUNCER_API_KEY "$new_file"
  RESTART_NEEDED[traefik]=1
}

rotate_tde_principal_key() {
  log "Rotating TDE principal key (delegating to rotate-tde-principal-key.sh)..."
  local rotate_tde="$SCRIPT_DIR/rotate-tde-principal-key.sh"
  [[ -x "$rotate_tde" ]] || err "rotate-tde-principal-key.sh not found or not executable at $rotate_tde"

  if $DRY_RUN; then
    "$rotate_tde" --dry-run
  else
    "$rotate_tde" || err "TDE principal key rotation failed — see output above"
  fi
  # The TDE principal key lives in pg_tde/Vault, not docker/.env, so no env_set
  # and no service restart is required (re-wrap is online).
}

rotate_mobile_signing_secret() {
  warn "MOBILE_SIGNING_SECRET is not used by the public Android/iOS apps."
  warn "Rotate it only for an explicitly controlled legacy/research-client fleet."
  if ! $DRY_RUN && ! confirm "Rotate MOBILE_SIGNING_SECRET with controlled legacy-client coordination?"; then
    warn "Skipped MOBILE_SIGNING_SECRET rotation"
    return
  fi
  local new_file
  prepare_secret_file new_file base64 32
  env_set MOBILE_SIGNING_SECRET "$new_file"
  RESTART_NEEDED[chronicle-backend]=1
  warn "ACTION REQUIRED: Update only the controlled legacy clients that were explicitly provisioned with this compatibility key."
}

rotate_mobile_app_key() {
  warn "MOBILE_APP_KEY is not present in the public APK/AAB."
  warn "Rotate it only if a controlled legacy integration is explicitly known to consume it."
  if ! $DRY_RUN && ! confirm "Rotate MOBILE_APP_KEY with controlled legacy-client coordination?"; then
    warn "Skipped MOBILE_APP_KEY rotation"
    return
  fi
  local new_file
  prepare_secret_file new_file hex 32
  env_set MOBILE_APP_KEY "$new_file"
  RESTART_NEEDED[chronicle-backend]=1
  warn "ACTION REQUIRED: Coordinate only the controlled legacy integration that consumes MOBILE_APP_KEY."
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
    TDE_PRINCIPAL_KEY)          rotate_tde_principal_key ;;
    MOBILE_SIGNING_SECRET)      rotate_mobile_signing_secret ;;
    MOBILE_APP_KEY)             rotate_mobile_app_key ;;
    *)
      err "Unknown secret: $ONLY. Rotatable: ${ROTATABLE_SECRETS[*]} TDE_PRINCIPAL_KEY ${DANGEROUS_SECRETS[*]}"
      ;;
  esac
else
  log "=== Starting full secret rotation ==="
  log "Secrets to rotate: ${ROTATABLE_SECRETS[*]} TDE_PRINCIPAL_KEY"
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
  rotate_tde_principal_key

  if ! $AUTO; then
    rotate_mobile_signing_secret
    rotate_mobile_app_key
  else
    warn "Skipping MOBILE_SIGNING_SECRET and MOBILE_APP_KEY in --auto mode (require explicit controlled legacy-client coordination)"
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

# Guard: under `set -u`, an empty `declare -A` array errors on ${#arr[@]}.
# The +x test is set only when the array has at least one element. Some rotations
# (e.g. the TDE principal key) intentionally populate nothing.
if [[ -n "${RESTART_NEEDED[*]+x}" ]]; then
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
  log "  1. Verify backend readiness:  curl -fsS http://localhost:40320/chronicle/internal/health/ready"
  log "  2. Verify Traefik health:  docker exec edge-traefik traefik healthcheck"
  log "  3. Verify Grafana login:   open https://\$(grep DOMAIN $ENV_FILE | cut -d= -f2)/grafana"
  log "  4. Verify mobile API:      curl -s -H 'X-Chronicle-App-Key: <new-key>' https://\$(grep DOMAIN $ENV_FILE | cut -d= -f2)/chronicle/v3/healthz"
  log "  5. Update HIPAA rotation log with today's date"
fi
