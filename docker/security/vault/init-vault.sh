#!/bin/bash
# Vault initialization and secret seeding script for Chronicle
# Run once after first deployment: docker exec chronicle-vault sh /vault/scripts/init-vault.sh
#
# Prerequisites: .env file with all secrets set
# Output: unseal keys and root token (SAVE THESE SECURELY)

set -euo pipefail

VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_ADDR

echo "=== Chronicle Vault Initialization ==="

# Check if already initialized
if vault status 2>/dev/null | grep -q "Initialized.*true"; then
    echo "Vault is already initialized."
    if vault status 2>/dev/null | grep -q "Sealed.*true"; then
        echo "ERROR: Vault is sealed. Unseal with: vault operator unseal <key>"
        exit 1
    fi
    echo "Vault is unsealed and ready."
    exit 0
fi

echo "Initializing Vault with 3 key shares, 2 required to unseal..."
INIT_OUTPUT=$(vault operator init -key-shares=3 -key-threshold=2 -format=json)

echo ""
echo "================================================================"
echo "CRITICAL: Save the following keys securely (e.g., password manager)"
echo "You need 2 of 3 keys to unseal Vault after a restart."
echo "================================================================"
echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[] | "Unseal Key: " + .'
echo ""
echo "Root Token: $(echo "$INIT_OUTPUT" | jq -r '.root_token')"
echo "================================================================"

# Auto-unseal for initial setup
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')
UNSEAL_KEY_1=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
UNSEAL_KEY_2=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[1]')

vault operator unseal "$UNSEAL_KEY_1"
vault operator unseal "$UNSEAL_KEY_2"

export VAULT_TOKEN="$ROOT_TOKEN"

# Enable KV secrets engine v2
vault secrets enable -path=chronicle kv-v2

echo ""
echo "Vault initialized and unsealed. KV engine enabled at chronicle/."
echo ""
echo "To seed secrets from .env, run:"
echo "  vault kv put chronicle/database password=\$POSTGRES_PASSWORD user=\$POSTGRES_USER"
echo "  vault kv put chronicle/jwt secret=\$JWT_SECRET"
echo "  vault kv put chronicle/smtp host=\$SMTP_HOST port=\$SMTP_PORT user=\$SMTP_USERNAME password=\$SMTP_PASSWORD"
echo ""
echo "Enable audit logging:"
echo "  vault audit enable file file_path=/vault/logs/audit.log"
