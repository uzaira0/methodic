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
# So this script drops the application schema first, and restores with ON_ERROR_STOP so a
# restore that goes wrong stops and says so instead of half-landing.
#
#   ./chronicle restore
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
  echo "         ./chronicle restore [--yes] [/backups/path/to/dump.sql.gz]" >&2
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
    -v ON_ERROR_STOP=1 -tAq "$@"
}

# ---------------------------------------------------------------------------------------
# 1. The dump must exist and be readable BEFORE anything is dropped.
# ---------------------------------------------------------------------------------------
if [[ ! -s "$RESTORE_FILE" ]]; then
  echo "  FAIL no dump at ${RESTORE_FILE}" >&2
  echo "       pass one explicitly:" >&2
  echo "         ./chronicle restore /backups/daily/chronicle-YYYYMMDD.sql.gz" >&2
  echo "       available:" >&2
  find "$BACKUPS_DIR" -name '*.sql.gz' -type f 2>/dev/null | sed 's|^|         |' >&2 || true
  exit 1
fi

# A truncated dump that is only discovered after the schema is gone is the worst possible
# ordering, so verify the compression checksum first. This reads the whole file.
if ! gzip -t "$RESTORE_FILE" 2>/dev/null; then
  echo "  FAIL ${RESTORE_FILE} is not a valid gzip file (truncated or corrupt)" >&2
  exit 1
fi
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
     -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges \
     --exclude-schema=chronicle_restore_continuity 2>/dev/null \
     | gzip > "$SAFETY_DUMP" && [[ -s "$SAFETY_DUMP" ]] &&
     gzip -t "$SAFETY_DUMP" 2>/dev/null && /bin/chmod 0600 "$SAFETY_DUMP"; then
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
  psql_q <<'SQL' >/dev/null
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
    enrollment_invitation_count BIGINT NOT NULL
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

CREATE TABLE chronicle_restore_continuity.deletion_operations AS
SELECT operation_id, study_id, participant_ref, participant_id, mode, status,
       requested_by, idempotency_key, registry_version, quarantine_until,
       completed_at, proof_hash, cancelled_by, cancelled_at
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
  AND settings -> 'DataCollection' ->> 'settingsVersion' ~ '^[1-9][0-9]*$';

CREATE TABLE chronicle_restore_continuity.enrollment_invitations AS
SELECT access_code_id, token_hash, study_id, participant_id, form_kind, resource_id,
       logical_date, issuer_type, issued_by, expires_at, exchanged_at, revoked_at, created_at,
       enrollment_attempt_id, enrollment_source_device_hash, enrollment_device_id,
       enrollment_manifest_digest, enrollment_request_hash, enrollment_proposed_key_hash,
       enrollment_replay_expires_at, enrollment_settings_version,
       enrollment_disclosure_version, enrollment_enabled_modules, enrollment_required_modules
FROM public.participant_form_access_codes
WHERE form_kind = 'ENROLLMENT';

WITH canonical(line) AS (
    SELECT concat_ws('|',
        'withdrawal', request_id::text, api_key_id::text, study_id::text,
        participant_id, device_id::text, already_withdrawn::text,
        to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'))
    FROM chronicle_restore_continuity.withdrawal_requests
    UNION ALL
    SELECT concat_ws('|',
        'revoked-key', key_id::text, study_id::text,
        COALESCE(participant_id, '<null>'), COALESCE(device_id::text, '<null>'))
    FROM chronicle_restore_continuity.revoked_api_keys
    UNION ALL
    SELECT concat_ws('|', 'withdrawn', study_id::text, participant_id)
    FROM chronicle_restore_continuity.withdrawn_participants
    UNION ALL
    SELECT concat_ws('|',
        'operation', operation_id::text, study_id::text,
        COALESCE(participant_ref, '<null>'), COALESCE(participant_id, '<null>'),
        mode, status, requested_by, idempotency_key::text, registry_version::text,
        COALESCE(to_char(quarantine_until AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '<null>'),
        COALESCE(to_char(completed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '<null>'),
        COALESCE(proof_hash, '<null>'), COALESCE(cancelled_by, '<null>'),
        COALESCE(to_char(cancelled_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '<null>'))
    FROM chronicle_restore_continuity.deletion_operations
    UNION ALL
    SELECT concat_ws('|',
        'hold', hold_id::text, operation_id::text, study_id::text, reason,
        created_by, to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        to_char(review_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        COALESCE(released_by, '<null>'),
        COALESCE(to_char(released_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '<null>'),
        COALESCE(release_reason, '<null>'))
    FROM chronicle_restore_continuity.retention_holds
    UNION ALL
    SELECT concat_ws('|',
        'tombstone', operation_id::text, study_ref,
        COALESCE(participant_ref, '<null>'), mode, registry_version::text,
        to_char(completed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        proof_hash)
    FROM chronicle_restore_continuity.deletion_tombstones
    UNION ALL
    SELECT concat_ws('|', 'collection-revision', study_id::text, settings_version::text,
                     setting::text,
                     to_char(issued_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'))
    FROM chronicle_restore_continuity.data_collection_settings_revisions
    UNION ALL
    SELECT concat_ws('|', 'published-collection-settings', study_id::text,
                     settings_version::text, setting::text)
    FROM chronicle_restore_continuity.published_data_collection_settings
    UNION ALL
    SELECT concat_ws('|', 'enrollment-invitation', access_code_id::text,
                     encode(token_hash, 'hex'), study_id::text, participant_id, form_kind,
                     COALESCE(resource_id::text, '<null>'), COALESCE(logical_date::text, '<null>'),
                     issuer_type, issued_by,
                     to_char(expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                     COALESCE(to_char(exchanged_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '<null>'),
                     COALESCE(to_char(revoked_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '<null>'),
                     to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                     COALESCE(enrollment_attempt_id::text, '<null>'),
                     COALESCE(enrollment_source_device_hash, '<null>'),
                     COALESCE(enrollment_device_id::text, '<null>'),
                     COALESCE(enrollment_manifest_digest, '<null>'),
                     COALESCE(enrollment_request_hash, '<null>'),
                     COALESCE(enrollment_proposed_key_hash, '<null>'),
                     COALESCE(to_char(enrollment_replay_expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '<null>'),
                     COALESCE(enrollment_settings_version::text, '<null>'),
                     COALESCE(enrollment_disclosure_version, '<null>'),
                     COALESCE(enrollment_enabled_modules::text, '<null>'),
                     COALESCE(enrollment_required_modules::text, '<null>'))
    FROM chronicle_restore_continuity.enrollment_invitations
), digest AS (
    SELECT encode(
        sha256(convert_to(COALESCE(string_agg(line, E'\n' ORDER BY line), ''), 'UTF8')),
        'hex'
    ) AS value
    FROM canonical
)
INSERT INTO chronicle_restore_continuity.checkpoint (
    contract_version, checkpoint_id, created_at, source_schema_version,
    checkpoint_sha256, withdrawal_receipt_count, revoked_api_key_count,
    withdrawn_participant_count, deletion_operation_count, source_tombstone_count,
    collection_revision_count, published_collection_settings_count,
    enrollment_invitation_count
)
SELECT 2,
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
       (SELECT count(*) FROM chronicle_restore_continuity.enrollment_invitations)
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
     -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges \
     --schema=chronicle_restore_continuity 2>/dev/null \
     | gzip > "$CONTINUITY_DUMP" && [[ -s "$CONTINUITY_DUMP" ]] &&
     gzip -t "$CONTINUITY_DUMP" 2>/dev/null && /bin/chmod 0600 "$CONTINUITY_DUMP"; then
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
psql_q <<'SQL' >/dev/null
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
SQL

remaining=$(psql_q -c "SELECT count(*) FROM pg_stat_user_tables WHERE schemaname = 'public'")
if [[ "$remaining" != "0" ]]; then
  echo "  FAIL ${remaining} table(s) survived the drop; refusing to restore onto them" >&2
  echo "       the database is unchanged apart from those drops; ${SAFETY_DUMP} holds the data" >&2
  exit 1
fi

# ---------------------------------------------------------------------------------------
# 5. Restore. ON_ERROR_STOP is the entire point: without it psql reports success no matter
#    what happened, which is the failure this script exists to prevent.
# ---------------------------------------------------------------------------------------
echo "  --   restoring ${RESTORE_FILE}"
# stdout is the dump echoing its own SET/COPY results back; only stderr carries anything the
# operator needs, and ON_ERROR_STOP plus the exit status carry the verdict.
if ! gzip -dc "$RESTORE_FILE" | PGPASSWORD="$POSTGRES_PASSWORD" psql \
       -h "${POSTGRES_HOST:-postgres}" -p "${POSTGRES_PORT:-5432}" \
       -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q >/dev/null; then
  echo "  FAIL the restore stopped on an error and the database is now incomplete" >&2
  echo "       Chronicle remains stopped; after reviewing the failure, recover with:" >&2
  echo "         ./chronicle restore ${SAFETY_DUMP}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------------------
# 6. Reapply the non-negotiable containment decision before any application starts.
#
#    The current backend later replays immutable receipts and deletion operations, but an
#    older restored schema must never have a window where a withdrawn participant or mobile
#    credential is active. This owner transaction also satisfies V68's mutation guard through
#    the same explicit deletion-worker context used by the canonical erasure worker.
# ---------------------------------------------------------------------------------------
echo "  --   applying post-backup withdrawal containment"
psql_q <<'SQL' >/dev/null
DO $$
BEGIN
    IF to_regclass('public.api_keys') IS NULL
       OR to_regclass('public.study_participants') IS NULL THEN
        RAISE EXCEPTION 'Restored schema predates the supported withdrawal containment contract';
    END IF;
END $$;

BEGIN;
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

DO $$
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
END $$;
COMMIT;
SQL
echo "  ok   restored credentials and participants remain contained"

# A previous Chronicle binary does not know how to consume the transient checkpoint. Permit
# `restore --no-start` only when the selected backup already contains every immutable receipt,
# operation, hold, and tombstone captured before the restore. This makes an ordinary immediate
# upgrade rollback possible while refusing a time-travel rollback that would discard later
# withdrawal or erasure evidence. The checkpoint remains for a current binary to verify again.
if [[ "${CHRONICLE_RESTORE_LEAVE_STOPPED:-false}" == true ]]; then
  echo "  --   verifying rollback backup already contains protected continuity evidence"
  unresolved_continuity=$(psql_q -c "
    SELECT
      (SELECT count(*)
       FROM chronicle_restore_continuity.withdrawal_requests source
       LEFT JOIN public.mobile_withdrawal_requests target
         ON target.request_id = source.request_id
        AND target.api_key_id = source.api_key_id
        AND target.study_id = source.study_id
        AND target.participant_id = source.participant_id
        AND target.device_id = source.device_id
        AND target.already_withdrawn = source.already_withdrawn
        AND target.created_at = source.created_at
       WHERE target.request_id IS NULL) +
      (SELECT count(*)
       FROM chronicle_restore_continuity.deletion_operations source
       LEFT JOIN public.data_deletion_operations target
        ON target.operation_id = source.operation_id
        AND target.study_id = source.study_id
        AND target.participant_ref IS NOT DISTINCT FROM source.participant_ref
        AND target.participant_id IS NOT DISTINCT FROM source.participant_id
        AND target.mode = source.mode
        AND target.status = source.status
        AND target.requested_by = source.requested_by
        AND target.idempotency_key = source.idempotency_key
        AND target.registry_version = source.registry_version
        AND target.quarantine_until IS NOT DISTINCT FROM source.quarantine_until
        AND target.completed_at IS NOT DISTINCT FROM source.completed_at
        AND target.proof_hash IS NOT DISTINCT FROM source.proof_hash
        AND target.cancelled_by IS NOT DISTINCT FROM source.cancelled_by
        AND target.cancelled_at IS NOT DISTINCT FROM source.cancelled_at
       WHERE target.operation_id IS NULL) +
      (SELECT count(*)
       FROM chronicle_restore_continuity.retention_holds source
       LEFT JOIN public.retention_holds target
         ON target.hold_id = source.hold_id
        AND target.operation_id = source.operation_id
        AND target.study_id = source.study_id
        AND target.reason = source.reason
        AND target.created_by = source.created_by
        AND target.created_at = source.created_at
        AND target.review_at = source.review_at
        AND target.released_by IS NOT DISTINCT FROM source.released_by
        AND target.released_at IS NOT DISTINCT FROM source.released_at
        AND target.release_reason IS NOT DISTINCT FROM source.release_reason
       WHERE target.hold_id IS NULL) +
      (SELECT count(*)
       FROM chronicle_restore_continuity.deletion_tombstones source
       LEFT JOIN public.data_deletion_tombstones target
         ON target.operation_id = source.operation_id
        AND target.study_ref = source.study_ref
        AND target.participant_ref IS NOT DISTINCT FROM source.participant_ref
        AND target.mode = source.mode
        AND target.registry_version = source.registry_version
        AND target.completed_at = source.completed_at
        AND target.proof_hash = source.proof_hash
       WHERE target.operation_id IS NULL)
  ")
  if [[ "$unresolved_continuity" != "0" ]]; then
    echo "  FAIL selected rollback backup predates ${unresolved_continuity} protected withdrawal/erasure fact(s)" >&2
    echo "       Chronicle remains stopped; start only the current release so it can reconcile the checkpoint" >&2
    exit 1
  fi
  echo "  ok   rollback backup already contains all protected continuity evidence"
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
