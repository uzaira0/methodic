# Upgrade, Forward Recovery, and Rollback

Use the upgrade command from a newly downloaded release bundle. Do not copy the old `.env`
by hand and do not run the new backend before the automatic backup completes.

## Supported automatic upgrade

1. Download the new release archive and its `.sha256` file.
2. Verify the checksum and extract the archive beside—not over—the current release.
3. Keep the previous release directory. Its `backups/` and `tls/` directories may remain the
   persistent state location after the upgrade.
4. Run:

   ```bash
   sha256sum -c chronicle-selfhost-<new-version>.tar.gz.sha256
   tar -xzf chronicle-selfhost-<new-version>.tar.gz
   cd chronicle-selfhost-<new-version>/selfhost
   ./chronicle upgrade --from /absolute/path/to/chronicle-selfhost-<old-version>/selfhost
   ```

The command fails before replacing containers unless all of these are true:

- both release manifests and every inventoried file pass their checksums;
- the new semantic version is newer;
- the old deployment uses one declared mode plus the supported backup/monitoring overlays;
- the old PostgreSQL container is healthy;
- no study has envelope encryption enabled and no historical encrypted participant payloads
  remain that this release cannot export;
- the new configuration passes `docker compose config` and `config-guard`;
- the new PostgreSQL image has the same major version as the running server;
- every old application writer and the backup sidecar stop and are verified stopped; and
- a full `pg_dump` of that quiesced database completes, is non-empty, and passes gzip
  integrity verification.

Only after all live-safe preflight work is complete does the command begin a short maintenance
window. It stops `backend`, `web`, `db-init`, and the optional `db-backup`, then takes the
rollback dump. Stopping writers before the dump is required: otherwise a write committed
after the dump snapshot but before the handoff would be lost by rollback. The command then
runs `docker compose up -d --wait`, applies Flyway migrations through the new backend, and
runs `./chronicle verify`. The dump is written under the persistent `backups/` directory,
and a mode-`0600` JSON receipt containing its path and SHA-256 is written under
`upgrade-receipts/`.

The upgrade command also isolates Compose from inherited shell overrides. The validated
release `.env` and explicit supported Compose files—not an old exported `COMPOSE_FILE`,
`COMPOSE_PROFILES`, image variable, or optional setting—control the handoff.

The new `.env` sets `CHRONICLE_STATE_DIR` to the previous persistent state directory. **Do
not delete that directory while the setting points to it.** Docker named volumes remain
attached through the unchanged `COMPOSE_PROJECT_NAME`; never add `-v` to an upgrade or
recovery `docker compose down` command.

### Study-encryption export precondition

This release intentionally refuses to ingest or silently omit study-encrypted participant
payloads until its participant-export path can decrypt them. Before it renders the new `.env`,
stops an application service, or starts a migration, `./chronicle upgrade` checks the running
database for both:

- a study whose `Encryption` setting is enabled; and
- any row in `encrypted_payloads`, including ciphertext retained after that setting was disabled.

If either exists, keep the previous release running. **Do not delete ciphertext merely to make
the upgrade pass.** An affected operator needs an approved, verified decrypt-and-export or data
migration procedure that preserves the research record and applicable retention obligations.
Remain on the prior release until that procedure is complete and its exported data has been
validated. A failed or indeterminate preflight query also stops the upgrade without changing the
running release.

Upgrade, restore, and secret rotation are mutually exclusive for one state directory. Each
command checks the other operation locks both before and after atomically acquiring its own,
so concurrently started commands cannot both proceed. A crash can leave an empty
`.chronicle-upgrade.lock` directory. Remove that exact directory only after confirming no
upgrade process is running.

## If the command fails

### Before `Starting Chronicle ...`

The running release has not been replaced and its schema has not changed. If the command had
already quiesced application services, it attempts a bounded restart of the previous release
and reports whether that old stack returned healthy. The generated new `.env` is removed so
the command can be retried from the clean bundle. Diagnose the reported validation, pull,
disk, stop, restart, or backup error and rerun the same command. A completed pre-upgrade dump
is retained even if a later pre-start check fails.

### At or after `Starting Chronicle ...`

Assume a database migration may have committed. **Do not start the old backend against that
schema.** Prefer forward recovery:

```bash
cd /path/to/chronicle-selfhost-<new-version>/selfhost
docker compose ps --all
docker compose logs --tail=200 backend postgres db-init
docker compose up -d --wait --wait-timeout 300
./chronicle verify
```

Correct the concrete startup/configuration failure in the new release rather than copying
old image pins into it.

## Tested rollback procedure

Rollback is a database restore, not an image-only restart. Use it only when forward recovery
cannot make the new release healthy.

1. In the **new** release directory, select the failed/succeeded upgrade receipt and verify
   its pre-upgrade dump. Reading the receipt does not expose `.env` secrets:

   ```bash
   RECEIPT=/absolute/state/path/upgrade-receipts/<receipt>.json
   BACKUP_HOST="$(jq -r '.pre_upgrade_backup.path' "$RECEIPT")"
   BACKUP_SHA256="$(jq -r '.pre_upgrade_backup.sha256' "$RECEIPT")"
   printf '%s  %s\n' "$BACKUP_SHA256" "$BACKUP_HOST" | sha256sum -c -
   ```

2. Use the guarded restore command with `--no-start`. It verifies the selected dump, stops
   and verifies every application writer and the backup sidecar, takes another safety dump,
   and stops on the first SQL error. `--no-start` keeps the newer backend from reconnecting
   after the old schema is restored. It also compares the current immutable withdrawal and
   deletion checkpoint with the selected backup. A later withdrawal, active deletion change,
   retention-hold change, or tombstone that is absent from the backup blocks rollback because
   the previous binary cannot safely reconcile it:

   ```bash
   RESTORE_IN_CONTAINER="/backups/$(basename "$BACKUP_HOST")"
   ./chronicle restore --no-start "$RESTORE_IN_CONTAINER"
   ```

   If this command reports that the backup predates protected continuity facts, stop. Do not
   start the old bundle or remove the restore lock/checkpoint. Recover forward with the current
   release and a newer reviewed backup instead.

3. Stop the new release **without deleting volumes**, then start the previous bundle:

   ```bash
   docker compose down
   cd /absolute/path/to/chronicle-selfhost-<old-version>/selfhost
   docker compose up -d --wait --wait-timeout 300
   ./chronicle verify
   ```

The old backend is now paired with the exact pre-upgrade schema and data. Keep both the
upgrade dump and the restore service's `pre-restore-*.sql.gz` safety dump until the incident
is resolved.

The release smoke test exercises this sequence with a database sentinel: previous-version
start, automatic backup, new-version start, data continuity, restore of the pre-upgrade
dump, previous-version restart, and a final forward start.

## PostgreSQL major upgrades

PostgreSQL data directories are not compatible across major versions. The automatic command
therefore refuses a major change before replacing the running container. Follow
[POSTGRES-18-UPGRADE.md](POSTGRES-18-UPGRADE.md) for the separate dump/restore process.
