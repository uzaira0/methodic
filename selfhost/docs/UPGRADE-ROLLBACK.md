# Upgrade, Forward Recovery, and Rollback

Use the upgrade command from a newly downloaded release bundle. Do not copy the old `.env`
by hand and do not run the new backend before the automatic backup completes.

## Supported automatic upgrade

### One-command update

From the current bundle's `selfhost` directory, run `./chronicle update --check` to
print the current and latest release versions (exit 0 if up to date, 3 if an update is
available). Run `./chronicle update` to download the latest bundle, its `.sha256`, and
`.sha256.sig`. It verifies the SSH ed25519 signature with the currently installed
`selfhost/release-signing.pub`, then checks the archive checksum before extracting beside
the current bundle and handing off to the guarded upgrade below. Missing or invalid
signatures stop the update before extraction or execution. It requires `curl`, `python3`,
and OpenSSH `ssh-keygen` with `-Y` support, refuses a release that
is not newer, and never overwrites an existing release directory or download.
Only the changelog inside the signature-verified archive is printed as release instructions.
`--check` prints version availability; GitHub release bodies are not authenticated by the
bundle signature and are not displayed.

### Upgrading a proxy deployment to 2026.10.9

The upgrade migrates the old loopback-only `CADDY_TRUSTED_PROXIES` automatically. A same-host
proxy uses the gateway of the saved `CHRONICLE_SUBNET`; a remote F5 uses the existing explicit
`POOL_ALLOWED_IPS`. Client XFF is optional, including when the F5 uses SNAT. A loopback
dashboard allowlist also gains the Compose gateway to retain SSH-tunnel access.
If a remote bind has no recorded F5 source ranges, the upgrade retains its old trust boundary
and the guard warns without blocking startup. SNAT traffic without XFF uses the F5 socket
address. Forwarded client headers remain untrusted until exact F5 source CIDRs are configured;
the upgrade never guesses a range or broadens trust to every address.

### Release signatures and key rotation

Release checksums are signed in the `chronicle-release` SSH namespace. The publisher
requires the private key at `~/.config/chronicle/release-signing-key`, or the path set by
`CHRONICLE_RELEASE_SIGNING_KEY`; it uploads the detached `.sha256.sig` alongside the
archive and checksum. Every new bundle contains the public key. Updates trust the key
from the currently installed bundle, before reading anything inside the downloaded archive.

For manual verification, download all three assets and use your installed public key:

```bash
printf 'chronicle-release %s\n' "$(cat /path/to/current/selfhost/release-signing.pub)" > allowed_signers
ssh-keygen -Y verify -f allowed_signers -I chronicle-release -n chronicle-release \
  -s chronicle-selfhost-<new-version>.tar.gz.sha256.sig \
  < chronicle-selfhost-<new-version>.tar.gz.sha256
sha256sum -c chronicle-selfhost-<new-version>.tar.gz.sha256
```

Proceed to extraction only if both commands succeed. A first installation must obtain
the public key through an independently trusted channel to authenticate the download;
the key inside that same download cannot establish its own trust.

The installed 2026.10.x bundles shipped before signing have no public key. Their existing
checksum-only updater fetches the first signed release without authenticating its signature.
That transition still trusts GitHub's release assets. After switching to the first signed
bundle, subsequent updates require signatures; there is no unsigned fallback in the new CLI.

To rotate keys, publish a bridge release whose checksum is signed by the old private key
and whose bundle ships the new public key. Install that bridge before using releases signed
by the new key. Operators who skipped the bridge must verify and install it with their old
installed key first; replacing the local trust key from an unverified download is unsafe.

### Switching from a source checkout to release bundles

Use `adopt` once when the running installation is a source checkout without a
`release-manifest.json`. Download the archive, `.sha256`, and `.sha256.sig`; verify the
signature with an independently trusted public key as above, then run:

```bash
sha256sum -c chronicle-selfhost-<new-version>.tar.gz.sha256
tar -xzpf chronicle-selfhost-<new-version>.tar.gz
cd chronicle-selfhost-<new-version>/selfhost
./chronicle adopt --from /absolute/path/to/source-checkout/selfhost
```

The new bundle must have no `.env`. The source must have a mode-`0600` `.env`,
`backups/`, `tls/`, and a running healthy PostgreSQL container. Its state directory
must be its own `selfhost` directory. Adoption holds the source's
`.chronicle-upgrade.lock` until it finishes, so restore, upgrade, secret rotation and
setup refuse to run there meanwhile. Like `upgrade`, it refuses before stopping anything
when the new release's PostgreSQL major differs from the running one, or when a study has
encryption enabled or `encrypted_payloads` holds rows. Adoption preserves `COMPOSE_PROJECT_NAME`
(default `chronicle-selfhost`) so the release uses the existing database volumes.
It stops `backend`, `web`, `db-init`, and optional `db-backup`, then creates and
verifies `backups/pre-adopt-<timestamp>-<pid>.sql.gz` in the source directory.
It copies `.env` with mode `0600`; release defaults and pinned images come from the new
bundle's `.env.example`. `CHRONICLE_STATE_DIR` retains the source state directory, including
backups, TLS, the shared `.reconcile.lock`, and recovery markers. No state is duplicated.
Successful adoption transfers the existing reconciliation launcher to the new release. While the source can still restart, it runs the new release's
configuration guard and host checks (ports, bind addresses, free disk) and pulls its
images. After removing the source containers without deleting volumes,
it runs `./chronicle up` and `./chronicle verify` in the new bundle and records the
dump path and SHA-256 in a mode-`0600` `upgrade-receipts/*-adopt.json` receipt.

Failures before the new `up` restart the source stack and remove the copied files.
Once `up` has been invoked, assume migrations may have run: keep the new files and
recover forward, or follow the tested rollback procedure below using the receipt's
`pre_adopt_backup.path` and `pre_adopt_backup.sha256`. Independently review the source
checkout, adoption receipt, and exact dump before accepting its digest as trusted; the
receipt or a sidecar alone does not authenticate bytes if both came from an untrusted source.
From the new bundle, pass the reviewed digest to the guarded rollback command:

```bash
./chronicle rollback --from /absolute/path/to/source/selfhost \
  --trusted-sha256=REVIEWED_SHA256 /backups/pre-adopt-<timestamp>-<pid>.sql.gz
```

This checks the digest before stopping writers, honors the adoption recovery lock, and
transfers Compose ownership and reconciliation back to the source. Never run both
installations at once or delete their shared database volumes.

After successful adoption, future updates run from the bundle:

```bash
./chronicle update --check
./chronicle update
```

### Manual release-bundle upgrade

To download and start a release-bundle upgrade manually:

1. Download the new release archive, its `.sha256`, and `.sha256.sig` files.
2. Verify the signature as above, then the checksum, and extract beside the current release.
3. Keep the previous release directory. Its `backups/` and `tls/` directories may remain the
   persistent state location after the upgrade.
4. Run:

   ```bash
   sha256sum -c chronicle-selfhost-<new-version>.tar.gz.sha256
   tar -xzpf chronicle-selfhost-<new-version>.tar.gz
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
is retained even if a later pre-start check fails. `./chronicle update` reuses its retained
archive and clean extraction only after checking the signature, checksum and complete release inventory.
You can also retry directly:

```bash
cd /path/to/chronicle-selfhost-<new-version>/selfhost
./chronicle upgrade --from /path/to/chronicle-selfhost-<old-version>/selfhost
```

After success, use the new `selfhost/` directory for every operator command; the command
prints that directory. Commands that change the deployment refuse a superseded release.

### At or after `Starting Chronicle ...`

Assume a database migration may have committed. **Do not start the old backend against that
schema.** Prefer forward recovery:

```bash
cd /path/to/chronicle-selfhost-<new-version>/selfhost
docker compose ps --all
docker compose logs --tail=200 backend postgres db-init
./chronicle up
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

   The check proves the file matches the receipt; it does not authenticate the receipt.
   Independently review the originating release and backup operation, then approve this
   exact digest through your trusted operator record before proceeding. A `.sha256` file
   generated beside an untrusted dump is not an independent trust source.

2. From the current release, use the guarded rollback command. It holds the same flock
   as startup and reconciliation, persists the stop marker, verifies the reviewed dump and
   protected continuity facts, restores with every writer stopped, and transfers the schedule
   to a previous release that supports reconciliation before starting it:

   ```bash
   RESTORE_IN_CONTAINER="/backups/$(basename "$BACKUP_HOST")"
   ./chronicle rollback --from /absolute/path/to/chronicle-selfhost-<old-version>/selfhost \
     "--trusted-sha256=${BACKUP_SHA256}" "$RESTORE_IN_CONTAINER"
   ```

   Schema replacement, containment, ACL verification, and continuity proof share one
   PostgreSQL transaction. The proof includes enrollment invitations and published collection
   settings as well as withdrawals and deletion evidence. A proof refusal rolls back the
   replacement, releases the restore lock, and resumes the current release with its live data.
   Connection loss with an uncertain commit outcome preserves the lock for diagnosis.
   Do not clear a migration or restore checkpoint
   merely to start an older binary. Diagnose the preserved checkpoint and repeat the reviewed
   recovery. A standalone `restore --no-start` also stays stopped across scheduled ticks until
   an explicit `up` from the authorized release. Bare Compose commands bypass these safeguards.

Rollback carries the current credentials into the previous release while retaining that
release's image pins. Passwords and signing secrets revoked since the upgrade stay revoked.
If the previous release lacks `chronicle_ops`, rollback removes the reconciliation and
daily update schedules instead. It retains private logs under `operator-receipts/` and
makes only the empty operation lock and stop marker readable for the older preflight.
Automatic reconciliation stays off until a supported release is installed again.
The old backend is now paired with the exact pre-upgrade schema and data. Keep both the
upgrade dump and the restore service's `pre-restore-*.sql.gz` safety dump until the incident
is resolved.

## Removing unused release downloads

From the active release, review `./chronicle cleanup --releases-dir /absolute/releases`.
Repeat with `--apply` to remove eligible bundles and their archives/checksums/signatures. Cleanup keeps
the newest three releases, active/state/recovery owners, all bundles with deployment
configuration or private state, and every bundle referenced by a Compose project. It also
asks Docker to remove unused images; images referenced by containers remain protected.

### Restore continuity contracts

Contract 5 checkpoints bind deletion start times, purge cutoffs, pause/completion capture
cutoffs and immutable module decisions to their row counts and shared digest. Reconciliation
preserves the original timestamps and decision order; restore time grants no new consent.
Older backups remain supported. The backend validates and upgrades pending contracts 2, 3
and 4; the restore command refuses those unresolved checkpoints before replacing public
state, so they must first be consumed by the compatible backend with sufficient evidence.
Older checkpoints lack module history and may lack a purge's original start watermark;
reconciliation uses preserved operation evidence or the original completion time, never
restore time. Missing pause cutoffs remain closed to queued uploads.

### A restore checkpoint left by release 2026.10.3 or earlier

An unresolved contract-2 checkpoint cannot prove the participant binding for every completed
deletion. The guarded restore command refuses it before dropping or replacing public data;
the original public operation records remain available for a qualified recovery. Preserve
that database state, checkpoint, and restore lock. Have a qualified maintainer reconcile the
legacy checkpoint against the original public records before retrying restore. Do not infer
bindings from fingerprints or invent a participant identifier or block token. After the
checkpoint has been safely reconciled, re-review the selected dump and its digest, then retry
with the required `--trusted-sha256=...` value. If the evidence cannot be reconciled, keep the
system stopped and preserve the records for the maintainer; do not clear the checkpoint or
overwrite the source data with another backup.

## PostgreSQL major upgrades

PostgreSQL data directories are not compatible across major versions. The automatic command
therefore refuses a major change before replacing the running container. Follow
[POSTGRES-18-UPGRADE.md](POSTGRES-18-UPGRADE.md) for the separate dump/restore process.

After a successful rollback, the abandoned candidate's settings are preserved as a private
mode-0600 `.env.rollback-<timestamp>` file in the shared state's mode-0700 `operator-receipts`
directory, outside the candidate bundle inventory. Retry that same candidate through the guarded
command, with no manual Compose startup or fresh extraction:

```bash
cd /absolute/path/to/chronicle-selfhost-<candidate>/selfhost
./chronicle upgrade --from /absolute/path/to/chronicle-selfhost-<restored>/selfhost
```

The successful update reclaims superseded release images, preserving the active release and
the previous release's image pins for rollback. Deployment settings and private state remain
protected by release cleanup.
