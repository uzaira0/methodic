#!/usr/bin/env bash
# Collect database cutover evidence without printing credentials or PHI/ePHI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="${CHRONICLE_DATABASE_EVIDENCE_DIR:-/tmp/chronicle-database-evidence}"
RUN_LIVE=0
REQUIRE_LIVE=0

usage() {
  cat <<'EOF'
Usage: scripts/chronicle-database-evidence.sh [options]

Collects database cutover evidence:
  - canonical checkout proof
  - database-related source/config checksums
  - static database evidence guardrails
  - role/RLS/TDE/audit/TLS posture inventory from tracked files
  - optional live Docker database security audit and RLS guardrails
  - artifact SHA-256 manifest

Options:
  --report-dir DIR    Evidence output directory.
  --live              Run live DB/RLS audits when the local Docker runtime exists.
  --require-live      Require live DB/RLS audits to run and pass.
  -h, --help          Show this help.

The script does not print database passwords, Vault tokens, connection strings,
private keys, kubeconfigs, or row data. Operators may attach the generated,
redacted bundle to their own deployment approval process.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-dir)
      REPORT_DIR="${2:?--report-dir requires a value}"
      shift 2
      ;;
    --live)
      RUN_LIVE=1
      shift
      ;;
    --require-live)
      RUN_LIVE=1
      REQUIRE_LIVE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$REPORT_DIR"
SUMMARY="$REPORT_DIR/summary.tsv"
: > "$SUMMARY"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

record() {
  printf '%s\t%s\t%s\n' "$(timestamp)" "$1" "$2" | tee -a "$SUMMARY"
}

run_step() {
  local name="$1"
  shift
  local logfile="$REPORT_DIR/${name//[^A-Za-z0-9_.-]/_}.log"
  record "$name" "start"
  if "$@" >"$logfile" 2>&1; then
    record "$name" "pass"
  else
    local status=$?
    record "$name" "fail status=$status log=$logfile"
    cat "$logfile" >&2
    exit "$status"
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

database_source_files=(
  "docker/init-db-roles.sql"
  "docker/init-db-encryption.sh"
  "docker/init-audit-immutability.sh"
  "docker/postgres-ssl/pg_hba-ssl.conf"
  "docker/postgres-ssl/postgresql-ssl.conf"
  "k8s/base/postgres.yaml"
  "k8s/base/postgres-init/10-init-db-roles.sql"
  "k8s/base/postgres-init/20-init-db-encryption.sh"
  "k8s/base/postgres-init/25-init-replication.sh"
  "k8s/base/postgres-init/30-init-audit-immutability.sh"
  "tests/security/database-security-tests.sh"
  "tests/security/run-rls-guardrails.sh"
)

copy_database_sources() {
  local list="$REPORT_DIR/database-source-files.tsv"
  : > "$list"
  printf 'path\tsha256\n' >> "$list"
  local rel
  for rel in "${database_source_files[@]}"; do
    if [[ ! -f "$ROOT_DIR/$rel" ]]; then
      printf 'missing\t%s\n' "$rel" >&2
      return 1
    fi
    printf '%s\t%s\n' "$rel" "$(sha256_file "$ROOT_DIR/$rel")" >> "$list"
  done
}

write_static_inventory() {
  python3 - "$ROOT_DIR" "$REPORT_DIR" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
report = pathlib.Path(sys.argv[2])

role_sql = (root / "docker/init-db-roles.sql").read_text(encoding="utf-8")
role_sql_no_comments = re.sub(r"--.*", "", role_sql)
enc_sh = (root / "docker/init-db-encryption.sh").read_text(encoding="utf-8")
pg_hba = (root / "docker/postgres-ssl/pg_hba-ssl.conf").read_text(encoding="utf-8")
pg_ssl = (root / "docker/postgres-ssl/postgresql-ssl.conf").read_text(encoding="utf-8")
k8s_pg = (root / "k8s/base/postgres.yaml").read_text(encoding="utf-8")

checks = [
    ("chronicle_app role exists", "CREATE ROLE chronicle_app WITH" in role_sql),
    ("chronicle_app nonsuperuser", "NOSUPERUSER" in role_sql),
    ("chronicle_app no createdb", "NOCREATEDB" in role_sql),
    ("chronicle_app no createrole", "NOCREATEROLE" in role_sql),
    ("chronicle_app no bypassrls", "BYPASSRLS" not in role_sql_no_comments.split("CREATE ROLE chronicle_admin", 1)[0]),
    ("audit immutability revoke", "REVOKE UPDATE, DELETE" in role_sql),
    ("pg_tde extension configured", "CREATE EXTENSION pg_tde" in enc_sh),
    ("vault provider path exists", "PG_TDE_KEY_PROVIDER" in enc_sh and "chronicle-vault" in enc_sh),
    ("vault https required", "PG_TDE_VAULT_URL must use https://" in enc_sh),
    ("tde verification table encrypted", "pg_tde_is_encrypted" in enc_sh),
    ("hostssl required", re.search(r"^hostssl", pg_hba, re.M) is not None),
    ("no remote trust", " trust" not in "\n".join(line for line in pg_hba.splitlines() if line.strip().startswith("host"))),
    ("postgres ssl enabled", "ssl = on" in pg_ssl),
    ("postgres tls minimum", "ssl_min_protocol_version" in pg_ssl),
    ("scram password encryption", "password_encryption" in pg_ssl and "scram-sha-256" in pg_ssl),
    ("k8s postgres uses app secrets", "chronicle-app-secrets" in k8s_pg),
    ("k8s postgres has probes", "readinessProbe" in k8s_pg and "livenessProbe" in k8s_pg),
]

rows = ["check\tstatus"]
failed = []
for name, ok in checks:
    rows.append(f"{name}\t{'pass' if ok else 'fail'}")
    if not ok:
        failed.append(name)

(report / "database-static-inventory.tsv").write_text("\n".join(rows) + "\n", encoding="utf-8")
(report / "database-static-blockers.txt").write_text("\n".join(failed) + ("\n" if failed else ""), encoding="utf-8")
if failed:
    raise SystemExit("database static evidence blockers: " + ", ".join(failed))
PY
}

run_live_database_audit() {
  if ! command -v docker >/dev/null 2>&1; then
    if [[ "$REQUIRE_LIVE" == "1" ]]; then
      echo "docker is required for --require-live database evidence" >&2
      return 127
    fi
    record "live-database-security-audit" "skip docker not found"
    return 0
  fi
  if ! docker inspect chronicle-postgres >/dev/null 2>&1; then
    if [[ "$REQUIRE_LIVE" == "1" ]]; then
      echo "chronicle-postgres container is required for --require-live database evidence" >&2
      return 1
    fi
    record "live-database-security-audit" "skip chronicle-postgres container not found"
    return 0
  fi
  "$ROOT_DIR/tests/security/database-security-tests.sh"
}

run_live_rls_guardrails() {
  "$ROOT_DIR/tests/security/run-rls-guardrails.sh" "$REPORT_DIR/rls-guardrails"
}

write_manifest() {
  local manifest="$REPORT_DIR/database-evidence-manifest.txt"
  {
    printf 'date_utc=%s\n' "$(timestamp)"
    printf 'repo=%s\n' "$ROOT_DIR"
    printf 'live_requested=%s\n' "$RUN_LIVE"
    printf 'live_required=%s\n' "$REQUIRE_LIVE"
    printf 'strict_cutover_database_evidence=%s\n' "CHRONICLE_DATABASE_EVIDENCE"
    printf 'artifact\tsha256\n'
    for artifact in \
      database-source-files.tsv \
      database-static-inventory.tsv \
      database-static-blockers.txt \
      database-evidence-guardrails/database-evidence-guardrails.txt; do
      printf '%s\t%s\n' "$artifact" "$(sha256_file "$REPORT_DIR/$artifact")"
    done
  } > "$manifest"
}

run_step "canonical-preflight-explain" "${REPO_CANONICAL_PREFLIGHT:-repo-canonical-preflight}" --explain
run_step "canonical-preflight" "${REPO_CANONICAL_PREFLIGHT:-repo-canonical-preflight}"
run_step "database-source-checksums" copy_database_sources
run_step "database-static-inventory" write_static_inventory
run_step "database-evidence-guardrails" "$ROOT_DIR/tests/security/database-evidence-guardrails.sh" "$REPORT_DIR/database-evidence-guardrails"
if [[ "$RUN_LIVE" == "1" ]]; then
  run_step "live-database-security-audit" run_live_database_audit
  run_step "live-rls-guardrails" run_live_rls_guardrails
else
  record "live-database-security-audit" "skip --live not set"
  record "live-rls-guardrails" "skip --live not set"
fi
run_step "write-database-evidence-manifest" write_manifest

record "evidence" "complete report_dir=$REPORT_DIR"
printf 'Chronicle database evidence complete: %s\n' "$REPORT_DIR"
