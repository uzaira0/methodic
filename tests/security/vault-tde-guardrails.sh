#!/usr/bin/env bash
set -euo pipefail

REPORT_DIR="${1:-/tmp/chronicle-vault-tde-guardrails}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$REPORT_DIR"

DEPLOY_SCRIPT="${ROOT_DIR}/scripts/deploy.sh"
INIT_DB_ENCRYPTION="${ROOT_DIR}/docker/init-db-encryption.sh"
INIT_VAULT="${ROOT_DIR}/docker/init-vault.sh"
INIT_DEV_VAULT="${ROOT_DIR}/docker/vault/init-dev-secrets.sh"
ROTATE_TDE="${ROOT_DIR}/scripts/rotate-tde-principal-key.sh"
PRODUCTION_ENV_TEMPLATE="${ROOT_DIR}/docker/.env.production"

fail() {
  echo "vault/TDE guardrail failed: $*" >&2
  exit 1
}

require_pattern() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Eq -- "$pattern" "$file"; then
    fail "$message ($file)"
  fi
}

reject_pattern() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if grep -Eq -- "$pattern" "$file"; then
    fail "$message ($file)"
  fi
}

for file in "$DEPLOY_SCRIPT" "$INIT_DB_ENCRYPTION" "$INIT_VAULT" "$INIT_DEV_VAULT" "$ROTATE_TDE"; do
  [ -f "$file" ] || fail "required script missing: $file"
  bash -n "$file"
done

require_pattern "$DEPLOY_SCRIPT" 'require_env_url_scheme' \
  "deploy script must enforce URL schemes for production endpoints"
require_pattern "$DEPLOY_SCRIPT" 'PG_TDE_VAULT_URL"[[:space:]]+"https' \
  "production deploy must require HTTPS for the TDE Vault URL"
require_pattern "$DEPLOY_SCRIPT" 'VAULT_ADDR"[[:space:]]+"https' \
  "production deploy must require HTTPS for the application Vault URL"
require_pattern "$DEPLOY_SCRIPT" 'VAULT_ENABLED"[[:space:]]+"true' \
  "production deploy must require Vault-backed application secret loading"
require_pattern "$DEPLOY_SCRIPT" 'VAULT_TOKEN' \
  "production deploy must require an application Vault token"

require_pattern "$PRODUCTION_ENV_TEMPLATE" '^PG_TDE_VAULT_URL=https://' \
  "production env template must document HTTPS for TDE Vault"
require_pattern "$PRODUCTION_ENV_TEMPLATE" '^VAULT_ADDR=https://' \
  "production env template must document HTTPS for application Vault"
require_pattern "$PRODUCTION_ENV_TEMPLATE" '^VAULT_ENABLED=true$' \
  "production env template must enable Vault"

require_pattern "$INIT_DB_ENCRYPTION" 'PG_TDE_ALLOW_INSECURE_VAULT' \
  "TDE init must require an explicit local-development override for insecure Vault"
require_pattern "$INIT_DB_ENCRYPTION" 'PG_TDE_VAULT_TOKEN_PATH' \
  "TDE init must consume the Vault token through a mounted private file"
require_pattern "$INIT_DB_ENCRYPTION" '-v vault_token_path=' \
  "TDE init must pass only the Vault token file path through psql variables"
require_pattern "$INIT_DB_ENCRYPTION" ":.'vault_token_path'|:'vault_token_path'" \
  "TDE init SQL must use the psql-quoted Vault token file path"
reject_pattern "$INIT_DB_ENCRYPTION" '-v vault_token=' \
  "TDE init must not expose the Vault token value through psql command arguments"
reject_pattern "$INIT_DB_ENCRYPTION" "'\\$\\{PG_TDE_VAULT_TOKEN\\}'" \
  "TDE init SQL must not interpolate the Vault token directly"
require_pattern "$INIT_DB_ENCRYPTION" "format\\(" \
  "TDE init must build conversion SQL with PostgreSQL format()"
require_pattern "$INIT_DB_ENCRYPTION" "'ALTER TABLE public.%I SET ACCESS METHOD tde_heap'" \
  "TDE init must quote table identifiers when converting to tde_heap"

require_pattern "$INIT_VAULT" 'CHRONICLE_ALLOW_INSECURE_VAULT' \
  "Vault init must require an explicit local-development override for HTTP Vault"
require_pattern "$INIT_VAULT" 'Vault address is required' \
  "Vault init must require an explicit Vault address"
reject_pattern "$INIT_VAULT" 'VAULT_ADDR="\$\{VAULT_ADDR:-http://' \
  "Vault init must not default to plaintext HTTP Vault"
require_pattern "$INIT_VAULT" 'VAULT_APPROLE_SECRET_ID_TTL' \
  "Vault init must make AppRole secret ID TTL explicit"
reject_pattern "$INIT_VAULT" 'secret_id_ttl="0"' \
  "Vault init must not create non-expiring AppRole secret IDs"
require_pattern "$INIT_VAULT" '--tde-key-file' \
  "Vault init must accept the TDE key only through a protected file"
require_pattern "$INIT_VAULT" 'require_private_secret_file "\$TDE_KEY_FILE" "TDE key input"' \
  "Vault init must validate the TDE key input"
require_pattern "$INIT_VAULT" 'must have mode 0600' \
  "Vault init must enforce mode 0600 on secret-file input"
require_pattern "$INIT_VAULT" 'vault operator unseal <' \
  "Vault init must pass unseal shares through stdin"
reject_pattern "$INIT_VAULT" 'vault operator unseal "?\$' \
  "Vault init must not place unseal shares in process arguments"
require_pattern "$INIT_VAULT" 'vault kv put "\$secret_path" -' \
  "Vault init must stream secret payloads to Vault over stdin"
reject_pattern "$INIT_VAULT" 'vault kv put .*\b(password|secret|key)=' \
  "Vault init must not place secret values in Vault command arguments"
require_pattern "$INIT_VAULT" 'chmod 600 "\$\{OUTPUT_DIR\}/vault-env-snippet.txt"' \
  "Vault init must protect the generated credential handoff file"
reject_pattern "$INIT_VAULT" 'Role ID:[[:space:]]+\$\{APPROLE_ROLE_ID\}' \
  "Vault init must not print AppRole identifiers into operator logs"

require_pattern "$INIT_DEV_VAULT" 'chmod 600 "\$BOOTSTRAP_DIR/approle-role-id" "\$BOOTSTRAP_DIR/approle-secret-id"' \
  "Development Vault init must protect generated AppRole credentials"
reject_pattern "$INIT_DEV_VAULT" 'Root token:[[:space:]]+\$\{|AppRole Secret:[[:space:]]+\$\{|VAULT_TOKEN=\$\{' \
  "Development Vault init must not print usable credentials"

require_pattern "$ROTATE_TDE" '\.env\.production\.local' \
  "TDE rotation must prefer the untracked production env file"
require_pattern "$ROTATE_TDE" 'CHRONICLE_ENV_FILE' \
  "TDE rotation must support an explicit env file"
require_pattern "$ROTATE_TDE" 'PG_TDE_VAULT_URL must use https://' \
  "TDE rotation must reject plaintext Vault metadata updates"

cat > "${REPORT_DIR}/vault-tde-guardrails.txt" <<EOF
Vault/TDE guardrails passed.
Validated scripts:
- ${DEPLOY_SCRIPT}
- ${INIT_DB_ENCRYPTION}
- ${INIT_VAULT}
- ${ROTATE_TDE}
EOF

cat "${REPORT_DIR}/vault-tde-guardrails.txt"
