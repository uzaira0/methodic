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

Two links are not encrypted, as an **accepted residual risk** for a single-host install:

- **Dumps at rest.** Plain SQL on the host disk, in a `0700` directory; each dump is set to
  `0600` after every backup run. The control for the disk itself is **host full-disk
  encryption** (LUKS or your provider's encrypted volumes): use it whenever the disk may
  leave your control. `./chronicle check`, `doctor` and `verify` warn when backing-device
  encryption cannot be confirmed (Linux LUKS or macOS FileVault). For provider-managed encryption or another
  unavailable probe, obtain a reviewed waiver in the controlled operations register, with
  approver, scope, encryption evidence or compensating controls, expiry and review date.
  Set `BACKUP_STORAGE_ENCRYPTION_WAIVER` to that register reference in the protected
  `.env`; remove it when the waiver expires. An absent probe warns without blocking startup,
  updates or reconciliation.
  The stack does not encrypt dumps itself, because a lost dump key
  would make the backups unrestorable. Encrypt dumps before they leave the host (below).
- **Service traffic.** JDBC requires verified PostgreSQL TLS, and PostgreSQL rejects
  plaintext TCP connections. Grafana and the authenticated backend metrics scrape use
  HTTPS with the bundled service certificate as their trust anchor. Caddy's application
  bridge remains HTTP on the host's private Docker network. Keep Grafana on a private
  management address and trust `tls/monitoring.crt` when opening it through an SSH tunnel.

A copy of the encryption keyring is kept at `backups/keyring/chronicle-keyring.per` under
that state directory so the backup set can also remount the data volume itself. **Back up
the whole state-directory `backups/` tree as one unit**,
and keep it somewhere other than the disk holding the data volume.

A dump becomes `last/<active-db>-latest.sql.gz` only after its scratch restore and
cleanup succeed. The adjacent verified marker binds the active database, timestamp,
and SHA-256; `verify` and `doctor` require it even when TDE is disabled. Verification
requires twice the larger live-database or uncompressed-dump size additionally free
on PostgreSQL storage. Doctor projects the retained gzip footprint separately against
backup storage. Startup/dependency/verification deadlines default to 3600 seconds.
A successful `restore --no-start` writes a durable stop marker, so cron and reboot
reconciliation leave writers stopped until an explicit `up`.

## Automated backups (recommended)

Enable the overlay:

```ini
# .env — retain the existing mode overlay and append backups.yml
COMPOSE_FILE=docker-compose.yml:overlays/mode-behind-proxy-internal.yml:overlays/backups.yml
```

```bash
./chronicle check
./chronicle up
```

Dumps land in `${CHRONICLE_STATE_DIR:-.}/backups/` on the host, rotated
daily/weekly/monthly (tune `BACKUP_KEEP_*` in `.env`). After an upgrade this can point into
the first release directory, so check the setting before retiring old release files.
Copy encrypted backups to a separate host or storage account so a failed database disk
does not destroy the recovery copy.
Encrypt the complete backup directory, including the keyring, into a staging directory and
sync only that directory:

```bash
set -euo pipefail
umask 077
install -d -m 0700 /absolute/chronicle-state/backups-encrypted
archive_tmp=/absolute/chronicle-state/backups-encrypted/chronicle-backups.tar.gz.gpg.partial
trap 'rm -f -- "$archive_tmp"' EXIT
tar -C /absolute/chronicle-state/backups -czf - . |
  gpg --batch --yes --encrypt --recipient ops@example.org >"$archive_tmp"
mv -f "$archive_tmp" /absolute/chronicle-state/backups-encrypted/chronicle-backups.tar.gz.gpg
trap - EXIT
# Run nightly from the host after encryption completes.
rclone sync /absolute/chronicle-state/backups-encrypted remote:chronicle-backups
```

The sidecar takes one dump immediately after PostgreSQL is accepting connections and the
backend has completed Flyway migrations. It performs those checks inside its own startup
wrapper because Docker restart policies do not re-run Compose `depends_on` conditions
after a host or daemon restart. The default 3600-second (60-minute) bound is controlled by
`BACKUP_STARTUP_TIMEOUT_SECONDS`; a timeout leaves the scheduler stopped and the restart
policy tries the readiness sequence again instead of recording a failed initial backup.

> The stack requires `scram-sha-256` for *all* connections, including the local socket inside
> the container. The command below consumes the password already present in the PostgreSQL
> container; it does not export the host `.env` or put a password in Docker argv.

## Trigger one backup now

```bash
docker compose restart db-backup
./chronicle up
```

`./chronicle up` waits for the container to report healthy. A bare `docker compose up`
would recreate db-backup as root (see `overlays/backups.yml`) and leave dumps the operator
cannot prune.

The restart-safe wrapper waits for PostgreSQL and the migrated backend, then the pinned
backup image's `BACKUP_ON_START` path writes an ordinary `.sql.gz` into the same rotated
backup tree used by `./chronicle restore`. A custom-format `pg_dump` written elsewhere is
not accepted by the guarded restore command; keep one backup format and one tested path.

## Restore

Before restoring, independently review the dump's source and record the expected SHA-256
digest through a trusted operator record. A `.sha256` file distributed beside the dump is
not independent provenance. Set `TRUSTED_SHA256` to that reviewed, lowercase 64-character
digest; `./chronicle restore` checks it and gzip integrity before acquiring the restore lock
or stopping writers. For a locally generated backup, review its source and operation record
before accepting that backup's digest for a manual restore.

```bash
TRUSTED_SHA256='<reviewed lowercase 64-character SHA-256>'
```

```bash
./chronicle restore "--trusted-sha256=${TRUSTED_SHA256}"
```

That restores the newest dump the backups overlay wrote
(`backups/last/chronicle-latest.sql.gz`). To pick a different one:

```bash
./chronicle restore "--trusted-sha256=${TRUSTED_SHA256}" /backups/daily/chronicle-20260809.sql.gz
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
together in the same protected backup set until reconciliation succeeds.

These safety dumps, and the `pre-upgrade-*.sql.gz` dumps that `./chronicle upgrade` writes
to the same `backups/` root, are outside the daily/weekly/monthly rotation. The backup
sidecar deletes them after each successful backup once they are older than
`PRE_OP_BACKUP_KEEP_DAYS` (default 30). Raise it in `.env` if an incident needs them
longer, or copy them elsewhere first; restore and upgrade stop the sidecar while they run,
so a dump in use is never pruned. The companion is
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

**Restore time.** The command prints `Restore took N seconds.`, and every operation receipt
under `operator-receipts/operations/` records `durationSeconds`. Rehearse on a copy of your own
data and write down that figure as your recovery-time estimate; it grows with database size.
For reference: 61 s for a fixture database of 91 tables and
65,705 rows, including the bounded restart to a healthy stack.

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

For a tested previous-release rollback, run the guarded handoff from the current release:

```bash
./chronicle rollback --from /absolute/path/to/previous/selfhost "--trusted-sha256=${TRUSTED_SHA256}" \
  /backups/pre-upgrade-<version>-to-<version>-<run>.sql.gz
```

Rollback restores with application services stopped, carries current credentials forward,
and transfers Compose ownership and reconciliation before starting the previous release.
Follow [UPGRADE-ROLLBACK.md](UPGRADE-ROLLBACK.md) for digest review and adoption recovery.
Because a previous binary cannot
consume a checkpoint introduced by a newer release, this mode additionally proves that every
protected withdrawal receipt, revoked key, withdrawn participant, deletion operation, hold,
tombstone, collection-settings revision, published collection setting, enrollment invitation,
and erased-device-key tombstone already exists identically in the selected rollback dump.
Schema replacement and this proof commit together in one PostgreSQL transaction. A proof
refusal rolls back the replacement, preserves all live post-backup writes, releases the
restore lock, and resumes the current release. Choose a newer reviewed backup or continue
from the current release; do not start the previous binary against the current schema.

Operator dumps preserve ACLs. Restore clears broad creation defaults before replaying the
dump's ACLs and saved defaults, then verifies audit/restore role restrictions before
committing. An older dump that omitted privileges is refused with the live data preserved.
`verify` and `doctor` also check these restrictions.

If restore or post-restore startup fails, the application remains stopped and the restore
lock is preserved. Do not start an upgrade, rotation, or backend against a possibly partial
schema. Confirm no `./chronicle restore` process or one-shot `restore` container is still
running and diagnose the reported error. If PostgreSQL contains the
`chronicle_restore_continuity` schema, preserve it: it is the fail-closed authority for
post-backup withdrawals. The lock contains only three named metadata files;
after that check, remove exactly those files and the now-empty directory (never the state
directory itself), independently re-review the intended dump's source and digest, set
`TRUSTED_SHA256` to that exact reviewed digest, then rerun restore:

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
./chronicle restore "--trusted-sha256=${TRUSTED_SHA256}" /backups/the-reviewed-recovery-dump.sql.gz
```

The pre-restore safety dump remains available under `/backups` for recovery. If a previous
release failed after replacing data, follow the lock-release checks above, independently
review that safety dump and its digest, then recover from the current release:

```bash
./chronicle restore "--trusted-sha256=${TRUSTED_SHA256}" /backups/pre-restore-<timestamp>.<run>.sql.gz
./chronicle verify
```

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

The SQL dump restores without the database keyring. It names `pg_tde` in two
places — `CREATE EXTENSION IF NOT EXISTS pg_tde` and `SET default_table_access_method =
tde_heap` — and on a stock Postgres both fail harmlessly and the tables are created as
plain `heap`. Verified against `postgres:18-alpine` with no `pg_tde` available: 4 errors,
all 86 tables and every row present and identical.

## What to back up besides the database

- `.env` — your secrets (store in a password manager, **not** next to the dumps).
- The configured `${CHRONICLE_STATE_DIR:-.}/tls/` directory. Own-TLS mode stores the
  supplied production certificate and key there; internal-dashboard modes also store the
  internal-listener certificate pair. Production TLS uses supplied files; Chronicle does not
  obtain or reissue production certificates. Keep an encrypted copy for rebuilds.

## Verify off-host copies

After each sync, and at least monthly, compare the remote copy and test decryption:

```bash
# 1. The encrypted staging directory matches the remote copy, file by file (size and checksum).
rclone check /absolute/chronicle-state/backups-encrypted remote:chronicle-backups
#    Without rclone: compare checksum manifests from both sides.
( cd /absolute/chronicle-state/backups-encrypted && find . -type f -exec sha256sum {} + | sort -k2 ) >host.sha256

# 2. The off-host archive decrypts and contains a complete gzip tar stream (run where the key lives).
rclone copy remote:chronicle-backups/chronicle-backups.tar.gz.gpg ./check/
gpg --decrypt ./check/chronicle-backups.tar.gz.gpg | tar -tzf - >/dev/null && echo "decrypts and is intact"
```

## Test your restore

Periodically restore the latest dump into a
throwaway Postgres that has no network and no connection to the running stack:

```bash
docker run --rm -d --name chronicle-restore-check --network none \
  -e POSTGRES_USER=chronicle -e POSTGRES_DB=chronicle -e POSTGRES_HOST_AUTH_METHOD=trust \
  postgres:18-alpine
sleep 5
docker exec chronicle-restore-check psql -U chronicle -d chronicle \
  -c 'CREATE ROLE chronicle_app; CREATE ROLE chronicle_admin;'
gunzip -c /absolute/chronicle-state/backups/last/chronicle-latest.sql.gz |
  docker exec -i chronicle-restore-check psql -q -U chronicle -d chronicle >/dev/null
docker exec chronicle-restore-check psql -U chronicle -d chronicle -c \
  "SELECT 'studies' AS t, count(*) FROM studies UNION ALL SELECT 'audit_logs', count(*) FROM audit_logs;"
docker rm -f chronicle-restore-check
```

Expect two errors about the missing `pg_tde` extension and access method (stock Postgres
has neither), then non-zero counts that match what the dashboard shows. The same check
works on a decrypted off-host copy.
