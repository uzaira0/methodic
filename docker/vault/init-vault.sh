#!/bin/sh
# Chronicle Vault PRODUCTION Initialization Script
# =============================================================================
# Seeds the REAL Chronicle secrets into a production Vault and creates the
# chronicle-server AppRole. This is the production counterpart to
# init-dev-secrets.sh (which seeds throwaway dev values and must NEVER be used
# against a deployment the backend reads from with VAULT_ENABLED=true — its dev
# DB/JWT/mobile values would be overlaid over the real ones and break the stack).
#
# PRECONDITIONS (operator-run, deliberately NOT automated):
#   1. A PERSISTENT, unsealed Vault (raft/integrated storage or external cluster
#      with auto-unseal). Do NOT use `vault server -dev` — its in-memory storage
#      loses every secret (incl. W2 study keys → undecryptable ciphertext) on restart.
#   2. VAULT_ADDR + a VAULT_TOKEN with privileges to enable engines/auth + write.
#   3. The REAL secret values exported in this script's environment (source them
#      from your secret manager / the live .env — they are NOT hardcoded here).
#
# This script is idempotent. After it succeeds, set in the backend env:
#   VAULT_ENABLED=true
#   VAULT_AUTH_METHOD=approle
#   VAULT_APP_ROLE_ID / VAULT_APP_ROLE_SECRET_ID  (printed at the end)
# then restart the backend in a maintenance window.
# =============================================================================

set -eu

: "${VAULT_ADDR:?set VAULT_ADDR to the production Vault, e.g. https://vault.internal:8200}"
: "${VAULT_TOKEN:?set VAULT_TOKEN to a token that can configure Vault}"

# ── Required real secrets (fail fast if any is missing or still a dev default) ──
require_real() {
    name="$1"; val="$2"
    if [ -z "$val" ]; then
        echo "FATAL: $name is empty — refusing to seed an incomplete Vault." >&2
        exit 1
    fi
    case "$val" in
        *dev-*|*not-for-production*|*example.com*|change-me*|CHANGEME*)
            echo "FATAL: $name looks like a dev/placeholder value ('$val') — refusing." >&2
            exit 1 ;;
    esac
}

require_real POSTGRES_USER          "${POSTGRES_USER:-}"
require_real POSTGRES_PASSWORD      "${POSTGRES_PASSWORD:-}"
require_real JWT_SECRET             "${JWT_SECRET:-}"
require_real MOBILE_SIGNING_SECRET  "${MOBILE_SIGNING_SECRET:-}"
require_real MOBILE_APP_KEY         "${MOBILE_APP_KEY:-}"
require_real HAZELCAST_SERVER_PASSWORD "${HAZELCAST_SERVER_PASSWORD:-}"
require_real HAZELCAST_CLIENT_PASSWORD "${HAZELCAST_CLIENT_PASSWORD:-}"

echo "=== Chronicle Vault PRODUCTION init against ${VAULT_ADDR} ==="

# Refuse to run against a dev-mode server (in-memory storage = guaranteed secret loss).
if vault status -format=json 2>/dev/null | grep -q '"storage_type"[[:space:]]*:[[:space:]]*"inmem"'; then
    echo "FATAL: target Vault uses in-memory (dev) storage. Use a persistent backend." >&2
    exit 1
fi

# ── 1. KV v2 at secret/ ───────────────────────────────────────────────────────
vault secrets list | grep -q "^secret/" || vault secrets enable -path=secret -version=2 kv

# ── 2. Seed the REAL secrets ──────────────────────────────────────────────────
vault kv put secret/chronicle/database  user="$POSTGRES_USER" password="$POSTGRES_PASSWORD"
vault kv put secret/chronicle/jwt       secret="$JWT_SECRET"
vault kv put secret/chronicle/mobile    signing-secret="$MOBILE_SIGNING_SECRET" app-key="$MOBILE_APP_KEY"
vault kv put secret/chronicle/hazelcast server-password="$HAZELCAST_SERVER_PASSWORD" client-password="$HAZELCAST_CLIENT_PASSWORD"

# Optional secrets — seed only if provided.
[ -n "${SMTP_HOST:-}" ]            && vault kv put secret/chronicle/smtp     host="$SMTP_HOST" port="${SMTP_PORT:-587}" user="${SMTP_USER:-}" password="${SMTP_PASSWORD:-}"
[ -n "${TWILIO_SID:-}" ]           && vault kv put secret/chronicle/twilio   sid="$TWILIO_SID" token="${TWILIO_TOKEN:-}" from-phone="${TWILIO_FROM_PHONE:-}"
[ -n "${CROWDSEC_BOUNCER_KEY:-}" ] && vault kv put secret/chronicle/crowdsec bouncer-api-key="$CROWDSEC_BOUNCER_KEY"
[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ] && vault kv put secret/chronicle/grafana admin-password="$GRAFANA_ADMIN_PASSWORD"

# ── 3. Policy + AppRole ───────────────────────────────────────────────────────
vault policy write chronicle-server "$(dirname "$0")/chronicle-server-policy.hcl"
vault auth list | grep -q "^approle/" || vault auth enable approle
vault write auth/approle/role/chronicle-server \
    token_policies="chronicle-server" token_ttl="1h" token_max_ttl="4h" \
    secret_id_ttl="0" secret_id_num_uses="0"

ROLE_ID=$(vault read -field=role_id auth/approle/role/chronicle-server/role-id)
SECRET_ID=$(vault write -field=secret_id -f auth/approle/role/chronicle-server/secret-id)

echo ""
echo "=== Production Vault seeded. Set in the backend env, then restart in a window: ==="
echo "    VAULT_ENABLED=true"
echo "    VAULT_AUTH_METHOD=approle"
echo "    VAULT_APP_ROLE_ID=${ROLE_ID}"
echo "    VAULT_APP_ROLE_SECRET_ID=${SECRET_ID}"
echo "================================================================================="
