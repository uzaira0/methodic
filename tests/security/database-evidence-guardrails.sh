#!/usr/bin/env bash
# Static guardrails for reusable database security evidence.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REPORT_DIR="${1:-/tmp/chronicle-database-evidence-guardrails}"
REPORT_FILE="$REPORT_DIR/database-evidence-guardrails.txt"

mkdir -p "$REPORT_DIR"
: > "$REPORT_FILE"
failures=0

record() {
  printf '%s\n' "$*" | tee -a "$REPORT_FILE"
}

fail() {
  failures=$((failures + 1))
  record "[fail] $*"
}

pass() {
  record "[ok] $*"
}

require_file() {
  local path="$1"
  if [ -f "$ROOT_DIR/$path" ]; then
    pass "found $path"
  else
    fail "missing $path"
  fi
}

require_pattern() {
  local path="$1"
  local pattern="$2"
  local description="$3"
  if grep -Eq -- "$pattern" "$ROOT_DIR/$path"; then
    pass "$description"
  else
    fail "$description"
  fi
}

reject_pattern() {
  local path="$1"
  local pattern="$2"
  local description="$3"
  if grep -Eq -- "$pattern" "$ROOT_DIR/$path"; then
    fail "$description"
  else
    pass "$description"
  fi
}

record "Chronicle database evidence guardrails"

require_file "scripts/chronicle-database-evidence.sh"
require_file "tests/security/database-security-tests.sh"
require_file "tests/security/run-rls-guardrails.sh"
require_file "docker/init-db-roles.sql"
require_file "k8s/base/postgres-init/10-init-db-roles.sql"
require_file "docker/init-db-encryption.sh"
require_file "scripts/verify-schema-postconditions.sh"
require_file "scripts/local-ci.sh"

require_pattern "scripts/chronicle-database-evidence.sh" 'database-static-inventory\.tsv'   "database evidence writes a static posture inventory"
require_pattern "scripts/chronicle-database-evidence.sh" 'database-source-files\.tsv'   "database evidence writes a source checksum inventory"
require_pattern "scripts/chronicle-database-evidence.sh" 'database-evidence-manifest\.txt'   "database evidence writes an artifact checksum manifest"
require_pattern "scripts/chronicle-database-evidence.sh" '--require-live'   "database evidence can fail closed when a live audit is required"
require_pattern "tests/security/database-security-tests.sh" 'Request role .* cannot bypass row-level security'   "database audit checks that the request role cannot bypass RLS"
require_pattern "tests/security/database-security-tests.sh" 'pg_tde extension loaded'   "database audit checks pg_tde"
require_pattern "tests/security/database-security-tests.sh" 'hostssl entries present'   "database audit checks PostgreSQL TLS authentication"
require_pattern "tests/security/run-rls-guardrails.sh" 'RLS guardrails passed'   "focused RLS guardrails have an explicit all-clear result"
require_pattern "docker/init-db-roles.sql" 'CREATE ROLE chronicle_app WITH'   "database bootstrap creates the application role"
require_pattern "docker/init-db-roles.sql" 'NOSUPERUSER'   "application database role remains non-superuser"
require_pattern "docker/init-db-roles.sql" "'mobile_withdrawal_requests'"   "Docker bootstrap re-revokes mobile withdrawal receipt mutation"
require_pattern "docker/init-db-roles.sql" 'REVOKE INSERT ON mobile_withdrawal_requests FROM chronicle_admin'   "Docker bootstrap prevents admin-forged withdrawal receipts"
require_pattern "docker/init-db-roles.sql" 'REVOKE CREATE ON SCHEMA public FROM chronicle_app, chronicle_admin'   "Docker bootstrap prevents runtime-owned schema objects"
require_pattern "docker/init-db-roles.sql" 'REVOKE EXECUTE ON FUNCTION public.record_data_collection_settings_revision'   "Docker bootstrap prevents direct revision-recorder calls"
require_pattern "docker/init-db-roles.sql" 'REVOKE INSERT, UPDATE, DELETE, TRUNCATE'   "Docker bootstrap protects the immutable settings-revision ledger"
require_pattern "docker/init-db-roles.sql" 'restore_continuity_reconciliations'   "Docker bootstrap protects restore reconciliation receipts"
require_pattern "docker/init-db-roles.sql" "'audit',[[:space:]]*$"   "Docker bootstrap includes the final audit table in its immutable registry"
require_pattern "docker/init-db-roles.sql" "'audit_buffer',[[:space:]]*$"   "Docker bootstrap includes the final audit buffer in its immutable registry"
require_pattern "k8s/base/postgres-init/10-init-db-roles.sql" "'mobile_withdrawal_requests'"   "Kubernetes bootstrap re-revokes mobile withdrawal receipt mutation"
require_pattern "k8s/base/postgres-init/10-init-db-roles.sql" 'REVOKE INSERT ON mobile_withdrawal_requests FROM chronicle_admin'   "Kubernetes bootstrap prevents admin-forged withdrawal receipts"
require_pattern "k8s/base/postgres-init/10-init-db-roles.sql" 'REVOKE CREATE ON SCHEMA public FROM chronicle_app, chronicle_admin'   "Kubernetes bootstrap prevents runtime-owned schema objects"
require_pattern "k8s/base/postgres-init/10-init-db-roles.sql" 'REVOKE EXECUTE ON FUNCTION public.record_data_collection_settings_revision'   "Kubernetes bootstrap prevents direct revision-recorder calls"
require_pattern "k8s/base/postgres-init/10-init-db-roles.sql" 'REVOKE INSERT, UPDATE, DELETE, TRUNCATE'   "Kubernetes bootstrap protects the immutable settings-revision ledger"
require_pattern "k8s/base/postgres-init/10-init-db-roles.sql" 'restore_continuity_reconciliations'   "Kubernetes bootstrap protects restore reconciliation receipts"
require_pattern "k8s/base/postgres-init/10-init-db-roles.sql" "'audit',[[:space:]]*$"   "Kubernetes bootstrap includes the final audit table in its immutable registry"
require_pattern "k8s/base/postgres-init/10-init-db-roles.sql" "'audit_buffer',[[:space:]]*$"   "Kubernetes bootstrap includes the final audit buffer in its immutable registry"
for init_script in docker/init-audit-immutability.sh k8s/base/postgres-init/30-init-audit-immutability.sh; do
  require_pattern "$init_script" 'REVOKE DELETE, UPDATE, TRUNCATE ON audit FROM chronicle_app, chronicle_admin'   "$init_script protects final audit rows from both runtime roles"
  require_pattern "$init_script" 'REVOKE DELETE, UPDATE, TRUNCATE ON audit_buffer FROM chronicle_app, chronicle_admin'   "$init_script protects final audit-buffer rows from both runtime roles"
done
require_pattern "scripts/verify-schema-postconditions.sh" 'mobile_withdrawal_requests:TRUNCATE'   "live schema verification checks withdrawal receipt immutability"
require_pattern "scripts/verify-schema-postconditions.sh" "has_table_privilege\('chronicle_admin', 'public.mobile_withdrawal_requests', 'INSERT'\)"   "live schema verification rejects admin-forged withdrawal receipts"
require_pattern "scripts/verify-schema-postconditions.sh" "has_schema_privilege\('chronicle_app', 'public', 'CREATE'\)"   "live schema verification rejects runtime schema creation"
require_pattern "scripts/verify-schema-postconditions.sh" "has_function_privilege\('chronicle_app', 'public.record_data_collection_settings_revision\(\)', 'EXECUTE'\)"   "live schema verification rejects direct revision-recorder calls"
require_pattern "scripts/verify-schema-postconditions.sh" 'data_collection_settings_revisions:INSERT'   "live schema verification checks settings-revision immutability"
require_pattern "scripts/verify-schema-postconditions.sh" 'restore_continuity_reconciliations:TRUNCATE'   "live schema verification checks restore-receipt immutability"
require_pattern "scripts/verify-schema-postconditions.sh" 'RESTORE_APP_SELECT'   "live schema verification prevents application receipt reads"
require_pattern "scripts/verify-schema-postconditions.sh" 'audit:TRUNCATE'   "live schema verification checks final audit-table immutability"
require_pattern "scripts/verify-schema-postconditions.sh" 'audit_buffer:TRUNCATE'   "live schema verification checks final audit-buffer immutability"
if grep -Eq 'docker[[:space:]]+exec([^[:cntrl:]]|\\$)*-e[[:space:]]+PGPASSWORD=' \
  "$ROOT_DIR/scripts/verify-schema-postconditions.sh"; then
  fail "live schema verification exposes PGPASSWORD in Docker process arguments"
else
  pass "live schema verification keeps PGPASSWORD off Docker process arguments"
fi
require_pattern "docker/RLS-SETUP.md" 'distinct offline schema owner, never this BYPASSRLS role'   "RLS guidance separates migration ownership from BYPASSRLS administration"
require_pattern "k8s/base/postgres-init/10-init-db-roles.sql" 'Run Flyway as the offline schema owner'   "Kubernetes bootstrap keeps migrations out of the BYPASSRLS admin role"
require_pattern "docker/init-db-encryption.sh" 'PG_TDE_KEY_PROVIDER'   "TDE initialization selects an external key provider"
require_pattern "docker/init-db-encryption.sh" 'PG_TDE_VAULT_URL must use https://'   "Vault-backed TDE refuses insecure Vault URLs"
require_pattern "scripts/local-ci.sh" '^PG_TDE_KEY_PROVIDER=file$'   "HTTP smoke initializes pg_tde before creating tde_heap tables"
require_pattern "docker/docker-compose.traefik.yml" 'chown -R 26:26 /var/lib/postgresql/tde-keyring'   "Postgres entrypoint must transfer fresh TDE keyring volume ownership before initdb drops privileges"
require_pattern "docker/docker-compose.traefik.yml" 'user: "0:0"'   "Postgres volume-preparation wrapper must start with the authority needed to transfer fresh named-volume ownership"
require_pattern "docker/docker-compose.traefik.yml" 'chmod 700 /var/lib/postgresql/tde-keyring'   "Postgres entrypoint must protect the TDE keyring before initialization"
require_pattern "docker/docker-compose.traefik.yml" '/data/db/wal_archive'   "Postgres WAL archiving must use the durable database volume"
reject_pattern "docker/docker-compose.traefik.yml" '/pgdata/wal_archive'   "Postgres WAL archiving must not target the stale non-writable path"
reject_pattern "docker/init-audit-immutability.sh" '/pgdata/wal_archive'   "Audit bootstrap must not recreate the stale non-writable WAL path"
reject_pattern "k8s/base/postgres-init/30-init-audit-immutability.sh" '/pgdata/wal_archive'   "Kubernetes audit bootstrap must not recreate the stale non-writable WAL path"
require_pattern "scripts/local-ci.sh" 'logs postgres --tail=160'   "HTTP smoke must retain PostgreSQL initialization diagnostics on readiness failure"

if [ -e "$ROOT_DIR/docker/migrations/C7-create-app-user.sql" ]; then
  fail "obsolete manual role bootstrap can re-grant immutable-table mutation privileges"
else
  pass "obsolete manual role bootstrap is retired"
fi

if grep -Eq 'private[-_]deployment[-_]evidence|tenant[-_]specific[-_]evidence'     "$ROOT_DIR/scripts/chronicle-database-evidence.sh"; then
  fail "database evidence must not depend on private tenant artifacts"
else
  pass "database evidence is independent of private tenant artifacts"
fi

if [ "$failures" -gt 0 ]; then
  record "Database evidence guardrails failed with $failures finding(s)"
  exit 1
fi

record "Database evidence guardrails passed"
