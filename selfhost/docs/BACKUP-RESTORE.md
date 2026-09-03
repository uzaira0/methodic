# Backup & Restore

The database files are encrypted at rest, but the backups are **not** — `pg_dump` reads
through the running server, so its output is ordinary compressed SQL with no encryption in
it. Any dump restores into a fresh Postgres, including one with no `pg_tde` installed:
you'll see two cosmetic errors about the missing extension and access method, then every
row restores.

That is deliberate. It means **the encryption key can never lock you out of your data** —
the dumps are a complete copy that needs no key. It also means the dumps are as sensitive
as the database itself: `${CHRONICLE_STATE_DIR:-.}/backups` is `0700` and owned by the deploying account, and you
should treat anywhere you copy it the same way.

A copy of the encryption keyring is kept at `backups/keyring/chronicle-keyring.per` under
that state directory so the backup set can also remount the data volume itself. **Back up
the whole state-directory `backups/` tree as one unit**,
and keep it somewhere other than the disk holding the data volume.

## Automated backups (recommended)

Enable the overlay:

```ini
# .env — retain the existing mode overlay and append backups.yml
COMPOSE_FILE=docker-compose.yml:overlays/mode-behind-proxy-internal.yml:overlays/backups.yml
```

```bash
./chronicle check
docker compose up -d
```

Dumps land in `${CHRONICLE_STATE_DIR:-.}/backups/` on the host, rotated
daily/weekly/monthly (tune `BACKUP_KEEP_*` in `.env`). After an upgrade this can point into
the first release directory, so check the setting before retiring old release files.
**Copy dumps off the box** — a backup on the same disk as the database is not a backup. For
example, sync the resolved directory to object storage:

```bash
# nightly, via your own cron on the host
rclone sync /absolute/chronicle-state/backups remote:chronicle-backups
```

For confidentiality of the copies, encrypt before they leave the host:

```bash
gpg --encrypt --recipient ops@example.cl /absolute/chronicle-state/backups/last/chronicle-latest.sql.gz
```

The sidecar takes one dump immediately after PostgreSQL is accepting connections and the
backend has completed Flyway migrations. It performs those checks inside its own startup
wrapper because Docker restart policies do not re-run Compose `depends_on` conditions
after a host or daemon restart. The default five-minute bound is controlled by
`BACKUP_STARTUP_TIMEOUT_SECONDS`; a timeout leaves the scheduler stopped and the restart
policy tries the readiness sequence again instead of recording a failed initial backup.

> The stack requires `scram-sha-256` for *all* connections, including the local socket inside
> the container. The command below consumes the password already present in the PostgreSQL
> container; it does not export the host `.env` or put a password in Docker argv.

## Trigger one backup now

```bash
docker compose restart db-backup
docker compose up -d --wait --wait-timeout 300 db-backup
```

The restart-safe wrapper waits for PostgreSQL and the migrated backend, then the pinned
backup image's `BACKUP_ON_START` path writes an ordinary `.sql.gz` into the same rotated
backup tree used by `./chronicle restore`. A custom-format `pg_dump` written elsewhere is
not accepted by the guarded restore command; keep one backup format and one tested path.

## Restore

```bash
./chronicle restore
```

That restores the newest dump the backups overlay wrote
(`backups/last/chronicle-latest.sql.gz`). To pick a different one:

```bash
./chronicle restore /backups/daily/chronicle-20260809.sql.gz
```

The command resolves the selected container path below the host's configured `backups/`
directory and checks its gzip integrity before causing downtime. It then acquires
`${CHRONICLE_STATE_DIR}/.chronicle-restore.lock`, refuses to overlap an upgrade or secret
rotation, and stops the backend, dashboard proxy, database-initialization job, and backup
sidecar. It verifies those services are no longer running before invoking the destructive
one-shot restore service. If stopping or verification fails before that invocation, the
database is unchanged; the command restarts exactly the application services that were
running beforehand and releases the restore lock. A failed compensating restart is reported
separately so the operator can repair Compose and run `./chronicle up`.
Direct `docker compose run restore` execution is rejected because it cannot prove that
application writers are stopped.

Before the restore service drops anything, it writes the current database to
`backups/pre-restore-<timestamp>.sql.gz`, so restoring the wrong dump is recoverable. It
stops on the first error rather than continuing, and prints how many tables and rows landed
and whether they are encrypted. It also checkpoints current withdrawal receipts, revoked
mobile-key identifiers, withdrawn participants, deletion operations, retention holds, and
deletion tombstones in an owner-only schema that the selected dump cannot overwrite. Secret
hashes and credential values are never copied into this checkpoint.

The command also writes a mode-`0600` companion next to the safety dump, named
`pre-restore-<timestamp>.<suffix>.continuity.sql.gz`. Keep the safety dump and companion
together in the same protected backup set until reconciliation succeeds. The companion is
the recovery copy of the owner-only checkpoint if the database volume is lost before the
current backend records its reconciliation receipt; it is not an ordinary application dump
and must never be restored into a running or previous-release backend.

After the dump lands, the restore service revokes every checkpointed mobile key and reapplies
`NOT_ENROLLED` before an application process can start. The current backend then blocks its
own startup while it validates the checkpoint digest and row counts, replays immutable
withdrawal receipts, and verifies any exact completed operation/tombstone/hold proof already
present in the restored snapshot. For every completed proof the snapshot does not already
contain exactly, it rebuilds deletion steps from the current canonical asset registry and
physically re-erases the rows. It appends an immutable
`restore_continuity_reconciliations` receipt and drops the transient checkpoint in the same
transaction. A conflict, missing relation, changed digest, active retention-hold mismatch,
or incomplete erasure proof leaves the backend unhealthy and stopped with the checkpoint
preserved for diagnosis. Do not remove `chronicle_restore_continuity` manually.

On success, the command starts the complete stack with a bounded health wait; `db-init`
encrypts anything that arrived on plain heap. Confirm the restore receipt before reopening
external access:

```sql
SELECT checkpoint_id, source_schema_version, checkpoint_sha256,
       withdrawal_receipt_count, already_protected_deletion_count,
       replayed_completed_deletion_count, reconciled_at
FROM restore_continuity_reconciliations
ORDER BY reconciled_at DESC
LIMIT 1;
```

For a tested previous-release rollback, use `--no-start` so the newly restored database is
not paired with the newer backend before that release is shut down:

```bash
./chronicle restore --no-start /backups/pre-upgrade-<version>-to-<version>-<run>.sql.gz
```

`--no-start` is an incident-recovery option, not the normal restore path. The application
services stay stopped until you follow the rollback runbook. Because a previous binary cannot
consume a checkpoint introduced by a newer release, this mode additionally proves that every
protected withdrawal receipt, deletion operation, hold, and tombstone already exists
identically in the selected rollback dump. If even one protected fact is newer than that dump,
the command fails and preserves the restore lock; do not start the previous binary. Start the
current release to reconcile the checkpoint, or recover forward from a newer reviewed backup.

If restore or post-restore startup fails, the application remains stopped and the restore
lock is preserved. Do not start an upgrade, rotation, or backend against a possibly partial
schema. Confirm no `./chronicle restore` process or one-shot `restore` container is still
running and diagnose the reported error. If PostgreSQL contains the
`chronicle_restore_continuity` schema, preserve it: it is the fail-closed authority for
post-backup withdrawals. The lock contains only three named metadata files;
after that check, remove exactly those files and the now-empty directory (never the state
directory itself), then rerun `./chronicle restore` with the intended dump:

```bash
LOCK=/absolute/path/from/CHRONICLE_STATE_DIR/.chronicle-restore.lock
cat "$LOCK/phase" "$LOCK/restore-file"
if kill -0 "$(cat "$LOCK/owner-pid")" 2>/dev/null; then
  echo 'Recorded restore owner still exists; do not remove the lock.' >&2
  exit 1
fi
docker compose ps --all restore
# Continue only when neither command reports an active restore.
rm -f "$LOCK/owner-pid" "$LOCK/phase" "$LOCK/restore-file"
rmdir "$LOCK"
./chronicle restore /backups/the-reviewed-recovery-dump.sql.gz
```

The pre-restore safety dump remains available under `/backups` for recovery.

### Do not pipe a dump into psql yourself

The obvious one-liner is silently destructive whenever the database still has its schema,
which it does any time you are rolling back rather than rebuilding from nothing:

```bash
# WRONG — reports success, corrupts the data
gunzip -c backups/last/chronicle-latest.sql.gz | docker compose exec -T postgres psql ...
```

Every `CREATE` fails with "already exists" and is skipped, and then every `COPY` appends
its rows into the table that is already there. Tables with a primary key reject the
duplicates. Tables without one keep both copies — `audit` is such a table, so the
compliance trail is exactly what doubles. Measured against this bundle: 568 errors,
**psql exit code 0**, `audit` 216 rows → 432. `./chronicle restore` invokes the service that
drops the schema first (leaving `pg_tde` in place) precisely so this cannot happen.

### Restoring into a Postgres without pg_tde

Works, and is the property the encryption design rests on. The dump names `pg_tde` in two
places — `CREATE EXTENSION IF NOT EXISTS pg_tde` and `SET default_table_access_method =
tde_heap` — and on a stock Postgres both fail harmlessly and the tables are created as
plain `heap`. Verified against `postgres:18-alpine` with no `pg_tde` available: 4 errors,
all 86 tables and every row present and identical.

## What to back up besides the database

- `.env` — your secrets (store in a password manager, **not** next to the dumps).
- `caddy_data` volume — the TLS certificates. Not essential (Caddy re-issues them), but
  restoring it avoids re-hitting Let's Encrypt rate limits on a rebuild.

## Test your restore

A backup you have never restored is a guess. Periodically restore the latest dump into a
throwaway Postgres container and confirm the row counts look right.
