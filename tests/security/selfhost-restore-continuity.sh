#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RESTORE_SCRIPT="${ROOT_DIR}/selfhost/restore.sh"
OPERATOR_CLI="${ROOT_DIR}/selfhost/chronicle"
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
  'checkpoint_sha256' \
  'sha256(' \
  'FROM PUBLIC, chronicle_app, chronicle_admin' \
  '--schema=chronicle_restore_continuity' \
  '--exclude-schema=chronicle_restore_continuity' \
  'CONTINUITY_DUMP' \
  '/bin/chmod 0600 "$CONTINUITY_DUMP"' \
  'gzip -t "$CONTINUITY_DUMP"' \
  '/bin/rm -f -- "$CONTINUITY_DUMP"' \
  'UPDATE public.api_keys' \
  'UPDATE public.study_participants'; do
  grep -Fq -- "$required" "$RESTORE_SCRIPT" || fail "restore omits required continuity contract: $required"
done

capture_line="$(grep -n 'CREATE SCHEMA chronicle_restore_continuity' "$RESTORE_SCRIPT" | head -1 | cut -d: -f1)"
drop_line="$(grep -n 'dropping the existing schema' "$RESTORE_SCRIPT" | tail -1 | cut -d: -f1)"
restore_line="$(grep -n 'restoring \${RESTORE_FILE}' "$RESTORE_SCRIPT" | tail -1 | cut -d: -f1)"
containment_line="$(grep -n 'UPDATE public.study_participants' "$RESTORE_SCRIPT" | tail -1 | cut -d: -f1)"
success_line="$(grep -n 'database restore complete' "$RESTORE_SCRIPT" | tail -1 | cut -d: -f1)"

[[ -n "$capture_line" && -n "$drop_line" && -n "$restore_line" && -n "$containment_line" && -n "$success_line" ]] ||
  fail "restore continuity phases could not be located"
((capture_line < drop_line && drop_line < restore_line && restore_line < containment_line && containment_line < success_line)) ||
  fail "restore continuity capture/containment phases are out of order"

if sed -n '/CREATE SCHEMA chronicle_restore_continuity/,/dropping the existing schema/p' "$RESTORE_SCRIPT" |
    grep -Eq '(^|[^[:alnum:]_])(api_key|token|secret|password)([^[:alnum:]_]|$)'; then
  fail "continuity checkpoint persists credential material instead of non-secret identifiers"
fi

grep -Fq 'DROP SCHEMA chronicle_restore_continuity' "$RESTORE_SCRIPT" &&
  fail "restore script must leave the checkpoint for server-side verified reconciliation"

grep -Fq 'CHRONICLE_RESTORE_LEAVE_STOPPED=true' "$OPERATOR_CLI" ||
  fail "operator rollback does not request exact protected-evidence verification"
for required in \
  'rollback backup already contains protected continuity evidence' \
  'chronicle_restore_continuity.deletion_operations source' \
  'chronicle_restore_continuity.retention_holds source' \
  'chronicle_restore_continuity.deletion_tombstones source' \
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

python3 - "$RESTORE_SCRIPT" "$SERVER_RECONCILER" <<'PY'
import re
import sys
from pathlib import Path

restore = Path(sys.argv[1]).read_text(encoding="utf-8")
server = Path(sys.argv[2]).read_text(encoding="utf-8")

def normalize(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip())

try:
    restore_tail = restore.split("WITH canonical(line) AS (", 1)[1]
    restore_canonical, restore_digest_tail = restore_tail.split("), digest AS (", 1)
    server_tail = server.split("WITH canonical(line) AS (", 1)[1]
    server_canonical, server_digest_tail = server_tail.split(
        ")\n            SELECT encode(", 1
    )
except (IndexError, ValueError) as error:
    raise SystemExit(f"unable to locate both checkpoint digest contracts: {error}") from error

if normalize(restore_canonical) != normalize(server_canonical):
    raise SystemExit("restore and server canonical checkpoint rows have drifted")

restore_digest = restore_digest_tail.split("FROM canonical", 1)[0]
server_digest = "SELECT encode(" + server_digest_tail.split("FROM canonical", 1)[0]
restore_digest = re.sub(r"\s+AS\s+value\s*$", "", normalize(restore_digest), flags=re.I)
if restore_digest != normalize(server_digest):
    raise SystemExit("restore and server checkpoint hash aggregation have drifted")
PY

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
