# Configuration & Operations

- [Managing studies](#managing-studies)
- [Mobile apps](#mobile-apps)
- [Deployment compatibility](#deployment-compatibility)
- [Multi-user login](#multi-user-login-experimental-not-shipped)
- [Secret rotation](#secret-rotation)
- [Data deletion and uninstall](#data-deletion-and-uninstall)
- [Upgrading](#upgrading)

---

## Managing studies

Everything is done from the web dashboard at `https://<your-domain>/chronicle` — there is
no admin CLI.

1. **Create a study.** Give it a name; it gets a study ID (UUID).
2. **Choose data-collection modules.** Each module (app usage, accelerometer, step count,
   battery, connectivity, activity recognition, etc.) is toggled **required / optional /
   off** per study, and sensor modules carry their own sampling rate + duty cycle. Collect
   only what the study needs — this is both good practice and a data-protection expectation.
3. **Add participants.** Each participant gets an enrollment code / QR that encodes the
   study ID, participant ID, and your server URL.
4. **Monitor.** The dashboard shows enrolled devices and last-upload times.
5. **Export.** The study's **Bulk Downloads** tab is the single place that covers every
   data family — a full-study background export (choose data types, Excel/CSV/JSON, and an
   optional date range), whole-study Time Use Diary CSVs, and per-questionnaire response
   CSVs. For a subset of people, tick rows on **Participants** and use *Download Data*.
   Output is plain and readable in R, Python, Excel — no proprietary tooling needed.

Which modules a given phone actually collects is the **intersection** of what the study
enables, what the participant consented to, and what the platform supports — a module a
device can't realize is silently dropped rather than blocking enrollment.

## Mobile apps

Participants need a Chronicle app build that points at **your** server. Public builds use
one-time enrollment links followed by per-device API keys; they do not carry a shared
deployment secret.

### Point the app at your server

The Google Play build and the public **"open" sideload build** both trust any valid
public-HTTPS Chronicle server:

- **Android from Google Play** — issue a one-time enrollment link from the dashboard. The
  link configures the server URL and the app displays it before the participant enrolls.
  No app rebuild or deployment-wide mobile secret is required.

- **Android sideload** — build the `open` product flavor:
  ```bash
  cd chronicle           # the Android submodule
  ./gradlew :app:assembleOpenRelease
  ```
  The `open` flavor sets `ALLOW_ANY_SERVER=true`, matching Play's hostname behavior. Both
  accept only a root URL on standard public HTTPS and rely on the device system trust store;
  plain HTTP, private CAs, URL credentials, query/fragment content, and path-prefixed base
  URLs are rejected. To ship the sideload flavor as a distinct store app, give it its own
  `applicationId` and store/signing configuration.

- **iOS** — in `chronicle-ios/chronicle/Config/Chronicle.local.xcconfig` set:
  ```
  CHRONICLE_ALLOW_ANY_SERVER = YES
  ```
  then build. Release builds validate the server certificate against the system trust
  store, so your server needs a valid publicly-trusted cert (Caddy handles this).

### Public-client credentials

Never compile a deployment-wide `MOBILE_SIGNING_SECRET` into a public app. A normal public
self-host deployment leaves `MOBILE_SIGNING_ENABLED=false`,
`MOBILE_SIGNING_REQUIRED=false`, `MOBILE_SIGNING_SECRET=`, and
`MOBILE_SIGNING_SECRET_PREVIOUS=`. A public client starts from a one-time enrollment link
issued by the dashboard and, after successful exchange, stores only its returned per-device
API key.

Only a controlled legacy/research-client fleet may opt in: set both booleans to `true` and
provide a generated 32+ character compatibility key. The configuration guard and backend
entrypoint reject mismatched booleans, an enabled mode without a key, or keys left populated
while the mode is disabled. Protect an opted-in value in `.env`: do not commit it or expose
it through logs, command arguments, shell transcripts, public app packages, or support
messages. The legacy rotation procedure is retained only for installations that explicitly
support those controlled old clients.

### Enroll a device

From the participant row in the dashboard, issue and scan the one-time enrollment QR/link.
Its access code is in the URL fragment rather than the query string, so browsers and
intermediaries do not send it as part of the HTTP request. Do not hand-construct, reuse, or
paste the code into support channels. Grant the OS permissions the study's modules need and
complete the per-module consent steps. The dashboard should then show the device with a
recent upload time.

### Play Console reviewer credential

Configure the scope through the dashboard; never reuse a real participant:

1. Create a dedicated reviewer study with active start/end dates. Complete its participant
   policy and save an explicit versioned **Data Collection** setting first. A legacy
   `AndroidSensor`-only setting is not valid for public enrollment.
2. Open **Participants**, add a synthetic non-PII ID such as `play-reviewer`, and keep it in
   `ENROLLED` state. The public reviewer route never changes researcher-controlled status.
3. Put only that study UUID and participant ID in `.env`, leave
   `CHRONICLE_REVIEWER_ACCESS_ENABLED=false`, start the stack, and run `./chronicle doctor`.
   Do not continue until the `reviewer-scope` check is `ok`; it verifies the live rows and
   active dates/status.
4. Run:

```bash
./chronicle rotate-secret reviewer
```

That command generates a 256-bit reusable secret directly into `.env`, enables the exact
reviewer endpoint, recreates the backend, and verifies readiness. Copy the value from a
trusted editor directly to Play Console. The browser/app submits it only in the
`X-Chronicle-Reviewer-Secret` header to
`POST /chronicle/v4/mobile/reviewer-enrollment`; never put it in a URL, local storage, or
Git. The response is `Cache-Control: no-store` and contains:

```json
{
  "enrollmentCode": "<fresh one-time code>",
  "preview": {
    "manifest": "<the normal authoritative enrollment manifest>",
    "manifestDigest": "<lowercase SHA-256 digest>"
  }
}
```

The reusable credential is scoped to that configured study only, is IP-rate-limited and
audited, and cannot authenticate any dashboard/admin API. Every successful call replaces
the prior outstanding reviewer invitation with a fresh 15-minute code. Normal participant
invitations keep their existing one-time behavior and are unaffected.

For a later review or a reset, use the dashboard to restore the same synthetic participant
to `ENROLLED` and ensure the study dates remain active. A prior destructive withdrawal must
be fully reset by an operator before reuse; the public route never bypasses pending deletion.
Then rerun `./chronicle doctor` and rotate the reviewer credential. Do not seed rows with SQL,
clone a real participant, or place the reusable secret in a participant field.

## Deployment compatibility

The release supports three private-dashboard modes, scheduled backups, optional monitoring,
and the exact storage combinations listed in
[DEPLOYMENT-COMPATIBILITY.md](DEPLOYMENT-COMPATIBILITY.md). Public-dashboard modes are not
shipped because the release does not yet ship a reviewed multi-user authentication path.

## Multi-user login (experimental, not shipped)

The release bundle does not claim Keycloak support. The previous overlay needed manual
route edits, a separately compiled frontend, realm bootstrap, and untested upgrade
coordination; presenting that scaffold beside supported overlays made an unfinished
container look production-ready. It now lives only in source checkouts at
`experimental/public-dashboard/auth.yml` and is excluded from release archives.

Promoting it back to `overlays/` requires automated coverage for all of the following:

1. **Route Keycloak through Caddy.** In
   `experimental/public-dashboard/Caddyfile`, add this inside the `route { … }`
   block, above `import chronicle_spa`:
   ```
   reverse_proxy /keycloak/* keycloak:8080
   ```
   and `docker compose restart web`. Use `reverse_proxy`, not `handle_path` — Keycloak
   must see the `/keycloak` prefix it was configured with, so the path must not be
   stripped.
2. **Publish an immutable frontend image with the supported authentication behavior.**
3. **Create the realm, client, and a user.** Create a `chronicle` realm, a `chronicle-web`
   OIDC client (set `OIDC_CLIENT_SECRET` in `.env` to match), and at least one user with an
   admin role. The source workspace's `docker/docker-compose.traefik.yml` documents the
   corresponding `OIDC_*` wiring for operators developing this experimental mode.

Until those tests exist, use the supported internal-dashboard login mode or an
institutional access layer in front of the private dashboard.

## Secret rotation

Do not hand-edit one side of a shared credential and restart containers piecemeal. Use
`./chronicle rotate-secret` for the dashboard, JWT, internal web, metrics, PostgreSQL,
Grafana, mobile HMAC, and TDE principal keys. It keeps a private recovery transaction,
health-checks the affected services, and writes secret-free receipts. See
[SECRET-ROTATION.md](SECRET-ROTATION.md), including the explicit forward/rollback command
for a host crash.

## Data deletion and uninstall

Deleting a participant or study is an application workflow with quarantine, verification,
and durable proof. Removing containers is not data deletion, and removing Docker volumes
does not remove bind-mounted backups. Follow
[UNINSTALL-DATA-DELETION.md](UNINSTALL-DATA-DELETION.md) for the exact distinction and safe
operator sequence.

## Upgrading

Your instance is independent of every other Chronicle deployment. Upgrade with a newer release bundle; do not
clone or build the source workspace on the server.

```bash
# After downloading and checksum-verifying the new release archive:
cd chronicle-selfhost-<new-version>/selfhost
./chronicle upgrade --from /absolute/path/to/chronicle-selfhost-<old-version>/selfhost
```

The command preserves operator settings but takes release/version/image pins from the new
bundle, keeps mutable backups/TLS state at its previous absolute location, validates the
PostgreSQL major version, stops and verifies every application writer, creates and verifies a
consistent pre-upgrade dump from that quiesced database, waits for the new stack, and writes
an upgrade receipt. Flyway migrations are automatic.

Read [UPGRADE-ROLLBACK.md](UPGRADE-ROLLBACK.md) before the first production upgrade. It
contains the exact forward-recovery and tested rollback procedure. PostgreSQL major changes
are deliberately refused and use the separate dump/restore runbook.
