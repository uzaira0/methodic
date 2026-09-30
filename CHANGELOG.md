# Changelog

Release headings use the bundle version: `YYYY.M.D` with no leading zeros (`2026.9.14`),
matching the `chronicle-selfhost-<version>` bundle, its image tags, and `./chronicle update`.
One bundle per calendar day: a same-day suffix such as `-2` is a semver prerelease and
would sort below the day's release, so `./chronicle update` would refuse it.

## [Unreleased]

## [2026.9.30]

Self-host scripts and documentation, and Android build 65. The server and dashboard code are
unchanged from 2026.9.29.

### Self-host
- `rotate-secret dashboard` also restarts the backend, which checks the same password; before, the new
  password opened the dashboard page but sign-in failed. The rotation now confirms a backend sign-in.
- `rotate-secret metrics` with monitoring on also updates the monitoring scraper and confirms it can
  read the backend again.
- `./chronicle verify --dashboard-password` also confirms a backend sign-in, and waits out the
  sign-in rate limit instead of reporting a wrong password.
- A local trial no longer reports "startup failed" after exporting its CA; `./chronicle up` prints the
  QR code after the stack is healthy.
- Monitoring alerts on the public and internal certificates separately, and keeps alerting after a
  certificate has expired.
- `pre-adopt-*` safety dumps are pruned after `PRE_OP_BACKUP_KEEP_DAYS` like the other safety dumps.
- The configuration check runs under the Bash 3.2 that ships with macOS.
- Documentation:
  - Off-host backups: encrypt the whole backup directory before it leaves the host.
  - Certificate renewal: run `cert-init` so the web server can read the new key.
  - Moving from a trial to production: rerun `./chronicle setup`.
  - The incident audit export command authenticates to PostgreSQL.
  - Only the pinned Percona PostgreSQL image is supported.
  - New "Which Android build" table: modules, certificates and upload diagnostics per build.
  - Legal checklists, developer notes and descriptions of unshipped components removed.
- The GitHub release page lists the install and update steps.

### Android (open flavor, versionCode 65, 2026.09.30-internal.open.1)
- After enrollment, the app opens Data Sharing when an accepted module still needs Android access
  (Usage Access for app usage), and Overview says so. Before, a participant who never opened Data
  Sharing had no app usage collected.
- Questionnaire reminders are delivered again, including when the alarm starts the app. Build 64
  dropped all of them.
- Reopening the app after Android stopped it no longer shows the enrollment screen.
- Rotating the phone during enrollment keeps the invitation and the consent answers given so far.
- Lifecycle events refused for low storage are counted as lost.
- A storage pause is not recorded under a different study or participant.
- A start-up recovery path no longer uses an API missing on Android 6.

## [2026.9.29]

Fixes found in a review of release 2026.9.28 and in a codebase-wide sweep for hangs, crashes and
erasure/consent races. Most sweep findings predate 2026.9.28.

### Server
- V108 records erased upload diagnostics by event ID, study ID and an MD5 of study and participant ID; these records
  stay until the study is erased. A device that replays an erased diagnostic, for example with a clock that runs ahead, no longer stores it again. Study erasure removes these records too. Diagnostics erased before V108 have no such record.
- Data-quality alert generation holds the study deletion lock until its inserts commit; a purge can no longer leave alerts behind.
- Participant diagnostics downloads through the published client request JSON; the OpenAPI query names match the server.
- V109: a collected-data purge records a per-participant cutoff. Uploads and buffer drains drop rows observed before
  it and keep the rest, so a device retry cannot restore purged data. Purges completed before V109 get a cutoff from
  their start time. The cutoff uses the device's observation time; a device clock far off can misplace rows near it.
- Participant erasure now covers `devices`, webhook delivery payloads, participant-scoped notifications and revoked
  export requests, including for erasures completed before V109. Unsent compliance messages without a participant
  scope are dropped. Consent acknowledgments and the notification delivery log are kept.
- Connection leaks in imports and nested pool borrows are fixed; drains, purge finalizers and notification writes take
  table locks in one order. ID allocation can no longer block forever when its producer fails.
- Draining the iOS upload buffer quarantines a malformed sample alone and stores the rest. A new iOS upload containing
  a malformed sample is still rejected whole (HTTP 400).
- Researcher notifications without a participant no longer fail the V74 upgrade.
- Jackson 2.22.3 (CVE-2026-68497: CPU denial of service through unbounded numeric parsing).

### Dashboard
- Clearing every study limit is refused with an explanation instead of silently keeping the old limits.
- Studies with legacy iOS sensor settings can be saved again.
- Date-only values show the calendar date in every timezone (zones behind UTC showed the previous day).
- Each study-settings save sends the revision returned by the save before it.
- A diagnostics export ending on a day whose midnight is skipped (DST) no longer includes the following day.

### Android (open flavor, versionCode 64, 2026.09.29-internal.open.1)
- Diagnostics recording, storage checks and usage collection can no longer hang each other while a withdrawal or settings change waits.
- A batch refused for low storage is retried; where the data cannot be collected again, it is counted as lost instead of dropped silently.
- Discarding a sensor also removes its samples waiting in memory, in direct-boot files, in unreadable direct-boot records and in half-written copies. An interrupted discard finishes on the next drain.
- Direct-boot files keep their field names across release builds. Build 63 wrote obfuscated names; such files cannot be read, and are recorded as lost.
- Legacy direct-boot samples without an owner go only to an enrollment that started before them.
- App network usage is never read from before the current enrollment or after a discard.
- A storage pause from one enrollment is never recorded under the next one.
- Sensor, accessibility, notification and broadcast callbacks never wait on the database or the persistence lock, so
  a withdrawal or settings change can no longer freeze the app (ANR).
- Storage, encryption or WorkManager start-up failures no longer crash the app; collection stays closed and retries.
- Data captured before a participant discards a module, a withdrawal or an enrollment change is never stored or
  uploaded afterwards. Discarding a module also clears its read cursors, queued samples, survey alarms and sealed
  upload files. An interrupted discard finishes on the next start. A module the researcher disables still uploads
  what it already queued, unless the study says to discard it.
- A temporary refusal (paused module, low storage) keeps the usage window and accepted sensor samples for retry.
- Checkpoints from build 63 carry over, so the upgrade neither skips nor re-reads usage, network or Health Connect data.

## [2026.9.28]

### Server
- Upload diagnostics and data-quality alerts are kept for the life of the study; the 30-day deletes are gone. Explicit participant or study erasure still removes them. V107 widens the diagnostic vocabularies to the shared Android catalog and adds deletion guards on `upload_diagnostics`.
- Diagnostics that started before a completed participant erasure are acknowledged but not stored again.
- V105 tables `usage_event_annotations` and `participant_pseudonyms` carry deletion guards; a registry test requires guards on every registry table.
- `GET /chronicle/v3/study/{studyId}/participants/android/diagnostics`: paged diagnostics and alert history per participant. Bulk and per-participant downloads offer `UploadDiagnostics` and `DataQualityAlerts`; the alert export adds `evaluation_start`, `evaluation_end` and `threshold`.
- Every export uses an inclusive start and an exclusive end.
- Study settings, details and limits are saved in sequence, each revision-guarded (`If-Match`).
- Public study settings for an unknown study return 404.
- Retention expiry only revokes non-admin access. It never starts an erasure, so a date or clock fault cannot destroy data.

### Dashboard
- Participant rows show the retained Android diagnostics history with filters and a download.
- Participant downloads need both dates and send the local offset; the default range is the last 30 days, 31 at most.
- A participant list that fills the last page is reported as an error instead of being cut off silently.

### Self-host
- `backups/secret-rotation/*.sql.gz` dumps are pruned after `PRE_OP_BACKUP_KEEP_DAYS` like the other pre-operation dumps.

### Android (open flavor, versionCode 63, 2026.09.28-internal.open.1)
- Diagnostics are kept on the phone until the server stores them, never expired or capped. Counts a legacy server rejects are parked and offered again; delivered history is replayed once a day.
- Low storage pauses collection and reports it, instead of evicting queued usage rows.
- Malformed rows are quarantined one by one; the rest of the batch still uploads.
- The usage upload cursor and the upload count commit together.
- Direct-boot records drain under the enrollment that owns them; a failure there no longer throws from the sensor callback.
- Research build: Delete Server now withdraws. Collection stops at once; the server is asked to delete the enrollment's data, and data on the phone is erased only after the server confirms.

## [2026.9.27]

### Server
- Participant deletion also removes usage-event annotations and participant pseudonyms; both were left behind before. V105 hides them while a deletion is in quarantine. A test now fails on any table with a `participant_id` column that deletion neither covers nor deliberately keeps.
- Dashboard login and the OIDC callback write `LOGIN` / `LOGIN_FAILED` audit events.
- V106 accepts three Android diagnostic counts: sensor samples expired by age, sensor samples dropped at the row cap, usage rows evicted on low storage. Counts only.
- `GET /chronicle/v3/study/{studyId}/participants/android/data-drops`: per participant, the data each Android device discarded in the last 30 days.

### Dashboard
- An expanded participant row shows the data the device discarded (last 30 days).
- Preprocessing opens the published preprocessing app when the deployment does not run its own (self-host); before, the button was disabled.
- Interval-configurable modules come from the shared module contract instead of a copy in the dashboard.

### Self-host
- Re-running `./chronicle setup` keeps HTTP, internal and Grafana ports held by this deployment's own containers instead of reporting them taken.
- Setup asks again until a bind address is on this host; the dashboard and Grafana never bind to all interfaces.
- Preflight checks host tools and Docker Compose >= 2.17, and warns on low memory.
- Backup dumps are readable by their owner only (`0600`).
- The bundle ships `THIRD-PARTY.md`.
- `docs/BACKUP-RESTORE.md` names host disk encryption as the control for dumps at rest and lists the connections between containers that are not encrypted (reach Grafana through an SSH tunnel). `docs/DEPLOYMENT-COMPATIBILITY.md` maps each server release to its Android build.

### Security
- Keycloak realm templates no longer allow `http://localhost` redirects or web origins.
- Release images are scanned one by one right after each build, so a fixable HIGH/CRITICAL finding stops the release before the next build.

### Android (open flavor, versionCode 62, 2026.09.27-internal.open.1)
- Settings -> Open-source licenses lists every bundled library with its license text.
- Discarded data is counted and reported to the server: sensor samples expired by age or dropped at the row cap. With less than 200 MiB free, each upload pass evicts the oldest 10% of queued usage rows and counts them; before, the queue grew until the disk was full.
- A request rejected for clock skew (> 25 s) is re-signed with the server's clock and retried once.
- Responses larger than 8 MiB are refused.
- Sensor age cleanup pauses while uploads are failing; the row cap still bounds storage.
- Notification details survive release minification; sleep-activity writes log their outcome; settings refresh branches on the HTTP status, not error text.
- Release dependencies locked in `app/gradle.lockfile`; Gradle wrapper checksum pinned.

## [2026.9.25]

### Self-host
- Every container drops all Linux capabilities (ownership fixes only where mounted paths need them), runs with a read-only root and sized tmpfs; `guard-config.sh` refuses a release image not pinned by digest, also for a bare `docker compose up`.
- Postgres bounds one statement (5 min), an idle open transaction (1 min) and a lock wait (30 s): `POSTGRES_STATEMENT_TIMEOUT`, `POSTGRES_IDLE_IN_TRANSACTION_TIMEOUT`, `POSTGRES_LOCK_TIMEOUT`. Migrations, database init and restore opt out, so an upgrade that rewrites a large table is never cut off.
- Caddy 2.11.4 on Alpine 3.23. Dashboard served with a same-origin Content-Security-Policy; the internal dashboard listener meters every request per client before the password check (`RATE_LIMIT_GUARD_EVENTS`/`RATE_LIMIT_GUARD_WINDOW`); `index.html` is always revalidated so a browser never keeps a page that points at files a newer release removed.
- Pre-upgrade and pre-restore safety dumps are deleted after `PRE_OP_BACKUP_KEEP_DAYS` (30); before, they grew without bound.
- Monitoring overlay: new alert rules (disk, backup age, certificate expiry, probe failures) and optional delivery to `CHRONICLE_ALERT_WEBHOOK_URL`; runbook entry per alert.
- `./chronicle` checks the host clock (signed uploads fail silently on a wrong clock), refuses to start below a free-disk floor, sizes memory ceilings for hosts under 8 GB, and bounds release downloads before extracting them.
- New `docs/INCIDENT-RESPONSE.md`; the Postgres 18 upgrade guide ships in the bundle.

### Server
- Migration V104 accepts the new Android diagnostic codes (sensor dead letters, app crashes and ANRs). Counts only; no payload, message or stack text.
- JWKS and token-exchange calls have connect and read timeouts; a slow identity provider no longer holds request threads.
- Participant and study lists page in a stable order, so no row repeats or goes missing across pages.
- Participant form sessions carry the study's privacy-policy and withdrawal links.
- Rolled log archives are deleted after 30 days.

### Dashboard
- Participant forms: a retry after a lost response is recorded once; editing answers after a failure no longer leaves the form stuck; requests time out instead of spinning; footer links the study's privacy policy and withdrawal page.
- Study save: untouched limits are not re-sent (a title edit no longer moves the study end date or fails for non-admins); every settings step that did not save is named; a concurrent edit reloads the form instead of being overwritten.
- Participant, study and audit lists read every page the server returns (large studies were cut off at 100 rows).
- Bulk export preselects only data types the study collects.
- Failed pages offer "Try again"; network, timeout and offline errors read as sentences; a stale page after an update reloads itself.
- Third-party notices ship with the dashboard; fonts load as separate files (stylesheet 160 kB -> 40 kB budget).

### Android (open flavor, versionCode 61, 2026.09.25-internal.open.1)
- Device-user prompt has its own high-importance notification channel, so it pops up after unlock and muting survey reminders no longer mutes it. Settings detects each reason the prompt cannot show (permission, app notifications off, channel blocked, channel silent) and opens the exact settings page.
- Every screen clears status bar, navigation bar, camera cutout and keyboard on Android 15+.
- A retried encrypted upload resends the same envelope, so the server stores it once.
- Sensor dead letters and app crashes/ANRs are counted in upload diagnostics; the app version is sent with each collection acknowledgment.
- Privacy and consent links open on Android 11+; in-app policies name device model, manufacturer, Android version, audit IP and Google Play services location.

## [2026.9.22]

### Security
- Bouncy Castle 1.84 -> 1.85 across server, api, models, rhizome and rhizome-client: GHSA-9pwp-9qqc-pr26 (X.509 name-constraint bypass via trailing dot) and GHSA-qp49-qgx5-5m26 (lazy ASN.1 sequence resets the nesting-depth guard). Full server suite green on 1.85.
- Dashboard build tooling: js-yaml 4.3.2 (GHSA-2883-xcg3-v3hh), smol-toml 1.8.0 (GHSA-7w5x-hrqm-74c2).
- APK download service: both download locations now keep `nosniff`, CSP, `X-Frame-Options` and `Referrer-Policy` (nginx drops server-level `add_header` in a location that sets its own).

### Dashboard
- Study form exports its configuration to a JSON file and imports one back, so a study setup can be reused on another study or deployment without re-typing. Nothing is written until the form is submitted. Imported files are completed from the module contract so the form shows exactly what it will save; features the form does not offer, legacy sensor settings and per-module dispositions are not carried; editing a study keeps its own participant policy; entries the form cannot apply are named in the status line.

### Self-host
- `./chronicle setup` refuses a non-public hostname (for example `study.pilot.test`) at the hostname question instead of letting `./chronicle up` refuse it after every other question. The prompt points to the trial mode for a same-network test.

## [2026.9.18]

### Self-host
- `./chronicle check`/`up` failed on every deployment after an upgrade: the readability guard flagged the private `upgrade-receipts/` directory. Pruned, and the printed `chmod` remediation leaves it private. `adopt` could never reach a healthy stack for the same reason.
- `verify` and monitoring status probe the local stack with `--noproxy '*'`; on a host with `HTTP_PROXY` set the proxy answered instead of Caddy.
- Re-running `setup` out of the trial mode no longer carries the trial's private `CHRONICLE_PUBLIC_BASE_URL` into a production `.env`.
- `upgrade.sh` and `rotate-secret.sh` compute digests with python3; `sha256sum` no longer required (macOS).
- Web healthcheck and monitoring probe target the `:8081` internal listener over TLS; the `:80` probe answered an empty 200 in own-tls and local-https modes.
- Monitoring overlay runs config-guard as root so `configuration.prom` can be written; the "configuration validation failed" alert no longer fires forever.
- README and CONFIGURATION name the internal listener for the dashboard; the public origin serves participants only.
- Release script refuses a dirty tree or out-of-sync submodules. Local CI runs the migration-safety fixture suite; the security runner registers the update, adopt and failure-propagation suites.

### Server
- Creating an organization seeds the creator as OWNER in `organization_members`; every organization-scoped endpoint was 403 for a new organization once the authorization aspect was registered.
- Settings reads take the revision before the settings map, so the `ETag` can never be newer than the map it accompanies.

### Dashboard
- A 412 on a settings write stops the remaining writes instead of sending them unguarded.
- Clearing every limit field no longer PUTs `{}`, which the server read as the default limits.

### Android
- Open flavor declares `SCHEDULE_EXACT_ALARM`; without it every launch bounced enrolled participants into system Settings.

## [2026.9.17]

### Self-host
- `./chronicle adopt`: copies `backups/` and `tls/` through a root container from the source PostgreSQL image, so the root-owned TLS key and dumps arrive intact; refuses a source with a preserved restore, upgrade or rotation lock.
- `./chronicle up` readability guard walks the whole bundle instead of one directory and prints the `chmod a+rX` remediation.
- `./chronicle update` verifies the bundle sha256 in-process; `sha256sum` no longer required.
- `upgrade.sh` runs release Compose commands as the operator uid/gid, so db-backup and restore containers do not leave root-owned dumps; pre-upgrade dump excludes `chronicle_restore_continuity` like restore does.
- Bundle ships `backups/` 0700 and `tls/` 0755 explicitly; release-bundle test asserts both.
- Migration gate rejects duplicate Flyway version numbers.
- Docs: extract bundles with `tar -xzpf`; `./chronicle up` named wherever the stack is started.

### Server
- Upload diagnostics batches answered 500: the service forced autocommit back on inside the halt recheck, so the guard's commit failed. Previous autocommit restored; regression test on a real PostgreSQL.

### Android
- OEM background-guidance dialog: vendor settings packages declared in `<queries>` for every flavor, so `resolveActivity` finds them on API 30+ instead of landing on the Settings root.

## [2026.9.14]

### Self-host
- `./chronicle update [--check]`: fetch latest release, verify sha256, extract beside current bundle, hand off to guarded upgrade.
- `./chronicle adopt --from <source selfhost>`: one-time cut-over from a source checkout to release bundles (pre-adopt dump, state copied, same Compose project so database volumes are reused).
- `/privacy` and `/withdrawal` redirects removed; store listings use the institutional privacy URL.
- Release bundles built by `scripts/publish-images.sh` (GHCR digest-pinned images + GitHub release). Versions `YYYY.M.D`, one bundle per day.
- Restore container runs as the operator account, as db-backup does; the image's postgres uid could not enter the 0700 backups directory, so no restore could find its dump.
- `./chronicle up` waits for every service to be healthy. Rollback, recovery and manual-backup docs use it; bare `docker compose up` recreates db-backup as root.
- Bundle build and `./chronicle update` extraction set 0755 directories regardless of umask; `./chronicle up` refuses an owner-only directory with the fix.
- `./chronicle verify` no longer expects the retired `/privacy` and `/withdrawal` pages.
- Release smoke drill (`tests/smoke/selfhost-release-smoke.sh`) passes end to end against the 2026.9.14 images: fresh install, upgrade, rollback, forward recovery, TDE rotation, restore.

### Server
- Study settings revision: `ETag` on settings reads and writes, optional `If-Match` precondition, 412 with current state on conflict (V103). Per-type PATCH merges into row-locked map.
- Device uploads run atomically with the collection-halt predicate; a consent decline landing mid-upload now rejects the batch.
- Organization membership self-grant closed (V102 split RLS policies; organization aspect registered).
- Refresh-token rotation claims the row atomically; blocklist rejects tokens minted in the revocation second; nonce TTL must cover request age plus clock skew.
- Audit entries never dropped on flush retries; export create/download audited.
- Authenticated device writes require study write access.
- Exports: header kept on zero rows; module/sensor timestamps rendered in row timezone.
- Usage upload acknowledges the persisted count. `upload_telemetry` cannot be disabled.

### Android
- OEM background guidance after enrollment (Xiaomi/Redmi/POCO, Huawei/Honor, Oppo/Realme/OnePlus, Vivo, Samsung); open/research builds request the battery exemption with the system dialog.
- Open flavor compiles the restricted collectors in (v58 collected nothing for sensor, accessibility, notification, sleep and activity modules).
- Queue write cursor monotonic across clock steps; direct-boot snapshot retired when the sensor gate closes; unknown encryption policy fails closed.
- Consent copy rendered as translatable resources with parity test; withdrawal text = uninstall the app.
- versionCode 59.

### Dashboard
- Settings writes send `If-Match`; conflict message on 412; untouched participant policy not re-sent; unknown modules carried through.
- Public research policy page retired. i18n report fails on empty keys; catalog guards. `dev:local` refuses non-loopback host.

### Models and API
- Retrofit responses that cannot be deserialized fail instead of returning null; bodied DELETE declarations fixed; `AclKey` ordering fixed.
- Notification usage event types 10 and 12 named.

### Tooling
- Migration-safety gate in local CI (immutable published migrations, additive-only SQL, version ordering).
- Translator workbook export/import (`make i18n-sheet-export/import`); i18n lint tool gate.
- Toolchain pins: Gradle 9.7.1, Kotlin 2.4.10, Percona 18.6.1-1, Keycloak 26.7.3, Traefik 3.7.12, fluent-bit 5.1.1, Grafana 13.1.3; verify-toolchain checks active JDK, Python floor, every image pin. deps-freshness and fluent-bit-config CI jobs.
- Infra scripts fail loud (restore drill, backup archive, key rotation); dev host ports bound to loopback; plaintext replication pg_hba entry dropped; TDE key probe works on a fresh cluster.
- rhizome: honor `http2-enabled=false`, optional key-manager password, client-auth order. rhizome-client: retry backoff only before another attempt.

## [2026.9.4]

### Added

- Android Internal Testing build 58 (`2026.09.03-internal.open.1`): the open flavor with translation support, built and uploaded from local CI.
- `make changelog RELEASE=<version>` drafts the changelog entry from the commits staged for publish.

### Changed

- Public history is curated: `make publish-stage` lays the filtered private tree over the public tip and `make publish-push` fast-forwards the logical commits built from it, gated by a secrets scan and a commit-message check. Commit messages follow Conventional Commits; `docs/GIT-WORKFLOW.md` describes the model.

### Fixed

- The self-host Grafana viewer helper crashed on Python 3.9 because of a postponed-annotation syntax in a signature.
- The capability-ownership check looked for English UI text that now lives in the translation table.

### Security

- Web dependencies: fast-uri 4.1.4, browserslist 4.28.8, and qs 6.16.0 close the advisories reported by `bun audit`.

## [2026.9.3]

### Added

- Translation support across the web dashboard, Android app, iOS app, and server-sent messages: English base tables with per-language override hooks, `Accept-Language` on every client call, and a dev-only `en-XA` pseudo-locale. Upstream Spanish, German, Swedish, and Hebrew diary wording is preserved verbatim.
- A hardcoded-string gate for every surface (`make i18n-lint`), with a table-driven proof suite and a mutation test (`make i18n-lint-proof`).
- Publishing from the private development repositories to the public mirrors, gated by a secrets scan and a `.publishignore` per repository.
- `CONTRIBUTING.md`, `SECURITY.md`, and `docs/GIT-WORKFLOW.md`.

### Changed

- All continuous integration now runs locally (`lefthook`, `scripts/local-ci.sh`). The GitHub Actions workflows and the checks that inspected them were retired; the Maestro emulator runner scripts moved to `tests/maestro/`.
- Android `SetTextI18n` is now a build error, and debug builds enable pseudolocales.


### Security

- The shared JVM dependency policy now requires RabbitMQ Java client 5.34.0 and verifies the new RabbitMQ/Netty artifacts used by the server and Rhizome builds.

### Fixed

- Public selfhost deployments now admit the Android app's bounded startup synchronization burst while retaining per-client edge and backend rate limits. [#159](https://github.com/uzaira0/methodic/pull/159)
