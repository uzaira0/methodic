# PostgreSQL 17 to 18 self-host upgrade

PostgreSQL data directories are not compatible across major versions. Chronicle's normal
`./chronicle upgrade` command detects the running and target PostgreSQL majors and refuses
to attach an older data volume to PostgreSQL 18. A major upgrade must use a logical dump
and restore into a fresh PostgreSQL 18 volume.

This runbook contains no deployment addresses or credentials. Replace every example path
with an operator-reviewed path on the deployment being upgraded.

## Before the maintenance window

1. Read the [backup and restore runbook](../../selfhost/docs/BACKUP-RESTORE.md) and rehearse
   a restore on a disposable host.
2. Confirm the current stack is healthy with `./chronicle doctor --json` and
   `./chronicle verify`.
3. Enable the backups overlay if it is not already enabled, then trigger and verify a fresh
   backup as described in the backup runbook.
4. Copy the entire configured backup directory off the deployment host. Treat every SQL
   dump as sensitive research data even when the live data volume uses `pg_tde`.
5. Record the old release directory, immutable image references, Compose project name, and
   exact PostgreSQL major. Keep the old release and its volumes until the restored service
   has passed verification and a retention decision has been approved.

Do not use `docker compose down -v`, delete a volume, or overwrite the only backup during
this procedure.

## Create the migration dump

Stop every application writer while leaving PostgreSQL running, then take a logical dump
with the PostgreSQL client inside the old database container. The maintained upgrade
command uses this same ordering for ordinary releases: writers stop first, their stopped
state is verified, and only then does `pg_dump` start.

Store the resulting gzip-compressed SQL file below the configured self-host backup
directory so the guarded restore command can resolve it. Verify gzip integrity and copy the
file off-host before continuing. Never put a database password in a command-line argument,
shell history, log, or evidence artifact.

## Start PostgreSQL 18 on fresh volumes

1. Stop the old stack without deleting its volumes.
2. Preserve the old PostgreSQL data and TDE keyring volumes under operator-recorded names
   or storage snapshots. Verify the snapshots before changing the active volume set.
3. Configure the new release to use fresh, empty PostgreSQL data and TDE keyring volumes.
   Do not mount the PostgreSQL 17 data directory into PostgreSQL 18.
4. Start the new release. Allow `db-init` and the backend migrations to complete, then stop
   application writers again before restoring the migration dump.
5. Run the guarded restore command against the reviewed dump path:

   ```bash
   ./chronicle restore /backups/<reviewed-major-upgrade-dump>.sql.gz
   ```

The restore orchestration stops and verifies all supported writers, takes a pre-restore
safety dump, recreates the application schema, restores with fail-fast SQL handling, and
restarts the stack only after the restore succeeds. `db-init` establishes `pg_tde` and its
principal key on the fresh cluster before application traffic resumes.

## Verify and retain rollback state

Run all of the following before declaring the upgrade complete:

```bash
./chronicle doctor --json
./chronicle verify
./verify-config.sh
```

Also confirm that:

- the backend reports PostgreSQL 18;
- the expected studies and aggregate row counts are present;
- every required application table uses the encrypted table access method;
- a new scheduled backup completes and its gzip integrity check passes;
- participant enrollment and authenticated upload work through the public HTTPS origin;
- dashboard access remains limited to the configured private listener.

Keep the PostgreSQL 17 volume snapshots, the migration dump, and the new pre-restore safety
dump until the operator-approved rollback window has closed. Rollback means stopping every
new writer and starting the retained old release against its retained PostgreSQL 17 volumes;
never attach the PostgreSQL 18 data directory to PostgreSQL 17.

## Why the logical restore is required

- PostgreSQL rejects data directories initialized by another major version.
- A PostgreSQL 17 `pg_dump` client cannot dump a PostgreSQL 18 server, so the migration dump
  must be taken before the old runtime is retired.
- A logical dump is plaintext database content even when the source tables use `pg_tde`;
  transport and off-host storage therefore require independent encryption and access
  control.
- Extension versions are reconciled on the fresh cluster. The current initialization path
  runs the supported `pg_tde` update and encryption checks rather than carrying an old
  extension directory forward.

If any prerequisite, snapshot, dump verification, or post-restore check fails, keep the
application stopped and return to the retained old release. Do not improvise an in-place
major-version start.
