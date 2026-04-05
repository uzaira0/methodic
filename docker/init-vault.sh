#!/bin/bash
# Chronicle Vault Initialization Script
# Sets up HashiCorp Vault for TDE key management in production.
#
# Usage:
#   ./init-vault.sh [--vault-addr <url>] [--tde-key <hex>]
#
# Prerequisites:
#   - HashiCorp Vault server running and accessible
#   - vault CLI installed
#   - VAULT_ADDR and VAULT_TOKEN environment variables (or --vault-addr)
#
# This script:
#   1. Initializes Vault with 5 unseal keys (3 threshold)
#   2. Enables KV v2 secrets engine at the configured mount path
#   3. Stores the TDE principal key in Vault
#   4. Creates a PostgreSQL read-only policy
#   5. Generates a token with that policy
#
# HIPAA §164.312(a)(2)(iv) — Encryption key management

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_MOUNT_PATH="${PG_TDE_VAULT_MOUNT_PATH:-secret}"
TDE_KEY=""
VAULT_INIT_SHARES=5
VAULT_INIT_THRESHOLD=3
SKIP_INIT=false

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log()      { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_ok()   { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}OK${NC} $*"; }
log_err()  { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}ERROR${NC} $*" >&2; }
log_warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}WARN${NC} $*"; }
log_step() { echo -e "\n${BOLD}=== Step $1: $2 ===${NC}"; }

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --vault-addr <url>    Vault address (default: \$VAULT_ADDR or http://127.0.0.1:8200)"
    echo "  --tde-key <hex>       TDE principal key to store (generated if omitted)"
    echo "  --mount-path <path>   KV v2 mount path (default: secret)"
    echo "  --skip-init           Skip Vault init (use if already initialized)"
    exit 1
}

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault-addr)   VAULT_ADDR="$2"; shift 2 ;;
        --tde-key)      TDE_KEY="$2"; shift 2 ;;
        --mount-path)   VAULT_MOUNT_PATH="$2"; shift 2 ;;
        --skip-init)    SKIP_INIT=true; shift ;;
        --help|-h)      usage ;;
        *)              log_err "Unknown option: $1"; usage ;;
    esac
done

export VAULT_ADDR

# ── Check prerequisites ──────────────────────────────────────────────────────
if ! command -v vault >/dev/null 2>&1; then
    log_err "vault CLI not found. Install from: https://developer.hashicorp.com/vault/install"
    exit 1
fi

log "Vault address: ${VAULT_ADDR}"

# Check Vault connectivity
if ! vault status -format=json >/dev/null 2>&1; then
    # vault status returns exit code 2 when sealed, 1 when not initialized -- both are OK
    VAULT_STATUS_CODE=$?
    if [ "$VAULT_STATUS_CODE" -gt 2 ]; then
        log_err "Cannot reach Vault at ${VAULT_ADDR}"
        exit 1
    fi
fi

# ── Output directory for secrets ──────────────────────────────────────────────
OUTPUT_DIR="./vault-init-output"
mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"

# ══════════════════════════════════════════════════════════════════════════════
log_step 1 "Initialize Vault"
# ══════════════════════════════════════════════════════════════════════════════

if [ "$SKIP_INIT" = true ]; then
    log "Skipping Vault initialization (--skip-init)"
else
    INIT_STATUS=$(vault status -format=json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('initialized', False))" 2>/dev/null || echo "false")

    if [ "$INIT_STATUS" = "True" ] || [ "$INIT_STATUS" = "true" ]; then
        log_warn "Vault is already initialized. Use --skip-init to proceed."
        log_warn "If you need to re-initialize, you must destroy and recreate the Vault storage."
    else
        log "Initializing Vault with ${VAULT_INIT_SHARES} unseal keys, ${VAULT_INIT_THRESHOLD} threshold..."

        INIT_OUTPUT=$(vault operator init \
            -key-shares="${VAULT_INIT_SHARES}" \
            -key-threshold="${VAULT_INIT_THRESHOLD}" \
            -format=json)

        # Extract unseal keys and root token
        for i in $(seq 0 $((VAULT_INIT_SHARES - 1))); do
            KEY=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][$i])")
            echo "$KEY" > "${OUTPUT_DIR}/unseal-key-$((i + 1)).txt"
            chmod 600 "${OUTPUT_DIR}/unseal-key-$((i + 1)).txt"
        done

        ROOT_TOKEN=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")
        echo "$ROOT_TOKEN" > "${OUTPUT_DIR}/root-token.txt"
        chmod 600 "${OUTPUT_DIR}/root-token.txt"

        log_ok "Vault initialized"
        log "  Unseal keys written to ${OUTPUT_DIR}/unseal-key-{1..${VAULT_INIT_SHARES}}.txt"
        log "  Root token written to ${OUTPUT_DIR}/root-token.txt"

        # Unseal Vault
        log "Unsealing Vault..."
        for i in $(seq 1 "$VAULT_INIT_THRESHOLD"); do
            UNSEAL_KEY=$(cat "${OUTPUT_DIR}/unseal-key-${i}.txt")
            vault operator unseal "$UNSEAL_KEY" >/dev/null 2>&1
        done
        log_ok "Vault unsealed"

        export VAULT_TOKEN="$ROOT_TOKEN"
    fi
fi

# Verify Vault is unsealed
SEALED=$(vault status -format=json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed', True))" 2>/dev/null || echo "true")
if [ "$SEALED" = "True" ] || [ "$SEALED" = "true" ]; then
    log_err "Vault is sealed. Unseal it before continuing."
    exit 1
fi

# Ensure we have a token
if [ -z "${VAULT_TOKEN:-}" ]; then
    if [ -f "${OUTPUT_DIR}/root-token.txt" ]; then
        export VAULT_TOKEN=$(cat "${OUTPUT_DIR}/root-token.txt")
    else
        log_err "VAULT_TOKEN is not set. Export it or provide root-token.txt."
        exit 1
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
log_step 2 "Enable KV v2 secrets engine"
# ══════════════════════════════════════════════════════════════════════════════

# Check if already enabled
EXISTING_MOUNTS=$(vault secrets list -format=json 2>/dev/null || echo "{}")
if echo "$EXISTING_MOUNTS" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if '${VAULT_MOUNT_PATH}/' in d else 1)" 2>/dev/null; then
    log_warn "Secrets engine already enabled at '${VAULT_MOUNT_PATH}/'"
else
    vault secrets enable -path="${VAULT_MOUNT_PATH}" -version=2 kv
    log_ok "KV v2 secrets engine enabled at '${VAULT_MOUNT_PATH}/'"
fi

# ══════════════════════════════════════════════════════════════════════════════
log_step 3 "Store TDE principal key"
# ══════════════════════════════════════════════════════════════════════════════

if [ -z "$TDE_KEY" ]; then
    log "Generating new TDE principal key..."
    TDE_KEY=$(openssl rand -hex 32)
    log_ok "Generated 256-bit TDE key"
fi

TDE_FINGERPRINT=$(echo -n "$TDE_KEY" | sha256sum | awk '{print $1}')

vault kv put "${VAULT_MOUNT_PATH}/chronicle/tde-principal-key" \
    key="$TDE_KEY" \
    fingerprint="$TDE_FINGERPRINT" \
    created_at="$(date -Iseconds)" \
    description="Chronicle TDE principal encryption key"

log_ok "TDE key stored at ${VAULT_MOUNT_PATH}/chronicle/tde-principal-key"
log "  Key fingerprint: ${TDE_FINGERPRINT}"

# ══════════════════════════════════════════════════════════════════════════════
log_step 4 "Create PostgreSQL read policy"
# ══════════════════════════════════════════════════════════════════════════════

POLICY_NAME="chronicle-tde-read"

vault policy write "$POLICY_NAME" - <<POLICY
# Chronicle TDE Key Read Policy
# Allows the PostgreSQL service to read the TDE principal key
# but not write, delete, or list other secrets.

path "${VAULT_MOUNT_PATH}/data/chronicle/tde-principal-key" {
    capabilities = ["read"]
}

path "${VAULT_MOUNT_PATH}/metadata/chronicle/tde-principal-key" {
    capabilities = ["read"]
}
POLICY

log_ok "Policy '${POLICY_NAME}' created"

# ══════════════════════════════════════════════════════════════════════════════
log_step 5 "Generate service token"
# ══════════════════════════════════════════════════════════════════════════════

SERVICE_TOKEN_OUTPUT=$(vault token create \
    -policy="${POLICY_NAME}" \
    -display-name="chronicle-postgres-tde" \
    -ttl="8760h" \
    -format=json)

SERVICE_TOKEN=$(echo "$SERVICE_TOKEN_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")

echo "$SERVICE_TOKEN" > "${OUTPUT_DIR}/pg-tde-service-token.txt"
chmod 600 "${OUTPUT_DIR}/pg-tde-service-token.txt"

log_ok "Service token generated with policy '${POLICY_NAME}'"
log "  Token written to ${OUTPUT_DIR}/pg-tde-service-token.txt"
log "  TTL: 8760h (1 year) -- rotate before expiry"

# ══════════════════════════════════════════════════════════════════════════════
log_step 6 "Generate .env configuration"
# ══════════════════════════════════════════════════════════════════════════════

cat > "${OUTPUT_DIR}/vault-env-snippet.txt" <<ENVEOF
# Add these to your .env file for Vault-backed TDE:
PG_TDE_KEY_PROVIDER=vault
PG_TDE_VAULT_URL=${VAULT_ADDR}
PG_TDE_VAULT_TOKEN=${SERVICE_TOKEN}
PG_TDE_VAULT_MOUNT_PATH=${VAULT_MOUNT_PATH}
# PG_TDE_VAULT_CA_PATH=/path/to/vault-ca.pem  # Uncomment for TLS
ENVEOF

log_ok "Environment snippet written to ${OUTPUT_DIR}/vault-env-snippet.txt"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=========================================="
echo "Vault Initialization Complete"
echo -e "==========================================${NC}"
echo ""
echo "  Vault Address:      ${VAULT_ADDR}"
echo "  Secrets Mount:      ${VAULT_MOUNT_PATH}/"
echo "  TDE Key Path:       ${VAULT_MOUNT_PATH}/chronicle/tde-principal-key"
echo "  TDE Fingerprint:    ${TDE_FINGERPRINT}"
echo "  Policy:             ${POLICY_NAME}"
echo "  Service Token TTL:  8760h (1 year)"
echo ""
echo "  Output files:"
if [ "$SKIP_INIT" != true ]; then
echo "    ${OUTPUT_DIR}/unseal-key-{1..${VAULT_INIT_SHARES}}.txt  (distribute to custodians)"
echo "    ${OUTPUT_DIR}/root-token.txt                (store securely, revoke after setup)"
fi
echo "    ${OUTPUT_DIR}/pg-tde-service-token.txt      (use as PG_TDE_VAULT_TOKEN)"
echo "    ${OUTPUT_DIR}/vault-env-snippet.txt         (paste into .env)"
echo ""
echo -e "${YELLOW}IMPORTANT:${NC}"
echo "  1. Distribute unseal keys to different custodians (same as key ceremony)"
echo "  2. Revoke the root token after initial setup: vault token revoke <root-token>"
echo "  3. Set up auto-unseal for production (see docs/KEY-MANAGEMENT-RUNBOOK.md)"
echo "  4. Copy the .env snippet into your production .env file"
echo "  5. Rotate the service token annually"
echo ""
