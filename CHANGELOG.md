# Changelog

Release headings use the bundle version: `YYYY.M.D` with no leading zeros (`2026.9.14`),
matching the `chronicle-selfhost-<version>` bundle, its image tags, and `./chronicle update`.
One bundle per calendar day: a same-day suffix such as `-2` is a semver prerelease and
would sort below the day's release, so `./chronicle update` would refuse it.

## [Unreleased]

## [2026.10.9]

Server, dashboard and Android build 69 (Play internal, open flavor).

### Upgrading

- Upgrades refuse studies with payload encryption enabled or historical encrypted collection
  payloads, because encrypted participant export is not supported. Keep the previous release
  running and complete an approved decrypt-and-export migration before retrying. Do not delete
  ciphertext to bypass the check.
- Restore requires `--trusted-sha256=...` from an independently reviewed dump. Unresolved
  checkpoints using older restore contracts are refused before database replacement. Preserve
  the original database, checkpoint and restore lock for qualified recovery.
- V114–V134 run before the backend starts when upgrading from 2026.10.3. Earlier installations
  also run their pending migrations. Upgrading from 2026.10.1 or earlier: read the 2026.10.2
  notes below first for log rotation and disk space for V111.
- V127 sets existing studies' withdrawal policy to `ERASE`. Review the policy before choosing
  `KEEP_PRIOR_DATA`: older installed apps promise deletion on withdrawal. Clients supporting
  `ERASED` also clear local enrollment and queued data when researcher erasure enters quarantine.
- `CHRONICLE_INTERNAL_WEB_SECRET` must have at least 32 characters. It also encrypts researcher
  create receipts. Rotating it makes earlier receipt results unreadable; retrying those creates
  returns 409 without creating again.
- Internal dashboards require a bcrypt `DASHBOARD_PASSWORD_HASH`, `TESTING_LOGIN_ENABLED=false`
  and `REQUIRE_MFA=false`. Use the existing dashboard password; run `./chronicle setup` if no
  hash exists. Upgrade, adopt, `up` and scheduled reconciliation migrate the old login settings
  when a valid hash exists. If `TESTING_LOGIN_ENABLED=true` remains, configuration checks refuse
  startup; leaving the variable set to `false` is supported.
- Dashboard sessions expire after 15 idle minutes by default (`CHRONICLE_SESSION_IDLE_MINUTES`,
  integer 1–120). Password-login sessions last at most 480 minutes by default
  (`DASHBOARD_SESSION_MINUTES`, a positive whole number), even with activity. Set both values
  to the institution's session limits.
- Install Python 3.9 or newer. Automatic reconciliation requires `crontab`, `logger`, `systemctl`
  and an enabled, active `cron` or `crond` service. Set `CHRONICLE_RECONCILE_ENABLED=false` only
  when an alternative manages startup and health checks.
- Allow the default 5 GiB free-space reserve and 10,000 free inodes on the state, Docker and
  database filesystems. Updates and upgrades additionally reserve 3 GiB on the state and Docker
  filesystems. Scheduled backup verification needs twice the larger of the live database size
  and uncompressed dump size as additional free space.
- The Compose network uses `CHRONICLE_SUBNET` (default `172.28.0.0/16`). Choose an unused private
  IPv4 subnet if it overlaps a host, VPN or Docker network. Backend trusted-proxy CIDRs follow
  that subnet. Upgrades migrate legacy proxy settings and preserve loopback dashboard access.
  Set `CADDY_TRUSTED_PROXIES` to exact upstream proxy CIDRs before relying on forwarded addresses;
  missing remote ranges warn without blocking the upgrade.
- Dashboard and Grafana binds must be specific private or loopback addresses. Unrestricted
  allowlists are refused. An upstream load balancer must support 10 MiB request bodies, 16 KiB
  headers and 300-second idle timeouts, and replace forwarded protocol headers with HTTPS.
  Enable `PUBLIC_HTTP_ENABLED` only when upstream HTTP redirects to the canonical HTTPS origin.
- `HTTP_BIND` and `INTERNAL_BIND` take IPv4 addresses only. Configuration checks refuse a
  specific IPv6 address: Docker relays an IPv6 listener into the IPv4 stack network through its
  proxy, so every client appears as the Docker gateway and the allowlists never match.
- Keep the environment file at mode `0600` and use literal `KEY=value` assignments. Commands,
  interpolation and backslash escapes are refused. Remove unsupported Compose control settings;
  `COMPOSE_FILE` and `COMPOSE_PROJECT_NAME` remain supported.
- API clients editing participant notes/tags or questionnaires must load the content and its
  `ETag` together, then send that revision in `If-Match` on PATCH. Missing revisions return 428;
  stale revisions return 412. Keep the draft and reload before saving again. Custom mobile HMAC
  clients must sign the normalized path without its trailing slash.
- Verify the release archive's checksum signature against an independently trusted release
  public key before installing it. The new `./chronicle update` refuses missing or invalid
  signatures before extracting or executing a downloaded bundle.

### Server

- The server uses Spring Framework 7.0.9, Spring Security 7.0.7 and Jetty 12.1.14 with ee11.
  Jackson remains on version 2. Netty 4.2.18 fixes Transfer-Encoding request smuggling
  (CVE-2026-89044). Trailing-slash requests are normalized before security, and
  mobile HMAC signatures are verified over that normalized path. Servlet error pages return
  generic JSON with an error ID and no stack trace.
- Researcher participant or study erasure reports `ERASED` to supporting devices during
  quarantine, holds and subsequent erasure. Older clients receive `NOT_ENROLLED`. Uploads and
  new form codes are refused, and device-key expiry stops extending. A collected-data purge
  keeps enrollment; database failures never count as ended participation.
- V114 adds erased device-key tombstones containing only the key hash, erasure kind and expiry,
  without study, participant or device identifiers. Completion deletes the key rows and keeps
  those hashes for 365 days, including expired or revoked keys. They permit only participation
  status and an already-withdrawn acknowledgment; manually revoked keys still return 401.
- V115 removes key rows left by earlier completed erasures and creates their tombstones. If
  another enrollment owns a reused hash, its credential remains and a migration notice reports
  the skipped hash count. Review those shared credentials. New enrollments cannot reuse erased
  or already-owned key material or an erased participant ID.
- Withdrawal follows the study's policy. `ERASE` starts deletion quarantine; `KEEP_PRIOR_DATA`
  stops collection and revokes the withdrawing device's credential while retaining prior server
  data. Withdrawal remains visible with its timestamp after participant erasure, and withdrawn
  participants cannot resume collection.
- Participant disclosures and withdrawal policy cannot change after enrollment. Pending
  enrollment attempts also block disclosure and collection-setting changes. Versioned collection
  settings cannot be removed, and unsupported Play collection policies are rejected before
  researchers issue an invitation.
- Pausing or completing participation records a capture cutoff. While the study remains active,
  queued captures before that cutoff can upload; later or undated captures are discarded.
  V133 backfills legacy cutoffs only from participant-bound audit evidence. Without reliable
  evidence, uploads stay unacknowledged on the device.
- Module uploads honor the consent and settings revision under which records were collected.
  Sensor receipts identify accepted, discarded and held samples separately, so held records stay
  on the phone while accepted records continue uploading.
- Researcher API keys belong to one study. READ_ONLY, WRITE and ADMIN scopes use an explicit route
  allowlist, capped by the creator's current study access and role membership on every request.
  Maximum lifetimes are 365, 90 and 30 days respectively; participant deletion and purge require
  ADMIN. Keys cannot manage keys, permissions, organizations or system administration. Audit
  records identify the key; its replacement or creator can still download its exports.
- Researcher key rotation commits revocation and replacement together. Sending `X-Api-Key` with
  a sign-in bearer token or authentication cookie returns 400. Unsupported DPoP authorization
  returns 401; Chronicle accepts Bearer tokens.
- Logout revokes presented cookie and bearer tokens until expiry. Revocations and session
  activity survive backend restarts. Removing user permissions also revokes their sessions and
  refresh tokens. Built-in login successes and failures are audited.
- Restore continuity contract 5 preserves withdrawal and erasure records, device-key tombstones
  and their original expiry, retention holds, participant pauses/completions, archived studies,
  capture and purge cutoffs, and collection consent records. Restore replays completed deletions,
  handles subjects absent from the backup and removes expired markers before consuming the
  checkpoint. Unproven or conflicting bindings block startup.
- V117 adds encrypted researcher create receipts. Study, questionnaire, async-export and
  researcher-key creates accept an optional `Idempotency-Key`. Keep the same key and exact body
  across retries: the original result is returned, and a changed body returns 409. Clients without
  the header keep their earlier behavior. New tables use the existing TDE default on encrypted
  self-hosts.
- Participant notes/tags and questionnaire reads return content and revision together. Revision
  checks and edits share a database lock, preventing a second tab from overwriting the first
  tab's save. Verified participant questionnaire reads remain available.
- Turning Data Collection off disables optional modules in saved settings, public reads and
  enrollment manifests; required modules remain. Study duration enforcement runs at startup
  and hourly and pauses enrolled participants. Retention expiry raises a deletion alert while
  preserving data and researcher access; deletion remains an explicit action.
- Retention holds require a future review time. Overdue holds produce logs and monitoring alerts
  and remain in effect until explicitly released. Participant deletion and its status audit
  commit together, audit replays no longer duplicate deletion events, and erasure avoids global
  write locks that would block unrelated studies.
- V120 permits verified erasure of collection-setting revisions and withdrawal receipts. V121
  removes deferred iOS device names when a deletion is cancelled. Audit descriptions no longer
  fail when bulk deletion or valid key names exceed the previous length limit.
- Exports reserve space for both Excel working files and the final download, stop at configured
  limits and remove partial files. Long exports avoid the database idle-transaction timeout,
  and failed download setup returns its connection. Spreadsheet-formula text is escaped in CSV;
  numeric values remain numeric.
- Historical diary sleep exports use the diary date for the following morning's wake-up time.
  Diary submission dates use the configured study time zone. Study durations entered as days
  remain exact day counts instead of being converted to approximate years and months.
- Phone verification returns 501 without marking a number verified. Unsupported email delivery
  is recorded as failed and its job is cancelled. Completed and failed webhook delivery records
  are pruned after 30 days.
- Malformed upload strings, timezones and dates are rejected before storage. Database input
  errors return 400, access denials 403, and temporary database failures 503 with `Retry-After: 5`.
  Error responses carry an error ID; logs omit SQL payloads. Readiness checks remain bounded
  when the connection pool stalls. Published API field definitions match server responses.

### Dashboard

- Researchers enter the shared dashboard password in the application login form. Caddy no longer
  asks for it separately. Sign-out and idle expiry require password entry again. The idle lock
  hides dashboard content and dialogs while preserving drafts for the same researcher after
  reauthentication; expired requests also trigger the lock.
- Each study's Audit tab includes researcher API-key scope and expiry choices, last-use details
  and revoke confirmation. The raw key is shown once, excluded from shared response caches and
  cleared on dismissal or study change. Late responses from another study are ignored.
- Study, questionnaire, export and API-key creates retain the same request and idempotency key
  across lost responses and retries. Notes and questionnaire editors send the loaded revision,
  preserve rejected drafts and offer explicit reload after conflicts. Study settings saves also
  use the loaded revision.
- Pause writes `PAUSED`. Turning Data Collection off saves disabled optional modules. Module
  status and sensor cadence reflect the current collection policy. Enrollment QR codes and
  links remain bound to the participant they were issued for during an in-flight request.
- Study forms include withdrawal policy and an IANA study time zone. They preserve exact duration
  values and unchanged legacy calendar durations. Retention expiry displays a deletion reminder.
  Participant lists show withdrawal timestamps and prevent resuming withdrawn or erased enrollment.
- Study forms explain which required or invalid fields block saving and ask before discarding
  unsaved changes. Failed page loads and enrollment-code requests offer Retry; network failures
  use readable messages.
- Participant forms wait for the study's survey or diary settings instead of substituting another
  instrument after failed loads. The portal diary link opens yesterday's diary. Links respect
  participant-session scope, and expired or unavailable sessions retain answers with a retryable
  warning.
- Enrollment previews explain whether withdrawal erases or retains prior server data. Unsupported
  or mismatched previews prevent enrollment.
- Participant downloads start with today's date range and select the only available data type
  automatically. Missing, reversed or excessive date ranges block download with a readable error.
- Compliance violations are paged, and diagnostics filters wait briefly for typing to stop
  before requesting another page. Collection acknowledgment loads report failures and offer Retry.
- Navigation, tables, settings-audit expansion and questionnaire choice ordering work from the
  keyboard. Mobile navigation keeps focus inside the drawer, closes with Escape and returns focus
  to its opener. Collapsed links retain their names, and focused content clears the sticky header.
- Forms have associated labels, pages have headings and distinct browser titles, and asynchronous
  errors are announced to screen readers. Narrow layouts wrap long headings, button focus remains
  visible in forced-colors mode, and the crash page remains readable in the dark theme.

### Android (open flavor, versionCode 69)

- Platform API handling covers Android 8–16. Notifications create their channels before checking
  runtime permission, the app switch, channel importance and blocked channel groups. A reminder
  on a cold start no longer disappears because its channel was missing. Suppressed low-storage
  notices remain eligible after permission is granted.
- Unlock monitoring receives `USER_PRESENT` across supported Android versions instead of silently
  dropping broadcasts from SystemUI. App-only broadcasts retain private receiver handling.
- Foreground-service start and promotion refusals are handled without starting collectors.
  Exact-alarm refusal falls back to an inexact reminder, and granting exact-alarm access triggers
  scheduling reconciliation. Exact access remains optional under reminder timing.
- Missing Usage Access, Health Connect grants, provider availability or supported features skip
  the affected read and preserve its checkpoint instead of retrying the whole collection worker.
  Access revoked during a read also preserves the checkpoint.
- Health Connect reads granted record types when another selected type is unavailable. Background
  permission is required only while the app is not open. Reads retain a consent-bounded 24-hour
  overlap for late records and remember delivered record IDs across restarts. Partial grants keep
  the checkpoint; concurrent reads cannot reset another scope, and discarding data clears seen IDs.
- Overview, Uploads and Data Sharing explain ended or paused participation. `NOT_ENROLLED` stops
  collection and removes reminders while retaining local rows; a 401 alone never ends enrollment.
  `ERASED` stops collection and clears local enrollment, queued data and recovery copies. Pending
  or support-needed withdrawal takes priority in status text.
- Queue writes advance beyond both queued and acknowledged data, so delayed writers cannot be
  skipped. Cleanup retains the user-attribution record needed by the next poll. Queues retain
  their collection-policy evidence, and held modules keep their rows while active modules upload.
  Sensor uploads remove only samples the server accepts or explicitly discards.
- Network calls have a 30-second overall timeout, and workers cancel in-flight calls when stopped.
  Slow responses cannot indefinitely block consent changes or withdrawal.
- Interrupted direct-boot drains keep complete records separate from the live file. Encrypting
  an older plaintext database preserves its schema version before the normal database upgrade.
- Low storage shows a private notice and paused status while retaining queued data. Uploads
  rejected with 400, 413 or 422 retain their data and stop repeating the unchanged request until
  settings, credentials or the app version change; temporary failures retry with a delay.
- Failed collector registration and lost activity, sleep or sensor access are reported with
  recovery options. Lifecycle and sleep samples that cannot be saved are counted without logging
  their contents.
- Applying a new settings version durably queues the accepted and declined decisions once,
  including offline, and retries until the server receives them.
- Temporary enrollment-preview failures preserve the invitation and consent flow. Reminder
  requests retry 502–504 and network failures instead of minting replacement form codes through
  the legacy fallback. Retired reminder taps clear the notice and explain its unavailability
  without issuing a new code. Failed scheduling remains eligible for retry.
- Survey reminders use a generic public lock-screen message; questionnaire logs omit prompts
  and choices. Permission denials lead to Settings instead of repeated prompts.
- Data Sharing preserves control focus through refreshes. Enrollment and recovery changes are
  announced to screen readers; consent text is readable in both themes and errors use
  participant-facing messages.
- Settings opens the packaged platform policy. Disclosure and Settings show the study's HTTPS
  withdrawal link and policy effective date; missing policy content is reported. Enrollment
  explains withdrawal policy and requires participant or guardian eligibility confirmation.

### Self-host

- Fresh setup selects a free private Docker subnet when the default is taken and preserves it on
  reruns. `up` and `upgrade` report overlapping Docker networks before creating resources or stopping
  the running release. Upgrades from 2026.10.3 recreate the network and retain exporter and Caddy
  volume-helper permissions needed after rollback.
- Upgrade preflights check configuration, immutable images, PostgreSQL major compatibility,
  storage, network availability and reconciliation prerequisites before stopping writers.
  Upgrades take a consistent verified rollback dump and write its hash into an upgrade receipt.
  Failures after the new release starts retain recovery state instead of restarting an older
  backend against a potentially migrated database.
- Operator commands enforce active deployment and Compose ownership and serialize upgrades,
  restores and secret rotations. Run subsequent commands from the release directory reported
  after a successful upgrade.
- Backups use `chronicle-selfhost-backup`, rebuilt from upstream backup scripts on the pinned
  Percona image. Schedules, rotation folders and dump format remain unchanged. Each scheduled
  dump must restore successfully into a scratch database before publication, with TDE checked
  when enabled. Verification and startup waits default to 3,600 seconds.
- Restore checks the reviewed hash and restricted dump format before stopping writers, then
  restores a fixed copy of those verified bytes. A `--no-start` rollback consumes its checkpoint
  only after proving the restored backup already protects every captured continuity record.
- Doctor checks verified-backup freshness, scratch capacity and projected retained-backup space,
  and warns about excessive WAL growth. Setup checks service memory ceilings plus host headroom,
  provides reduced limits for a 4 GiB host and defaults monitoring off below 10 GiB.
- The public listener permits researcher keys only for read-only Time Use Diary `/data` and
  `/participants/data`, and questionnaire `/data` downloads. These routes require `X-Api-Key`;
  dashboard bearer tokens and cookies do not pass the public boundary. Other researcher routes
  remain private. Participant pages continue working when dashboard cookies share their hostname.
- All five export limits reach the backend: `CHRONICLE_EXPORT_MAX_ROWS=1000000`,
  `CHRONICLE_EXPORT_MAX_BYTES=536870912`, `CHRONICLE_EXPORT_MAX_RUNTIME_SECONDS=1800`,
  `CHRONICLE_EXPORT_MAX_TOTAL_BYTES=8589934592`, and `CHRONICLE_EXPORT_MIN_FREE_BYTES=1073741824`.
  Values must be positive integers; invalid values stop backend startup.
- Caddy and the metrics server run without root; a helper repairs existing Caddy volume ownership.
  PostgreSQL, backup and CA-export containers have read-only roots with bounded writable paths.
  Caddy reaps healthcheck child processes, and the backend exits on out-of-memory failure to restart.
- Forwarded addresses are resolved from right to left through configured proxies. Direct TLS
  modes ignore forwarded identities from Docker's gateway. SNAT without client forwarding uses
  the load balancer's address; trust configuration cannot recover the original client address.
  Edge limits use IP addresses without retaining credential headers.
- Monitoring caches verified-backup checks, detects container OOM events and stalled log delivery,
  and checks authenticated database readiness. Alerts cover isolated failed exports and erasures,
  retention expiry, overdue holds and backend dashboard-login failures. Application views include
  Caddy errors and warnings, and concurrent operator events are preserved.
- Local HTTPS monitoring trusts the trial CA. For another private public-origin CA, configure
  `MONITORING_PUBLIC_CA_FILE` with its certificate under the mounted state TLS directory. Grafana
  receives only its own certificate and key, and independent monitoring startup validates its
  password and private bind.
- Setup and doctor warn when monitoring has no `CHRONICLE_ALERT_WEBHOOK_URL`. Failed upgrades
  record the operation-failure metric used by alerts. Verification checks canonical upstream HTTP
  redirects when public HTTP is enabled.
- Periodic reconciliation preserves unchanged frontend files and installation certificates.
  `./chronicle down` pauses reconciliation until a successful manual `up`. Published installations
  receive a daily update check that reports available releases without applying them.
- `./chronicle update` verifies signed checksums and prints every intervening changelog entry before
  applying an update. Help works before operational preflight, arguments are checked and forwarded,
  and setup rejects invalid Compose project names. Setup reruns preserve credentials and saved
  operational answers.
- PostgreSQL secret rotation no longer waits for the completed CA-export job to remain running.
  Dashboard password rotation recreates both backend and edge. Source deployments select their
  environment file with `CHRONICLE_ENV_FILE`. Rotation updates mounted credentials, verifies
  dependents and restores old values on failure; interrupted rotations retain recovery instructions.
  Custodian recovery validates shares and preserves backup passphrase bytes.
- Bundles include licenses and source references, and release assets include image-digest-bound
  SBOMs. Optional source and production deployment manifests require immutable image digests,
  which production rollback preserves.
- Hashed fonts use immutable caching. Source-deployment API responses use compression, and APK
  and preprocessing responses retain security headers. Operator documentation describes
  always-recorded device/enrollment metadata, external preprocessing fallback and archive identities
  for support reports.
- Third-party images updated: Percona PostgreSQL 18.6.1-3, Grafana 13.2.3,
  VictoriaMetrics 1.153.0, VictoriaLogs 1.53.0, cAdvisor 0.60.6,
  docker-socket-proxy 0.5.0 and fluent-bit 5.1.3.

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
