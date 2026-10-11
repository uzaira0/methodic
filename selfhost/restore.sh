#!/usr/bin/env bash
# Restore a dump over an EXISTING database, run as a one-shot compose service so the whole
# procedure is owned by `./chronicle restore` rather than a hand-assembled psql pipeline.
#
# Why this exists rather than the operator piping a dump into psql: piping a dump into a
# database that already has the schema does not fail, it CORRUPTS. Every CREATE fails with
# "already exists" and is skipped, and then each COPY appends its rows into the table that is
# already there. Tables with a primary key reject the duplicates -- noisily, but harmlessly.
# Tables WITHOUT one silently end up with every row twice. `audit` is such a table, so the
# compliance trail is precisely what doubles. psql still exits 0 through all of it, so the
# operator is told the restore succeeded. Measured on a real bundle dump: 568 errors,
# exit code 0, audit 216 rows -> 432.
#
# Schema replacement and its postconditions share one transaction with ON_ERROR_STOP so a
# rejected restore rolls back to the live data.
#
#   ./chronicle restore --trusted-sha256=REVIEWED_SHA256 /backups/path/to/dump.sql.gz
#
# The CLI stops the backend, dashboard proxy, database-initialization job, and backup
# sidecar before invoking this one-shot service. It holds a state-directory operation lock
# against upgrade and secret rotation, verifies that the writers really stopped, and starts
# the stack only after this script succeeds. db-init then re-encrypts anything that arrived
# on plain heap (a dump from an unencrypted instance restores as unencrypted tables;
# init-tde.sh fixes that).

set -euo pipefail
umask 077

if [[ "${CHRONICLE_RESTORE_ORCHESTRATED:-}" != true ]]; then
  echo "  FAIL direct restore-service execution is disabled because application writers may still be running" >&2
  echo "       run the guarded operator command instead:" >&2
  echo "         ./chronicle restore [--yes] --trusted-sha256=REVIEWED_SHA256 /backups/path/to/dump.sql.gz" >&2
  exit 1
fi
unset CHRONICLE_RESTORE_ORCHESTRATED

BACKUPS_DIR="${BACKUPS_DIR:-/backups}"
DEFAULT_DUMP="${BACKUPS_DIR}/last/chronicle-latest.sql.gz"
RESTORE_FILE="${RESTORE_FILE:-$DEFAULT_DUMP}"

psql_q() {
  PGPASSWORD="$POSTGRES_PASSWORD" psql \
    -h "${POSTGRES_HOST:-postgres}" -p "${POSTGRES_PORT:-5432}" \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -X -v ON_ERROR_STOP=1 -tAq "$@"
}

verify_restore_dump() {
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/selfhost python3 -m chronicle_ops.dump "$@"
}

RESTORE_SQL_DIR="$(dirname "${BASH_SOURCE[0]}")"
CHECKPOINT_DIGEST_SQL=$(cat "$RESTORE_SQL_DIR/restore-continuity-digest.sql")
RESTRICTIONS_SCHEMA_SQL=$(cat "$RESTORE_SQL_DIR/restore-restrictions-schema.sql")
AUTHORITIES_SCHEMA_SQL=$(cat "$RESTORE_SQL_DIR/restore-authorities-schema.sql")
RESTRICTIONS_CONTAINMENT_SQL=$(cat "$RESTORE_SQL_DIR/restore-restrictions-containment.sql")
RESTORE_CONTINUITY_CONTRACT_VERSION=$(cat "$RESTORE_SQL_DIR/restore-continuity.version")
readonly CHECKPOINT_DIGEST_SQL RESTORE_CONTINUITY_CONTRACT_VERSION
DATABASE_PRIVILEGES_SQL=$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/selfhost python3 -c \
  'from chronicle_ops.verify import DATABASE_PRIVILEGES_SQL; print(DATABASE_PRIVILEGES_SQL)')
EXIT_RESTORE_TRANSACTION_ROLLED_BACK=$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/selfhost python3 -c \
  'from chronicle_ops.dump import EXIT_RESTORE_TRANSACTION_ROLLED_BACK; print(EXIT_RESTORE_TRANSACTION_ROLLED_BACK)')

# ---------------------------------------------------------------------------------------
# 1. The dump must exist and be readable BEFORE anything is dropped.
# ---------------------------------------------------------------------------------------
if [[ ! -s "$RESTORE_FILE" ]]; then
  echo "  FAIL no dump at ${RESTORE_FILE}" >&2
  echo "       pass one explicitly:" >&2
  echo "         ./chronicle restore --trusted-sha256=REVIEWED_SHA256 /backups/daily/chronicle-YYYYMMDD.sql.gz" >&2
  echo "       available:" >&2
  find "$BACKUPS_DIR" -name '*.sql.gz' -type f 2>/dev/null | sed 's|^|         |' >&2 || true
  exit 1
fi

# Freeze the reviewed bytes before validation and execution to close the file-replacement
# window. The backup directory is protected; the input is never executed directly.
REVIEWED_RESTORE_FILE="$(mktemp "${BACKUPS_DIR}/.reviewed-restore.XXXXXX.sql.gz")"
cp -- "$RESTORE_FILE" "$REVIEWED_RESTORE_FILE"
RESTORE_FILE="$REVIEWED_RESTORE_FILE"
trap 'rm -f -- "$REVIEWED_RESTORE_FILE"' EXIT
verify_restore_dump "$RESTORE_FILE" "${CHRONICLE_RESTORE_TRUSTED_SHA256:-}" || exit "$?"

echo "  ok   ${RESTORE_FILE} passes its gzip integrity check"

# ---------------------------------------------------------------------------------------
# 2. Snapshot what is about to be replaced. This is not optional: a restore is the one
#    operation whose whole purpose is to discard the current contents, and an operator who
#    restores the wrong dump has no other way back.
# ---------------------------------------------------------------------------------------
command -v mktemp >/dev/null 2>&1 || {
  echo "  FAIL mktemp is unavailable; refusing to create an overwrite-prone safety dump" >&2
  exit 1
}
SAFETY_DUMP="$(mktemp "${BACKUPS_DIR}/pre-restore-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX.sql.gz")" || {
  echo "  FAIL unable to reserve a unique pre-restore safety dump" >&2
  exit 1
}
if PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \
     -h "${POSTGRES_HOST:-postgres}" -p "${POSTGRES_PORT:-5432}" \
     -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner \
     --exclude-schema=chronicle_restore_continuity 2>/dev/null \
     | gzip > "$SAFETY_DUMP" && [[ -s "$SAFETY_DUMP" ]] &&
     verify_restore_dump "$SAFETY_DUMP" 2>/dev/null && /bin/chmod 0600 "$SAFETY_DUMP"; then
  echo "  ok   current database saved to ${SAFETY_DUMP}"
else
  /bin/rm -f "$SAFETY_DUMP"
  echo "  FAIL unable to create pre-restore safety dump; refusing to drop the existing schema" >&2
  echo "       verify database connectivity, credentials, free space, and backup-directory permissions" >&2
  exit 1
fi

# ---------------------------------------------------------------------------------------
# 3. Preserve post-backup security authorities outside public.
#
#    A restore can move the public schema backward in time. Without this checkpoint, a
#    backup taken before withdrawal could reactivate the participant, their mobile key,
#    and the data that a later deletion proof had already erased. The backend consumes this
#    owner-only schema during its blocking initialization task and drops it only after a
#    fresh reconciliation receipt and any replacement deletion proof commit atomically. It
#    also preserves collection-settings revisions and enrollment-invitation state so an older
#    backup cannot roll back containment or resurrect a consumed/revoked/deleted invitation.
# ---------------------------------------------------------------------------------------
continuity_schema_exists=$(psql_q -c \
  "SELECT CASE WHEN to_regnamespace('chronicle_restore_continuity') IS NULL THEN 0 ELSE 1 END")
if [[ "$continuity_schema_exists" == "0" ]]; then
  echo "  --   capturing withdrawal and erasure continuity checkpoint"
  psql_q -1 <<SQL >/dev/null
CREATE SCHEMA chronicle_restore_continuity;
REVOKE ALL ON SCHEMA chronicle_restore_continuity
    FROM PUBLIC, chronicle_app, chronicle_admin;

CREATE TABLE chronicle_restore_continuity.checkpoint (
    contract_version INTEGER NOT NULL,
    checkpoint_id UUID PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL,
    source_schema_version TEXT NOT NULL,
    checkpoint_sha256 TEXT NOT NULL,
    withdrawal_receipt_count BIGINT NOT NULL,
    revoked_api_key_count BIGINT NOT NULL,
    withdrawn_participant_count BIGINT NOT NULL,
    deletion_operation_count BIGINT NOT NULL,
    source_tombstone_count BIGINT NOT NULL,
    collection_revision_count BIGINT NOT NULL,
    published_collection_settings_count BIGINT NOT NULL,
    enrollment_invitation_count BIGINT NOT NULL,
    erased_device_key_tombstone_count BIGINT NOT NULL,
    restricted_participant_count BIGINT NOT NULL,
    archived_study_count BIGINT NOT NULL
);

CREATE TABLE chronicle_restore_continuity.withdrawal_requests AS
SELECT request_id, api_key_id, study_id, participant_id, device_id,
       already_withdrawn, created_at
FROM public.mobile_withdrawal_requests;

CREATE TABLE chronicle_restore_continuity.revoked_api_keys AS
SELECT key_id, study_id, participant_id, device_id
FROM public.api_keys
WHERE revoked;

CREATE TABLE chronicle_restore_continuity.withdrawn_participants AS
SELECT study_id, participant_id
FROM public.study_participants
WHERE participation_status = 'NOT_ENROLLED'
UNION
SELECT study_id, participant_id
FROM public.mobile_withdrawal_requests;

$RESTRICTIONS_SCHEMA_SQL
INSERT INTO chronicle_restore_continuity.restricted_participants
SELECT study_id, participant_id, participation_status, (to_jsonb(participant)->>'capture_cutoff')::timestamptz
FROM public.study_participants participant WHERE participation_status IN ('PAUSED', 'COLLECTION_COMPLETED');
INSERT INTO chronicle_restore_continuity.archived_studies
SELECT study_id FROM public.studies WHERE lifecycle_status = 'ARCHIVED';

CREATE TABLE chronicle_restore_continuity.deletion_operations AS
SELECT operation_id, study_id, participant_ref, participant_id, participant_block_token,
       mode, status, requested_by, idempotency_key, registry_version, quarantine_until,
       started_at, completed_at, proof_hash, cancelled_by, cancelled_at
FROM public.data_deletion_operations;

CREATE TABLE chronicle_restore_continuity.retention_holds AS
SELECT hold_id, operation_id, study_id, reason, created_by, created_at, review_at,
       released_by, released_at, release_reason
FROM public.retention_holds;

CREATE TABLE chronicle_restore_continuity.deletion_tombstones AS
SELECT operation_id, study_ref, participant_ref, mode, registry_version,
       completed_at, proof_hash
FROM public.data_deletion_tombstones;

CREATE TABLE chronicle_restore_continuity.data_collection_settings_revisions AS
SELECT study_id, settings_version, setting, issued_at
FROM public.data_collection_settings_revisions;

CREATE TABLE chronicle_restore_continuity.published_data_collection_settings AS
SELECT study_id,
       (settings -> 'DataCollection' ->> 'settingsVersion')::INTEGER AS settings_version,
       settings -> 'DataCollection' AS setting
FROM public.studies
WHERE jsonb_typeof(settings -> 'DataCollection') = 'object'
  AND settings -> 'DataCollection' ->> 'settingsVersion' ~ '^[1-9][0-9]*\$';

CREATE TABLE chronicle_restore_continuity.enrollment_invitations AS
SELECT access_code_id, token_hash, study_id, participant_id, form_kind, resource_id,
       logical_date, issuer_type, issued_by, expires_at, exchanged_at, revoked_at, created_at,
       enrollment_attempt_id, enrollment_source_device_hash, enrollment_device_id,
       enrollment_manifest_digest, enrollment_request_hash, enrollment_proposed_key_hash,
       enrollment_replay_expires_at, enrollment_settings_version,
       enrollment_disclosure_version, enrollment_enabled_modules, enrollment_required_modules
FROM public.participant_form_access_codes
WHERE form_kind = 'ENROLLMENT';

-- Erasure deleted these device keys; their hashes keep answering an offline phone with its terminal
-- status. A key enrolled after the backup exists nowhere else, so its tombstone is carried as is.
CREATE TABLE chronicle_restore_continuity.erased_device_key_tombstones (
    key_hash TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);
DO \$\$
BEGIN
    IF to_regclass('public.erased_device_key_tombstones') IS NOT NULL THEN
        INSERT INTO chronicle_restore_continuity.erased_device_key_tombstones (key_hash, kind, expires_at)
        SELECT key_hash, kind, expires_at
        FROM public.erased_device_key_tombstones
        WHERE expires_at > now();
    END IF;
END \$\$;

$AUTHORITIES_SCHEMA_SQL
INSERT INTO chronicle_restore_continuity.participant_purge_cutoffs
SELECT * FROM public.participant_purge_cutoffs;
INSERT INTO chronicle_restore_continuity.participant_collection_acknowledgment
SELECT * FROM public.participant_collection_acknowledgment;

$CHECKPOINT_DIGEST_SQL
INSERT INTO chronicle_restore_continuity.checkpoint (
    contract_version, checkpoint_id, created_at, source_schema_version,
    checkpoint_sha256, withdrawal_receipt_count, revoked_api_key_count,
    withdrawn_participant_count, deletion_operation_count, source_tombstone_count,
    collection_revision_count, published_collection_settings_count,
    enrollment_invitation_count, erased_device_key_tombstone_count,
    restricted_participant_count, archived_study_count, purge_cutoff_count, collection_acknowledgment_count
)
SELECT $RESTORE_CONTINUITY_CONTRACT_VERSION,
       gen_random_uuid(),
       now(),
       COALESCE(
           (SELECT version FROM public.flyway_schema_history
            WHERE success ORDER BY installed_rank DESC LIMIT 1),
           'unversioned'
       ),
       digest.value,
       (SELECT count(*) FROM chronicle_restore_continuity.withdrawal_requests),
       (SELECT count(*) FROM chronicle_restore_continuity.revoked_api_keys),
       (SELECT count(*) FROM chronicle_restore_continuity.withdrawn_participants),
       (SELECT count(*) FROM chronicle_restore_continuity.deletion_operations),
       (SELECT count(*) FROM chronicle_restore_continuity.deletion_tombstones),
       (SELECT count(*) FROM chronicle_restore_continuity.data_collection_settings_revisions),
       (SELECT count(*) FROM chronicle_restore_continuity.published_data_collection_settings),
       (SELECT count(*) FROM chronicle_restore_continuity.enrollment_invitations),
       (SELECT count(*) FROM chronicle_restore_continuity.erased_device_key_tombstones),
       (SELECT count(*) FROM chronicle_restore_continuity.restricted_participants),
       (SELECT count(*) FROM chronicle_restore_continuity.archived_studies),
       (SELECT count(*) FROM chronicle_restore_continuity.participant_purge_cutoffs),
       (SELECT count(*) FROM chronicle_restore_continuity.participant_collection_acknowledgment)
FROM digest;

REVOKE ALL ON ALL TABLES IN SCHEMA chronicle_restore_continuity
    FROM PUBLIC, chronicle_app, chronicle_admin;
SQL
  echo "  ok   withdrawal and erasure continuity checkpoint captured"
else
  checkpoint_rows=$(psql_q -c \
    "SELECT count(*) FROM chronicle_restore_continuity.checkpoint")
  [[ "$checkpoint_rows" == "1" ]] || {
    echo "  FAIL incomplete restore continuity state cannot be resumed safely" >&2
    echo "       Chronicle remains stopped; recover the existing checkpoint before retrying" >&2
    exit 1
  }
  # A legacy checkpoint may omit the block token for an erased NULL-subject completion.
  # Its binding can only be recovered against the original public operation state. Do not
  # replace that state before a qualified reconciler has resolved the legacy checkpoint.
  checkpoint_contract=$(psql_q -c \
    "SELECT contract_version FROM chronicle_restore_continuity.checkpoint")
  [[ "$checkpoint_contract" == "$RESTORE_CONTINUITY_CONTRACT_VERSION" ]] || {
    echo "  FAIL unresolved continuity checkpoint uses unsupported contract ${checkpoint_contract}" >&2
    echo "       Chronicle remains stopped and the database is unchanged; recover it with the release that captured it" >&2
    echo "       Legacy contract 2 must be reconciled against the original public data before retrying restore" >&2
    exit 1
  }
  echo "  --   reusing the unresolved withdrawal and erasure continuity checkpoint"
fi

# Treat a resumed checkpoint as hostile until its privilege boundary has been reasserted.
# This is intentionally unconditional: a failed/manual recovery attempt must not be able to
# leave the evidence readable or writable by either runtime role before a retry continues.
psql_q <<'SQL' >/dev/null
REVOKE ALL ON SCHEMA chronicle_restore_continuity
    FROM PUBLIC, chronicle_app, chronicle_admin;
REVOKE ALL ON ALL TABLES IN SCHEMA chronicle_restore_continuity
    FROM PUBLIC, chronicle_app, chronicle_admin;
SQL

# Bind the transient evidence to the pre-restore safety backup as a separate protected SQL
# artifact. It is excluded from the main dump so restoring that dump cannot collide with the
# live owner-only schema; the companion is the recovery source if the database volume is lost
# before server reconciliation completes.
CONTINUITY_DUMP="${SAFETY_DUMP%.sql.gz}.continuity.sql.gz"
if PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \
     -h "${POSTGRES_HOST:-postgres}" -p "${POSTGRES_PORT:-5432}" \
     -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner \
     --schema=chronicle_restore_continuity 2>/dev/null \
     | gzip > "$CONTINUITY_DUMP" && [[ -s "$CONTINUITY_DUMP" ]] &&
     verify_restore_dump "$CONTINUITY_DUMP" 2>/dev/null && /bin/chmod 0600 "$CONTINUITY_DUMP"; then
  echo "  ok   continuity companion saved to ${CONTINUITY_DUMP}"
else
  /bin/rm -f -- "$CONTINUITY_DUMP"
  echo "  FAIL could not preserve the restore continuity companion" >&2
  echo "       application data is untouched; the owner-only checkpoint remains in PostgreSQL" >&2
  echo "       ${SAFETY_DUMP} holds the pre-restore public data" >&2
  exit 1
fi

# ---------------------------------------------------------------------------------------
# 4. Drop the application schema.
#
#    Objects OWNED BY AN EXTENSION are left alone, which is why this drops objects one by
#    one instead of the obvious `DROP SCHEMA public CASCADE`. pg_tde installs into public,
#    so dropping the schema takes the tde_heap access method with it -- and then the restore
#    below lands every table on plain heap, unencrypted, while reporting success.
# ---------------------------------------------------------------------------------------
echo "  --   dropping the existing schema (pg_tde and other extensions are preserved)"
# DDL, dump replay and rollback proof commit together. An error or producer interruption
# closes this session without COMMIT, preserving the live public schema and its data.
if {
cat <<'SQL'
BEGIN;
-- pg_dump ACLs describe grants relative to standard creation ACLs. Clear the runtime
-- bootstrap additions first; the dump restores its saved defaults after its ACLs.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM chronicle_app, chronicle_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM chronicle_app, chronicle_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM chronicle_app, chronicle_admin;
-- Other sessions still holding the old schema would block the drops. The backend should be
-- stopped already; this covers anything else that reconnected in the meantime.
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE datname = current_database() AND pid <> pg_backend_pid();

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT format('%I.%I', n.nspname, c.relname) AS ident, c.relkind
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind IN ('r','v','m','S')
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')
  LOOP
    CASE r.relkind
      WHEN 'r' THEN EXECUTE 'DROP TABLE IF EXISTS ' || r.ident || ' CASCADE';
      WHEN 'v' THEN EXECUTE 'DROP VIEW IF EXISTS ' || r.ident || ' CASCADE';
      WHEN 'm' THEN EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS ' || r.ident || ' CASCADE';
      WHEN 'S' THEN EXECUTE 'DROP SEQUENCE IF EXISTS ' || r.ident || ' CASCADE';
    END CASE;
  END LOOP;

  -- Functions and types are dropped for the same reason as tables. Skipping them is not
  -- harmless: a leftover function collides with the dump's CREATE FUNCTION, and under
  -- ON_ERROR_STOP that aborts the restore with the schema already gone.
  FOR r IN
    SELECT format(
             '%I.%I(%s)',
             n.nspname,
             p.proname,
             pg_get_function_identity_arguments(p.oid)
           ) AS ident,
           p.prokind
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
  LOOP
    IF r.prokind = 'p' THEN EXECUTE 'DROP PROCEDURE IF EXISTS ' || r.ident || ' CASCADE';
    ELSE EXECUTE 'DROP FUNCTION IF EXISTS ' || r.ident || ' CASCADE';
    END IF;
  END LOOP;

  FOR r IN
    SELECT format('%I.%I', n.nspname, t.typname) AS ident
      FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE n.nspname = 'public' AND t.typtype IN ('e','c','d')
       AND NOT EXISTS (SELECT 1 FROM pg_depend d
                        WHERE d.objid = t.oid AND d.deptype IN ('e','i'))
  LOOP
    EXECUTE 'DROP TYPE IF EXISTS ' || r.ident || ' CASCADE';
  END LOOP;
END $$;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_stat_user_tables WHERE schemaname = 'public') THEN
        RAISE EXCEPTION 'application tables survived the drop; refusing to restore onto them';
    END IF;
END $$;
SQL

# ---------------------------------------------------------------------------------------
# 5. Restore. ON_ERROR_STOP is the entire point: without it psql reports success no matter
#    what happened, which is the failure this script exists to prevent.
# ---------------------------------------------------------------------------------------
echo "  --   restoring ${RESTORE_FILE}" >&2
# stdout is the dump echoing its own SET/COPY results back; only stderr carries anything the
# operator needs, and ON_ERROR_STOP plus the exit status carry the verdict.
gzip -dc "$RESTORE_FILE" || exit 1
# pg_dump empties search_path for the rest of the session. The restored schema's trigger
# functions name tables unqualified, as the application's sessions resolve them in public, so
# every write below would fail inside those triggers. Pinned rather than RESET: the default
# "$user" entry would let a schema in the dump named after this role shadow public tables.
echo 'SET LOCAL search_path = pg_catalog, public, pg_temp;'

# ---------------------------------------------------------------------------------------
# 6. Reapply the non-negotiable containment decision before any application starts.
#
#    The current backend later replays immutable receipts and deletion operations, but an
#    older restored schema must never have a window where a withdrawn participant or mobile
#    credential is active. This owner transaction also satisfies V68's mutation guard through
#    the same explicit deletion-worker context used by the canonical erasure worker.
# ---------------------------------------------------------------------------------------
echo "  --   applying post-backup withdrawal containment" >&2
cat <<SQL
DO \$\$
BEGIN
    IF to_regclass('public.api_keys') IS NULL
       OR to_regclass('public.study_participants') IS NULL THEN
        RAISE EXCEPTION 'Restored schema predates the supported withdrawal containment contract';
    END IF;
END \$\$;

SET LOCAL app.is_admin = 'true';
SET LOCAL app.current_user_id = 'chronicle-deletion-worker';

UPDATE public.api_keys AS target
SET revoked = true
FROM chronicle_restore_continuity.revoked_api_keys AS source
WHERE target.key_id = source.key_id;

UPDATE public.api_keys AS target
SET revoked = true
FROM chronicle_restore_continuity.withdrawn_participants AS source
WHERE target.study_id = source.study_id
  AND target.participant_id = source.participant_id
  AND target.participant_id IS NOT NULL;

UPDATE public.study_participants AS target
SET participation_status = 'NOT_ENROLLED', updated_at = now()
FROM chronicle_restore_continuity.withdrawn_participants AS source
WHERE target.study_id = source.study_id
  AND target.participant_id = source.participant_id;

DO \$\$
DECLARE violations BIGINT;
BEGIN
    SELECT
        (SELECT count(*)
         FROM chronicle_restore_continuity.revoked_api_keys source
         JOIN public.api_keys target ON target.key_id = source.key_id
         WHERE NOT target.revoked) +
        (SELECT count(*)
         FROM chronicle_restore_continuity.withdrawn_participants source
         JOIN public.api_keys target
           ON target.study_id = source.study_id
          AND target.participant_id = source.participant_id
         WHERE NOT target.revoked) +
        (SELECT count(*)
         FROM chronicle_restore_continuity.withdrawn_participants source
         JOIN public.study_participants target
           ON target.study_id = source.study_id
          AND target.participant_id = source.participant_id
         WHERE target.participation_status <> 'NOT_ENROLLED')
    INTO violations;
    IF violations <> 0 THEN
        RAISE EXCEPTION 'Post-restore withdrawal containment verification failed';
    END IF;
END \$\$;
$RESTRICTIONS_CONTAINMENT_SQL
SQL

# Consume only a complete current-contract checkpoint whose every fact is already protected
# by the rollback dump. Proof and consumption are one owner transaction. Unsupported,
# missing, corrupt, or newer evidence stays available to the current backend reconciler.
if [[ "${CHRONICLE_RESTORE_LEAVE_STOPPED:-false}" == true ]]; then
  echo "  --   verifying rollback backup already contains protected continuity evidence" >&2
  cat <<SQL
DO \$\$
DECLARE expected record; actual_digest TEXT; pair record;
        captured BIGINT; unresolved_continuity BIGINT; predicate TEXT;
BEGIN
    IF (SELECT count(*) FROM chronicle_restore_continuity.checkpoint) <> 1 THEN
        RAISE EXCEPTION 'Incomplete continuity checkpoint';
    END IF;
    SELECT * INTO STRICT expected FROM chronicle_restore_continuity.checkpoint
    WHERE contract_version = $RESTORE_CONTINUITY_CONTRACT_VERSION;
    IF expected.withdrawal_receipt_count <> (SELECT count(*) FROM chronicle_restore_continuity.withdrawal_requests) OR
        expected.revoked_api_key_count <> (SELECT count(*) FROM chronicle_restore_continuity.revoked_api_keys) OR
        expected.withdrawn_participant_count <> (SELECT count(*) FROM chronicle_restore_continuity.withdrawn_participants) OR
        expected.deletion_operation_count <> (SELECT count(*) FROM chronicle_restore_continuity.deletion_operations) OR
        expected.source_tombstone_count <> (SELECT count(*) FROM chronicle_restore_continuity.deletion_tombstones) OR
        expected.collection_revision_count <> (SELECT count(*) FROM chronicle_restore_continuity.data_collection_settings_revisions) OR
        expected.published_collection_settings_count <> (SELECT count(*) FROM chronicle_restore_continuity.published_data_collection_settings) OR
        expected.enrollment_invitation_count <> (SELECT count(*) FROM chronicle_restore_continuity.enrollment_invitations) OR
        expected.erased_device_key_tombstone_count <> (SELECT count(*) FROM chronicle_restore_continuity.erased_device_key_tombstones) OR
        expected.restricted_participant_count <> (SELECT count(*) FROM chronicle_restore_continuity.restricted_participants) OR
        expected.archived_study_count <> (SELECT count(*) FROM chronicle_restore_continuity.archived_studies) OR
        expected.purge_cutoff_count <> (SELECT count(*) FROM chronicle_restore_continuity.participant_purge_cutoffs) OR
        expected.collection_acknowledgment_count <> (SELECT count(*) FROM chronicle_restore_continuity.participant_collection_acknowledgment) THEN
        RAISE EXCEPTION 'Incomplete continuity checkpoint counts';
    END IF;
    $CHECKPOINT_DIGEST_SQL
SELECT value INTO actual_digest FROM digest;
    IF actual_digest IS DISTINCT FROM expected.checkpoint_sha256 THEN
        RAISE EXCEPTION 'Corrupt continuity checkpoint digest';
    END IF;
    FOR pair IN SELECT * FROM (VALUES
        ('withdrawal_requests', 'mobile_withdrawal_requests'),
        ('revoked_api_keys', 'api_keys'),
        ('withdrawn_participants', 'study_participants'),
        ('deletion_operations', 'data_deletion_operations'),
        ('retention_holds', 'retention_holds'),
        ('deletion_tombstones', 'data_deletion_tombstones'),
        ('data_collection_settings_revisions', 'data_collection_settings_revisions'),
        ('published_data_collection_settings', 'studies'),
        ('enrollment_invitations', 'participant_form_access_codes'),
        ('erased_device_key_tombstones', 'erased_device_key_tombstones'),
        ('restricted_participants', 'study_participants'),
        ('archived_studies', 'studies'),
        ('participant_purge_cutoffs', 'participant_purge_cutoffs'),
        ('participant_collection_acknowledgment', 'participant_collection_acknowledgment')
    ) AS tables(source_name, target_name) LOOP
        EXECUTE format('SELECT count(*) FROM chronicle_restore_continuity.%I', pair.source_name) INTO captured;
        IF captured = 0 THEN CONTINUE; END IF;
        IF to_regclass('public.' || pair.target_name) IS NULL THEN
            RAISE EXCEPTION 'selected rollback backup predates protected table %', pair.target_name;
        END IF;
        predicate := 'to_jsonb(target) @> to_jsonb(source)';
        IF pair.source_name = 'revoked_api_keys' THEN
            predicate := predicate || ' AND target.revoked';
        ELSIF pair.source_name = 'withdrawn_participants' THEN
            predicate := predicate || ' AND target.participation_status = ''NOT_ENROLLED''';
        ELSIF pair.source_name = 'restricted_participants' THEN
            predicate := 'to_jsonb(target) @> (CASE WHEN source.capture_cutoff IS NULL THEN to_jsonb(source) - ''capture_cutoff'' ELSE to_jsonb(source) END)';
        ELSIF pair.source_name = 'archived_studies' THEN
            predicate := predicate || ' AND target.lifecycle_status <> ''ACTIVE''';
        ELSIF pair.source_name = 'published_data_collection_settings' THEN
            predicate := 'target.study_id = source.study_id AND target.settings -> ''DataCollection'' = source.setting';
        END IF;
        EXECUTE format('SELECT count(*) FROM chronicle_restore_continuity.%I source WHERE NOT EXISTS
            (SELECT 1 FROM public.%I target WHERE %s)', pair.source_name, pair.target_name, predicate)
        INTO unresolved_continuity;
        IF unresolved_continuity <> 0 THEN
            RAISE EXCEPTION 'selected rollback backup predates % protected continuity fact(s)', unresolved_continuity;
        END IF;
    END LOOP;
END \$\$;
DROP SCHEMA chronicle_restore_continuity CASCADE;
SQL
fi
cat <<SQL
DO \$\$
BEGIN
    IF NOT ($DATABASE_PRIVILEGES_SQL) THEN
        RAISE EXCEPTION 'restored database violates audit/restore least privilege; use a backup that preserves ACLs';
    END IF;
END \$\$;
COMMIT;
SQL
} | psql_q >/dev/null; then
  echo "  ok   restore, containment and database privileges committed together"
else
  restore_status=("${PIPESTATUS[@]}")
  echo "  FAIL restore transaction did not complete; safety dump: ${SAFETY_DUMP}" >&2
  if [[ "${restore_status[1]}" == 3 || "${restore_status[1]}" == 0 ]]; then
    echo "       the live database was preserved; the current release can resume" >&2
    exit "$EXIT_RESTORE_TRANSACTION_ROLLED_BACK"
  fi
  echo "       connection outcome is uncertain; preserve the lock and inspect PostgreSQL before recovery" >&2
  exit 1
fi

# ---------------------------------------------------------------------------------------
# 7. Report what landed, including whether it is encrypted. A dump taken from an
#    unencrypted instance restores as plain heap; that is expected and db-init's sweep
#    converts it on the next `docker compose up -d`.
# ---------------------------------------------------------------------------------------
psql_q -c "ANALYZE" >/dev/null
tables=$(psql_q -c "SELECT count(*) FROM pg_stat_user_tables WHERE schemaname = 'public'")
rows=$(psql_q -c "SELECT coalesce(sum(n_live_tup),0) FROM pg_stat_user_tables WHERE schemaname = 'public'")
echo "  ok   restored ${tables} table(s), ${rows} row(s)"

psql_q -F' ' -c "
  SELECT '  ok   storage: ' || a.amname || ' x ' || count(*)
    FROM pg_class c
    JOIN pg_am a ON a.oid = c.relam
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind = 'r'
   GROUP BY a.amname"

if [[ "${ENABLE_ENCRYPTION:-true}" == true ]]; then
  plain=$(psql_q -c "
    SELECT count(*) FROM pg_class c
      JOIN pg_am a ON a.oid = c.relam
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.amname <> 'tde_heap'")
  if [[ "$plain" != "0" ]]; then
    echo "  --   ${plain} table(s) are on plain heap; \`docker compose up -d\` encrypts them"
  fi
fi

echo "  ok   database restore complete; the guarded operator command will start Chronicle"
echo "       Startup remains blocked until the server consumes the continuity checkpoint."
