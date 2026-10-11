#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RESTORE_SCRIPT="${ROOT_DIR}/selfhost/restore.sh"
SERVER_RECONCILER="${ROOT_DIR}/chronicle-server/src/main/kotlin/com/openlattice/chronicle/services/delete/RestoreContinuityReconciler.kt"
SERVER_MIGRATION="${ROOT_DIR}/chronicle-server/src/main/resources/db/migration/V98__record_restore_continuity_reconciliation.sql"
SERVER_AUTHORITY_MIGRATION="${ROOT_DIR}/chronicle-server/src/main/resources/db/migration/V100__extend_restore_continuity_authority.sql"

fail() {
  echo "self-host restore continuity guard failed: $*" >&2
  exit 1
}

bash -n "$RESTORE_SCRIPT"

for required in \
  'CREATE SCHEMA chronicle_restore_continuity' \
  'chronicle_restore_continuity.checkpoint' \
  'chronicle_restore_continuity.withdrawal_requests' \
  'chronicle_restore_continuity.revoked_api_keys' \
  'chronicle_restore_continuity.withdrawn_participants' \
  'chronicle_restore_continuity.deletion_operations' \
  'chronicle_restore_continuity.retention_holds' \
  'chronicle_restore_continuity.deletion_tombstones' \
  'chronicle_restore_continuity.data_collection_settings_revisions' \
  'chronicle_restore_continuity.published_data_collection_settings' \
  'chronicle_restore_continuity.enrollment_invitations' \
  'chronicle_restore_continuity.erased_device_key_tombstones' \
  'participant_block_token' \
  'checkpoint_sha256' \
  'FROM PUBLIC, chronicle_app, chronicle_admin' \
  '--schema=chronicle_restore_continuity' \
  '--exclude-schema=chronicle_restore_continuity' \
  'CONTINUITY_DUMP' \
  '/bin/chmod 0600 "$CONTINUITY_DUMP"' \
  'verify_restore_dump "$CONTINUITY_DUMP"' \
  '/bin/rm -f -- "$CONTINUITY_DUMP"' \
  'UPDATE public.api_keys' \
  'UPDATE public.study_participants'; do
  grep -Fq -- "$required" "$RESTORE_SCRIPT" || fail "restore omits required continuity contract: $required"
done

capture_line="$(grep -n 'CREATE SCHEMA chronicle_restore_continuity' "$RESTORE_SCRIPT" | head -1 | cut -d: -f1)"
capture_invocation="$(grep -B1 '^CREATE SCHEMA chronicle_restore_continuity;' "$RESTORE_SCRIPT" | head -1)"
[[ "$capture_invocation" == "  psql_q -1 <<SQL >/dev/null" ]] ||
  fail "checkpoint capture must run as one transaction"
drop_line="$(grep -n 'dropping the existing schema' "$RESTORE_SCRIPT" | tail -1 | cut -d: -f1)"
restore_line="$(grep -n 'restoring \${RESTORE_FILE}' "$RESTORE_SCRIPT" | tail -1 | cut -d: -f1)"
containment_line="$(grep -n 'UPDATE public.study_participants' "$RESTORE_SCRIPT" | tail -1 | cut -d: -f1)"
success_line="$(grep -n 'database restore complete' "$RESTORE_SCRIPT" | tail -1 | cut -d: -f1)"

[[ -n "$capture_line" && -n "$drop_line" && -n "$restore_line" && -n "$containment_line" && -n "$success_line" ]] ||
  fail "restore continuity phases could not be located"
((capture_line < drop_line && drop_line < restore_line && restore_line < containment_line && containment_line < success_line)) ||
  fail "restore continuity capture/containment phases are out of order"
contract_line="$(grep -n 'SELECT contract_version FROM chronicle_restore_continuity.checkpoint' "$RESTORE_SCRIPT" | head -1 | cut -d: -f1 || true)"
[[ -n "$contract_line" ]] && ((contract_line < drop_line)) ||
  fail "restore does not check a reused checkpoint's contract before dropping the schema"

if sed -n '/^CHECKPOINT_DIGEST_SQL=/,/^SQL$/p; /CREATE SCHEMA chronicle_restore_continuity/,/^SQL$/p' "$RESTORE_SCRIPT" |
    grep -Eq '(^|[^[:alnum:]_])(api_key|token|secret|password)([^[:alnum:]_]|$)'; then
  fail "continuity checkpoint persists credential material instead of non-secret identifiers"
fi

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${ROOT_DIR}/tests/selfhost-py:${ROOT_DIR}/selfhost" \
  python3 -m unittest test_restore.RestoreTests.test_no_start \
  test_restore.RestoreTests.test_rollback_transaction_refusal_resumes_current_services_and_releases_lock \
  test_restore.RestoreTransactionTests.test_continuity_proof_and_dump_share_transaction_and_producer_failure_cannot_commit
for required in \
  'rollback backup already contains protected continuity evidence' \
  "('deletion_operations', 'data_deletion_operations')" \
  "('retention_holds', 'retention_holds')" \
  "('deletion_tombstones', 'data_deletion_tombstones')" \
  'selected rollback backup predates'; do
  grep -Fq "$required" "$RESTORE_SCRIPT" ||
    fail "rollback continuity comparison omits: $required"
done

[[ -f "$SERVER_RECONCILER" ]] || fail "server startup reconciler is missing"
[[ -f "$SERVER_MIGRATION" ]] || fail "immutable reconciliation receipt migration is missing"
[[ -f "$SERVER_AUTHORITY_MIGRATION" ]] || fail "continuity authority extension migration is missing"
grep -Fq 'DROP SCHEMA chronicle_restore_continuity' "$SERVER_RECONCILER" ||
  fail "server reconciler does not consume the checkpoint after verified replay"
grep -Fq 'restore_continuity_reconciliations' "$SERVER_MIGRATION" ||
  fail "migration does not create the durable reconciliation receipt"
grep -Fq 'already_protected_deletion_count' "$SERVER_MIGRATION" ||
  fail "reconciliation receipt does not distinguish existing proof from physical replay"
for required in \
  'contract_version IN (1, 2)' \
  'collection_revision_count' \
  'published_collection_settings_count' \
  'enrollment_invitation_count'; do
  grep -Fq "$required" "$SERVER_AUTHORITY_MIGRATION" ||
    fail "continuity authority receipt migration omits: $required"
done

# Both runtimes consume the same SQL resource copied by processResources.
[[ -s "${ROOT_DIR}/selfhost/restore-continuity-digest.sql" ]] ||
  fail "shared checkpoint digest resource is missing"

for bootstrap in \
  "${ROOT_DIR}/docker/init-db-roles.sql" \
  "${ROOT_DIR}/k8s/base/postgres-init/10-init-db-roles.sql"; do
  grep -Fq 'REVOKE ALL ON restore_continuity_reconciliations FROM chronicle_app' "$bootstrap" ||
    fail "$(basename "$bootstrap") can regrant application access to restore receipts"
  bootstrap_sql="$(tr '\n' ' ' < "$bootstrap")"
  grep -Eq 'REVOKE INSERT, UPDATE, DELETE, TRUNCATE[[:space:]]+ON restore_continuity_reconciliations FROM chronicle_admin' \
    <<< "$bootstrap_sql" ||
    fail "$(basename "$bootstrap") can regrant admin mutation of restore receipts"
done

grep -Fq 'restore_continuity_reconciliations:TRUNCATE' \
  "${ROOT_DIR}/scripts/verify-schema-postconditions.sh" ||
  fail "schema postconditions omit restore receipt immutability"

echo "self-host restore continuity guard passed"
