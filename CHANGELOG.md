# Changelog

Release headings use the bundle version: `YYYY.M.D` with no leading zeros (`2026.9.14`),
matching the `chronicle-selfhost-<version>` bundle, its image tags, and `./chronicle update`.
One bundle per calendar day: a same-day suffix such as `-2` is a semver prerelease and
would sort below the day's release, so `./chronicle update` would refuse it.

## [Unreleased]

## [2026.10.5]

Server, dashboard and Android build 68 (Play internal, open flavor).

### Upgrading

- V114–V117 run before the backend starts. Upgrading from 2026.10.1 or earlier: read the
  2026.10.2 notes below first (log file rotation, disk space for V111).
- `CHRONICLE_INTERNAL_WEB_SECRET` must have at least 32 characters; the self-host configuration
  check refuses a shorter value. It also encrypts researcher create receipts. Rotating it makes
  earlier receipt results unreadable; retrying those creates returns 409 without creating again.
- Dashboard sessions expire after 15 idle minutes by default (`CHRONICLE_SESSION_IDLE_MINUTES`,
  integer 1–120). Password-login sessions now last at most 480 minutes (`DASHBOARD_SESSION_MINUTES`,
  a positive whole number), even with activity. Set these values to the institution's session limits.
- The Compose network now uses `CHRONICLE_SUBNET` (default `172.28.0.0/16`); choose an unused
  private IPv4 subnet if that overlaps a host, VPN or other Docker network. `chronicle upgrade`
  checks this before it stops the running release. Backend trusted-proxy CIDRs follow
  that same setting. Set `CADDY_TRUSTED_PROXIES` to the exact upstream proxy CIDRs; its default
  is `127.0.0.1/32`. Dashboard and Grafana binds must be specific private or loopback addresses,
  and allowlists that cover the whole IPv4 or IPv6 space are refused.
- API clients editing participant notes/tags or questionnaires must load the content and its
  `ETag` together, then send that revision in `If-Match` on PATCH. A missing revision returns
  428; a stale one returns 412. Keep the draft and reload before another save.
- Restore now requires `--trusted-sha256=...` from an independently reviewed dump. Unresolved
  checkpoints from 2026.10.3 or earlier are refused before database replacement. Preserve the
  original database, checkpoint and restore lock for qualified recovery; do not clear the
  checkpoint or infer erased participants from fingerprints.
- Play and Amazon store Release/Dogfood builds require approved policy text for that flavor
  and its matching SHA-256 approval file. Supply institutional text and approval before building.

### Server

- A researcher deleting a participant, or erasing a study, now tells its devices `NOT_ENROLLED`
  during quarantine and after erasure. Uploads and new form codes are refused, and the device
  key's expiry stops extending. A collected-data purge keeps the participant enrolled; a database
  failure is never read as an ended enrollment.
- V114 adds erased device-key tombstones: only the key hash, erasure kind and expiry, with no
  study, participant or device identifiers. Completion deletes the key rows and keeps the hashes
  for 365 days, including expired or revoked keys. They allow only the status read and an
  "already withdrawn" acknowledgment; manually revoked keys still return 401.
- V115 removes key rows left by earlier completed erasures and creates their tombstones.
  If another enrollment still owns an old reused hash, its credential is kept and a migration
  notice reports the skipped hash count. Operators must review those shared credentials.
  New enrollments cannot reuse erased or already-owned key material or an erased participant ID.
- Researcher API keys belong to one study. READ_ONLY, WRITE and ADMIN scopes reach an explicit
  route allowlist, capped by the creator's current study access and role membership on every
  request. Maximum lifetimes are 365, 90 and 30 days respectively; participant deletion and
  purge require ADMIN. Keys cannot manage keys, permissions, organizations or system administration.
  Audit records identify the key; a replacement key or its creator can still download its exports.
- Sending `X-Api-Key` with a sign-in bearer token or authentication cookie returns 400.
  Send one credential type per request.
- Logout revokes the presented cookie and bearer tokens until their expiry, so a saved token
  cannot be replayed after logout. Built-in login successes and failures are audited.
- V116 adds restore continuity contract 3. Checkpoints retain completed erasures' block tokens
  and device-key tombstones, including their original expiry. Restore replays completed deletions,
  handles subjects absent from the backup, preserves later holds and removes expired markers
  before consuming the checkpoint. Old checkpoints without proven original bindings fail closed.
- V117 adds encrypted researcher create receipts and the tombstone update privilege needed by
  restore. Study, questionnaire, async-export and researcher-key creates accept an optional
  `Idempotency-Key`. Keep the same key and exact body across retries: the original result is
  returned, and a changed body returns 409. Clients without the header keep their earlier behavior.
  On encrypted self-hosts, the new tables use the existing TDE default.
- Participant notes/tags and questionnaire reads return the content and revision together.
  Revision checks and edits happen under one database lock, so a second tab cannot overwrite
  the first tab's save. Verified participant questionnaire reads remain available.
- Turning Data Collection off disables optional collection modules in saved settings, public
  reads and enrollment manifests; required always-on modules remain. Study end dates and access
  retention are enforced at startup as well as hourly. Retention expiry never erases data.
- Exports reserve space for both the Excel working files and final download, stop at the configured
  limit and remove partial files. Long exports no longer hit the database idle-transaction timeout,
  and failed download setup returns its connection. CSV text that could become a spreadsheet
  formula is escaped; numeric values stay numeric.
- Historical diary sleep exports use the diary date for the next morning's wake-up time,
  rather than the download date.
- Phone verification returns 501 and never marks a number verified. Unsupported email delivery
  is recorded as failed and its job is cancelled, rather than reported as sent.
- Malformed upload strings, timezones and dates are rejected before storage. Database input
  errors return 400, access denials 403, and temporary database failures 503 with `Retry-After: 5`.
  Error responses carry an error ID; logs omit SQL payloads. Readiness checks time out even when
  the database connection pool stalls. Published API field definitions match the server responses.

### Dashboard

- Each study's Audit tab has a researcher API-key panel with scope and expiry choices, last-use
  details and revoke confirmation. The raw key is shown once, kept out of the shared response
  cache and cleared on dismissal or study change. Late responses from a previous study are ignored.
- Study, questionnaire, export and API-key creates retain the same request and idempotency key
  across a lost response or retry. Notes and questionnaire editors send the loaded revision,
  retain rejected drafts and offer explicit reload after a conflict.
- Pause now writes `PAUSED`. Turning Data Collection off saves disabled optional modules instead
  of leaving them enabled. Enrollment QR codes and links stay bound to the participant they
  were issued for, even if the participant field changes while the request is running.
- Study forms explain which required or invalid fields block saving and ask before discarding
  unsaved changes. Failed page loads and enrollment-code requests offer Retry; network failures
  use readable messages.
- Participant forms wait for the study's survey or diary settings instead of substituting a
  different instrument after a failed load. The portal diary link opens yesterday's diary.
  Links respect the participant session's scope, and expired or unavailable sessions show a
  retryable warning while keeping entered answers.
- Compliance violations are paged, and diagnostics filters wait briefly for typing to stop
  before requesting another page.
- Navigation, tables and questionnaire choice ordering work from the keyboard. Mobile navigation
  keeps focus inside the drawer, closes with Escape and returns focus to its opener; collapsed
  links keep their names and focused content stays clear of the sticky header.
- Forms have associated labels, pages have headings and distinct browser titles, and asynchronous
  errors are announced to screen readers. Narrow layouts wrap long headings, button focus remains
  visible in forced-colors mode, and the crash page remains readable in the dark theme.

### Android (open flavor, versionCode 68, 2026.10.05-internal.open.1)

- Overview, Uploads and Data Sharing say when the study team ends or pauses participation,
  instead of reporting an unhealthy server or active collection. `NOT_ENROLLED` stops collection
  and removes reminders while retaining local rows; a 401 alone never ends enrollment.
  A pending withdrawal or support-needed withdrawal takes priority in the status text.
- Queue writes take their cursor after both queued and acknowledged data, so a delayed writer
  cannot be skipped. Cleanup retains the user-attribution record needed by the next poll.
  Modules on hold keep their queued data while active modules continue uploading.
- Network work has a 30-second overall deadline and is cancelled when its worker stops, so a
  slow response cannot indefinitely block a consent change or withdrawal.
- Health Connect re-reads a consent-bounded 24-hour overlap for late records and remembers
  delivered record IDs across restarts. Missing access to one selected type keeps the checkpoint
  for retry; concurrent reads cannot reset another read's scope. Discarding data clears those IDs.
- Interrupted direct-boot drains keep complete records separate from the live file. Encrypting
  an older plaintext database preserves its schema version before the normal database upgrade.
- Low storage shows a private notice and a paused status while retaining queued data. Uploads
  rejected with 400, 413 or 422 keep their data and stop repeating the unchanged request until
  settings, credentials or the app version change; temporary failures retry with a delay.
- Failed collector registration and lost activity, sleep or sensor access are reported and offer
  recovery. A rejected foreground-service start launches no collectors. Lifecycle and sleep
  samples that cannot be saved are counted without recording their contents.
- Applying a new settings version durably queues the current accepted/declined decisions once,
  including while offline, and retries until the server receives them.
- Temporary enrollment-preview failures keep the invitation and consent flow for retry.
  Retired reminder taps clear the notification and explain that it is unavailable without
  issuing a new form code. Failed reminder scheduling remains eligible for retry.
- Survey reminders use a generic public lock-screen message; questionnaire logs omit prompts
  and choices. Permission denials lead to the app's Settings instead of repeated prompts.
  Exact-alarm access is optional and offered under reminder timing, not on every app launch.
- Data Sharing keeps control focus through refreshes. Enrollment and recovery status changes
  are announced to screen readers; consent text is readable in both themes and errors use
  participant-facing messages.
- Settings opens the packaged platform policy. Disclosure and Settings show the study's
  supplied HTTPS withdrawal link and policy effective date; missing policy content is reported.

### Self-host

- The public listener accepts researcher keys only for read-only Time Use Diary `/data` and
  `/participants/data`, and questionnaire `/data` downloads. These routes require `X-Api-Key`;
  dashboard bearer tokens and cookies do not pass the public boundary. Other researcher routes
  stay on the private listener.
- All five export limits now reach the backend: `CHRONICLE_EXPORT_MAX_ROWS=1000000`,
  `CHRONICLE_EXPORT_MAX_BYTES=536870912`, `CHRONICLE_EXPORT_MAX_RUNTIME_SECONDS=1800`,
  `CHRONICLE_EXPORT_MAX_TOTAL_BYTES=8589934592`, and `CHRONICLE_EXPORT_MIN_FREE_BYTES=1073741824`.
  Values must be positive integers; invalid values stop backend startup.
- Restore verifies the reviewed hash and restricted dump format before stopping writers, then
  restores a fixed copy of those verified bytes. A `--no-start` rollback consumes its contract-3
  checkpoint only after proving the backup already protects every required deletion record.
- Caddy and the metrics server run without root; a one-time helper fixes existing Caddy volume
  ownership before startup. PostgreSQL, backup and CA-export containers have read-only roots
  with bounded writable paths. Caddy reaps healthcheck child processes instead of exhausting
  its process limit, and the backend exits on out-of-memory failure so it can restart.
- Forwarded client addresses are resolved from right to left through the configured proxies.
  Independent monitoring startup also checks Grafana's password and private bind. Public TLS
  modes refuse `.corp`, `.home` and `.mail` names; use local HTTPS for a private LAN trial.
- Setup and doctor warn when monitoring has no `CHRONICLE_ALERT_WEBHOOK_URL`. Failed upgrades
  write the operation-failure metric used by alerts. Behind-proxy installations must redirect
  public HTTP to canonical HTTPS at the upstream proxy; verification checks that redirect.
- `./chronicle update` prints every intervening changelog entry before applying the update.
  Help works before operational preflight, arguments are checked and forwarded, and setup
  rejects invalid Compose project names. Rerunning setup reports that credentials were preserved.
- PostgreSQL secret rotation no longer waits for the completed CA-export job to stay running.
  Source deployments select their environment file with `CHRONICLE_ENV_FILE`. The rotation
  helper updates mounted credentials, recreates dependents and
  restores the old values if verification fails; unsupported rotation types are refused.
  Custodian recovery validates every share, reconstructs threshold keys correctly and restores
  backup passphrase bytes unchanged.
- Release packaging rejects uncommitted inputs and mismatched source revisions, includes licenses
  and source references, and attaches image-digest-bound SBOMs. Release scans include shipped
  third-party images. Optional source/production deployment manifests require immutable image
  digests, and production rollback retains those digests.
- Hashed fonts use immutable caching. Source-deployment API responses use compression, and APK
  and preprocessing responses retain their security headers. Shipped documentation describes
  always-recorded device/enrollment metadata, the external preprocessing fallback and archive
  release identities for support reports.

## [2026.10.3]

Self-host bundle fix for 2026.10.2. Server, dashboard and Android build 67 are unchanged from 2026.10.2;
install 2026.10.3 instead of 2026.10.2. Upgrading from 2026.10.1 or earlier: read the 2026.10.2 notes
below first (log file rotation, disk space for V111).

### Self-host
- The 2026.10.2 configuration check failed on the new `CHRONICLE_RECORD_STAFF_IP` setting, so
  `./chronicle up` and updates to 2026.10.2 refused to start. The check now knows the backend reads
  the setting directly.

## [2026.10.2]

Server and Android build 67. iOS changes are not in this release.

### Server
- Participant IP addresses are no longer stored or logged. This covers the app, enrollment, form links
  and reviewer access. Audit rows and log lines show `ip:[withheld]`.
- Dashboard (staff) IP addresses are recorded only when `CHRONICLE_RECORD_STAFF_IP=true` (default
  `false`), and then only as a keyed fingerprint.
- V110 removes the IP addresses already stored in `audit_logs`, `study_settings_audit` and
  `refresh_tokens`.
- References in logs and deletion records (`participant:`, `study:`, `ip:`) are keyed with
  `CHRONICLE_INTERNAL_WEB_SECRET`, so a copied log cannot be reversed by hashing guesses.
  Rotating that secret changes the references.
- iOS device names ("Alex's iPhone") are no longer stored. V111 replaces stored names with the
  enrolled device ID, or a random ID when no device record matches. Rows of a participant with an
  open or failed deletion are skipped; they are erased when that deletion completes. The device
  system name column held the device name; it now holds the system name.
- V112: the backend database role can no longer read the legacy audit tables or delete from the
  deletion-audit outbox.
- Saving study settings with an unchanged data collection setting no longer conflicts with the stored
  revision history. Sets were read back in a different order after a restart.
- V113 accepts the new `COLLECTION_ACCESS_MISSING` diagnostic. The dashboard lists it under
  "Collection paused".
- Metric `chronicle_api_key_source_ip_hash` removed.

### Self-host operators
- Delete or rotate backend log files and audit log files written before this release. They can hold
  client IP addresses or unkeyed fingerprints of them. New files do not.
- V111 rewrites every iOS sensor row once, in one transaction, before the backend starts. Free disk
  space of at least the size of the `sensor_data` table is needed; a large iOS table extends the
  upgrade downtime. Android-only installations have few or no such rows.

### Android (open flavor, versionCode 67, 2026.10.02-internal.open.1)
- When an accepted module lacks its Android access, the app reports it to the server. When access that
  was granted is lost (for example, Android removes the accessibility service when the app is
  force-stopped), the participant also gets one "Action needed" notification per loss.
- When background data is off, or Data Saver is on without an exemption, a dialog asks the participant
  to allow background data. Before, uploads on mobile data failed silently.
- Overview shows "Device offline" when there is no validated network, instead of "Study server healthy".
- A Health Connect read that did not start (no scope, client or grant) no longer fails the module and
  delays the whole sync.
- A step counter's first value after registration is stamped at registration time, not at the time of
  the last step, which could be before enrollment.

## [2026.10.1]

Server and Android build 66. Found by enrolling a Pixel with build 65 against a trial self-host.

### Server
- Study IDs and other server-generated IDs are random. Before, a new server issued them in sequence
  (`00000000-0000-0000-8000-000000000000`, then `...0002`), so the next one was predictable.
  Existing IDs do not change.

### Android (open flavor, versionCode 66, 2026.10.01-internal.open.1)
- Minimum Android version is 8.0 (was 6.0). From versionCode 55, enrollment from a link crashed the
  app on every device: supporting Android 6 put a separate copy of the date classes in the app, which
  the app's JSON reader could not handle. Builds 55 to 65 are affected; replace them with 66.
- Upload diagnostics are sent again; their dates could not be encoded.
- Battery samples upload again. The release build renamed the classes behind the charging state,
  health and plug type fields, and every battery upload failed.
- Returning from a permission prompt no longer opens a second battery or background dialog.
- The exact-alarm settings page opens once, after enrollment, instead of on every app launch.
  Reminders use inexact alarms when it is not granted.
- versionCode 65 was not uploaded to Play.

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
