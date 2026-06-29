#!/usr/bin/env bash
# rotate-tde-principal-key.sh — Rotate the Chronicle TDE principal (master) key.
#
# The TDE principal key is the master key that wraps pg_tde's per-table internal
# keys. Rotating it creates a NEW key version under the active key provider and
# sets it as the principal key. pg_tde then RE-WRAPS the existing internal keys
# under the new principal key — this is a metadata-only operation: it does NOT
# re-encrypt table data and requires no downtime or full-table rewrite.
#
# Provider selection mirrors docker/init-db-encryption.sh:
#   PG_TDE_KEY_PROVIDER=vault  -> provider "chronicle-vault"      (HashiCorp Vault)
#   PG_TDE_KEY_PROVIDER=file   -> provider "chronicle-file-vault" (file keyring; dev/test)
#   (anything else defaults to the file provider)
#
# After a successful rotation this script upserts the 'tde_principal_key' row in
# the secret_rotation_tracking table so the backend's SecretRotationService sees
# a fresh rotation age. When the active provider is Vault, the rotated_at field
# of the Vault metadata at secret/chronicle/tde-principal-key is also updated.
#
# Usage:
#   ./scripts/rotate-tde-principal-key.sh            # rotate now
#   ./scripts/rotate-tde-principal-key.sh --dry-run  # print SQL/actions, change nothing
#
# Environment (read from docker/.env when present, falling back to the process
# environment), mirroring rotate-secrets.sh / init-db-encryption.sh:
#   POSTGRES_USER, POSTGRES_DB, POSTGRES_PASSWORD  — DB connection
#   PG_TDE_KEY_PROVIDER                            — file | vault
#   PG_TDE_VAULT_URL, PG_TDE_VAULT_TOKEN, PG_TDE_VAULT_MOUNT_PATH — Vault (if vault)
#   PG_CONTAINER                                   — postgres container (default chronicle-postgres)
#
# HIPAA §164.312(a)(2)(iv) — Encryption key management
#
# Pre-requisites:
#   - docker (the Postgres container must be running)
#   - vault CLI (only when PG_TDE_KEY_PROVIDER=vault, for the metadata update)
#   - Run from the repository root (or the script's parent dir)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/docker/.env"

DRY_RUN=false

# ── Argument parsing ────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ─────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[rotate-tde]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n'        "$*" >&2; }
err()  { printf '\033[1;31m[error]\033[0m %s\n'       "$*" >&2; exit 1; }

# Read a value from docker/.env, falling back to the current environment.
# Mirrors the env_val helper in rotate-secrets.sh but env-aware.
env_or_file() {
  local key="$1" default="${2:-}" val=""
  if [[ -f "$ENV_FILE" ]]; then
    val="$(grep -E "^${key}=" "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
  fi
  if [[ -z "$val" ]]; then
    val="${!key:-}"
  fi
  if [[ -z "$val" ]]; then
    val="$default"
  fi
  printf '%s' "$val"
}

# ── Resolve configuration ───────────────────────────────────────────
PG_CONTAINER="$(env_or_file PG_CONTAINER chronicle-postgres)"
POSTGRES_USER="$(env_or_file POSTGRES_USER postgres)"
POSTGRES_DB="$(env_or_file POSTGRES_DB chronicle)"
POSTGRES_PASSWORD="$(env_or_file POSTGRES_PASSWORD)"
PG_TDE_KEY_PROVIDER="$(env_or_file PG_TDE_KEY_PROVIDER file)"

# Select the active provider exactly as init-db-encryption.sh does.
case "$PG_TDE_KEY_PROVIDER" in
  vault) KEY_PROVIDER="chronicle-vault" ;;
  *)     KEY_PROVIDER="chronicle-file-vault" ;;
esac

KEY_NAME_BASE="chronicle-principal-key"
NEW_KEY_NAME="${KEY_NAME_BASE}-$(date +%Y%m%d%H%M%S)"

log "TDE key provider: ${PG_TDE_KEY_PROVIDER} (provider name: ${KEY_PROVIDER})"
log "New principal key version: ${NEW_KEY_NAME}"

# Run a SQL statement inside the Postgres container, matching the
# `docker exec -e PGPASSWORD=... <container> psql -h 127.0.0.1 -U <user> -d <db>`
# pattern already used by rotate-secrets.sh:rotate_postgres_password.
run_sql() {
  local sql="$1"
  docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$PG_CONTAINER" \
    psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "$sql"
}

# ── Rotation SQL ────────────────────────────────────────────────────
# Create a new principal-key version under the active provider, then set it as
# THE principal key. Setting the key re-wraps the existing internal keys under
# the new principal key (metadata-only; no full-table re-encryption).
ROTATE_SQL="SELECT pg_tde_create_key_using_database_key_provider('${NEW_KEY_NAME}', '${KEY_PROVIDER}');
SELECT pg_tde_set_key_using_database_key_provider('${NEW_KEY_NAME}', '${KEY_PROVIDER}');"

# Upsert the rotation-age tracking row read by SecretRotationService. This resets
# the age that the backend monitors for 'tde_principal_key'.
UPSERT_SQL="INSERT INTO secret_rotation_tracking (secret_name, last_rotated, rotated_by, notes) VALUES ('tde_principal_key', NOW(), 'rotate-tde-principal-key.sh', '${NEW_KEY_NAME}') ON CONFLICT (secret_name) DO UPDATE SET last_rotated = EXCLUDED.last_rotated, rotated_by = EXCLUDED.rotated_by, notes = EXCLUDED.notes;"

# ── Vault metadata update (vault provider only) ─────────────────────
update_vault_metadata() {
  local mount_path vault_addr vault_token kv_path
  mount_path="$(env_or_file PG_TDE_VAULT_MOUNT_PATH secret)"
  vault_addr="$(env_or_file PG_TDE_VAULT_URL)"
  vault_token="$(env_or_file PG_TDE_VAULT_TOKEN)"
  kv_path="${mount_path}/chronicle/tde-principal-key"

  if $DRY_RUN; then
    log "[dry-run] Would update Vault metadata at ${kv_path}:"
    log "[dry-run]   vault kv patch ${kv_path} rotated_at=<now> rotated_key=${NEW_KEY_NAME}"
    return
  fi

  if ! command -v vault >/dev/null 2>&1; then
    warn "vault CLI not found — skipping Vault metadata update at ${kv_path}"
    warn "Record the rotation manually: rotated_at + rotated_key=${NEW_KEY_NAME}"
    return
  fi

  [[ -n "$vault_addr" ]]  || err "PG_TDE_VAULT_URL is required to update Vault metadata"
  [[ -n "$vault_token" ]] || err "PG_TDE_VAULT_TOKEN is required to update Vault metadata"

  # Mirror how init-vault.sh writes this secret (rotated_at uses date -Iseconds,
  # same format as init-vault.sh's created_at). kv patch preserves existing
  # fields (key/fingerprint/created_at) while adding the rotation marker.
  VAULT_ADDR="$vault_addr" VAULT_TOKEN="$vault_token" \
    vault kv patch "$kv_path" \
      rotated_at="$(date -Iseconds)" \
      rotated_key="$NEW_KEY_NAME" \
    || err "Failed to update Vault metadata at ${kv_path}"

  log "Updated Vault metadata at ${kv_path} (rotated_at, rotated_key=${NEW_KEY_NAME})"
}

# ── Execute ─────────────────────────────────────────────────────────
if $DRY_RUN; then
  log "[dry-run] Would execute the following against ${PG_CONTAINER} (db: ${POSTGRES_DB}):"
  log "[dry-run] --- rotate principal key ---"
  printf '%s\n' "$ROTATE_SQL"
  log "[dry-run] --- upsert rotation tracking ---"
  printf '%s\n' "$UPSERT_SQL"
  if [[ "$PG_TDE_KEY_PROVIDER" == "vault" ]]; then
    update_vault_metadata
  fi
  log "[dry-run] No changes made."
  exit 0
fi

[[ -n "$POSTGRES_PASSWORD" ]] || err "POSTGRES_PASSWORD is not set (checked $ENV_FILE and environment)"

log "Rotating TDE principal key..."
run_sql "$ROTATE_SQL" || err "Failed to rotate TDE principal key — principal key UNCHANGED"
log "New principal key '${NEW_KEY_NAME}' created and set under provider '${KEY_PROVIDER}'"
log "Internal keys re-wrapped under the new principal key (no table re-encryption)"

log "Updating secret_rotation_tracking for 'tde_principal_key'..."
run_sql "$UPSERT_SQL" \
  || warn "Key rotated, but failed to update secret_rotation_tracking — update it manually"
log "secret_rotation_tracking updated (rotation age reset for backend monitoring)"

if [[ "$PG_TDE_KEY_PROVIDER" == "vault" ]]; then
  update_vault_metadata
fi

log ""
log "=== TDE principal key rotation complete ==="
log "  Provider:        ${KEY_PROVIDER}"
log "  New key version: ${NEW_KEY_NAME}"
log "Next steps:"
log "  1. Verify the principal key:  docker exec ${PG_CONTAINER} psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c 'SELECT * FROM pg_tde_key_info();'"
log "  2. Confirm backend monitoring: curl -s http://localhost:40320/internal/health/secrets | grep tde_principal_key"
log "  3. Record the rotation in the HIPAA key-management log"
