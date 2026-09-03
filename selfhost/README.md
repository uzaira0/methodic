# Chronicle — Self-Hosting Guide

Chronicle is a research data-collection platform: participants install a mobile app
(Android/iOS) that uploads sensor and app-usage data to a server you control, and
researchers manage studies and export data from a web dashboard.

This directory is a **self-contained deployment** of the Chronicle server, trimmed for
teams who want to run their own instance with minimal maintenance. Every deployment is
independent: you bring your own domain, your own database, and your own users.

> **Design choice: encrypted at rest, and no unrecoverable data.** PostgreSQL runs with
> transparent encryption-at-rest enabled by default, so a stolen disk or a copied data
> volume is useless without the key. It cannot lock you out: backups are ordinary
> compressed SQL dumps containing no encryption at all, and they restore into any
> Postgres even if the key is gone — so the stack refuses to run encrypted without
> backups turned on, and keeps a copy of the key inside the backup set. See
> [At-rest encryption](#at-rest-encryption) for the full recovery model, or set
> `ENABLE_ENCRYPTION=false` to turn it off.

---

## What you get

| | |
|---|---|
| **4 long-running services** | PostgreSQL, backend API, Caddy (dashboard + API routing + optional TLS), and a backup sidecar. Four more run once and exit: `config-guard` (refuses an unsafe configuration before anything starts), `cert-init` (certificates), `db-init` (encryption at rest), `frontend` (copies the prebuilt dashboard assets) |
| **1 supported operator command** | `./chronicle up`. It validates the host and configuration, initializes required submodules and source images when run from a clone, then starts the Compose stack. |
| **Encrypted at rest** | On by default, with backups that restore without the key so it cannot lock you out |
| **You control TLS** | sit behind your institution's load balancer, or terminate TLS on the stack with your own cert (no forced Let's Encrypt) |
| **100% open-source** | No proprietary components in the default stack |
| **Modular add-ons** | Backups and private monitoring are explicit overlays. Public-dashboard and Keycloak scaffolds are physically separated under `experimental/` and are not part of release bundles. |

## Requirements

- A Linux host with **Docker** and the **Docker Compose plugin**. The `./chronicle` script
  also runs on macOS (tested against Docker via OrbStack), which is useful for trying the
  stack out locally; deploy it on Linux.
- **~4 vCPU / 8 GB RAM** is comfortable; a pilot with a handful of devices runs on
  **2 vCPU / 4 GB**. See [Sizing](#sizing).
- A **hostname** (e.g. `study.example.org`) and a **TLS certificate** for it. On an
  institutional server this is normally your institution's load balancer + institutional
  cert; you do **not** need a public Let's Encrypt setup. See
  [Required configuration](#required-configuration).
- A published release bundle needs only outbound HTTPS access to pull its digest-pinned
  images; it needs no Java, Bun, Gradle, Git checkout, submodules, Xcode, or Android Studio.
  The source-clone path below additionally needs Git and outbound build dependency access;
  Java, Bun, and Gradle still run inside the image builds rather than on the host.

## Quick start from the Methodic repository

```bash
# 1. Clone the public repository. The operator script initializes only the server
#    submodules it needs; chronicle-ios intentionally remains unchecked out.
git clone https://github.com/uzaira0/methodic.git chronicle
cd chronicle/selfhost

# 2. Configure interactively. Secrets are generated and never printed.
./chronicle setup

# 3. Validate the host, pull, and start. This is the whole deployment.
./chronicle up

# 4. Prove the server is exposed the way you intended.
./chronicle verify

# 5. Confirm backups and monitoring are visible and actionable.
./chronicle doctor
./chronicle monitoring status    # when monitoring was selected during setup
```

The first `up` builds the backend, dashboard, and proxy images from the checked-out source,
so it takes longer than a restart. Each local tag contains the exact Methodic revision, and
the backend/dashboard metadata records that revision too; after a fast-forward pull and
submodule update, the next `up` builds new tags instead of silently reusing stale `:source`
images. The command refuses a mismatched or dirty build input rather than assigning it a
published revision. Published release bundles use digest-pinned images and the same
`setup` / `up` / `verify` interface.

To update a source checkout, first confirm that local work is committed on an appropriate
branch and that the current deployment has a recent verified backup. Then update by exact
gitlinks and let the operator command build the new revision:

```bash
cd /path/to/chronicle
git pull --ff-only
git submodule update --init --recursive
cd selfhost
./chronicle up
./chronicle verify
./chronicle doctor
```

For a production version transition, the signed release-bundle `upgrade` workflow remains
the preferred path because it quiesces writers and creates a verified rollback dump before
allowing database migrations.

`./chronicle setup` is the recommended path for a first-time operator. Copying
`.env.example` manually remains available for automation.
It generates deployment secrets directly into a mode-`0600` `.env`, asks you to choose the
dashboard password without echoing it, and sends that password to Caddy over stdin to
create a **bcrypt hash**. It never prints a generated secret or cleartext password. It also
writes the `COMPOSE_FILE` line that matches your answers, which is what makes step 3 need no
`-f` arguments.

Nothing starts until the configuration passes. `config-guard` runs first, and every other
service waits for it: placeholder secrets, a secret that is too short, a production mode
with no backups, a public dashboard with no reviewed authentication, `REQUIRE_MFA`
paired the wrong way — each stops the deployment before a container is started, with the
specific `.env` line to change. Then `cert-init` prepares the certificate the dashboard
listener needs, and `db-init` turns on encryption at rest *before* the backend first
connects, so every table is created encrypted rather than converted afterwards.

### No domain name yet? Trial it on this machine

`./chronicle setup` offers a third option: **a trial on this machine, with test phones on
the same wifi.** It needs no hostname, no certificate and no proxy — Caddy runs a small CA
inside the stack and issues its own certificate for this machine's LAN address.

```bash
./chronicle up
docker compose logs ca-export     # scan the QR code with the phone
```

Each test phone installs that CA once (the QR points at `http://<lan-ip>/local-ca.crt`),
after which it trusts the server. It is a **trial mode**: never ask study participants to
install a CA. Moving to a real deployment is a one-line change to `COMPOSE_FILE` and
nothing else in `.env`.

> Android caveat: a user-installed CA is trusted by browsers but **not by apps**, unless the
> app ships a `network-security-config` that opts in. The Chronicle `open` build ships that
> entry (`app/src/open/res/xml/open_network_security_config.xml`), so use the `open` APK
> (`:app:assembleOpenRelease`) for trial phones. Play/research builds stay system-CA-only —
> on those, enrollment fails with a TLS error while the same URL loads fine in Chrome on the
> same phone.

### Editing .env by hand instead

```bash
cp .env.example .env
chmod 600 .env
$EDITOR .env          # DOMAIN, deployment secrets, and DASHBOARD_PASSWORD_HASH
./chronicle up
```

`.env` is the only file you edit. It carries `COMPOSE_FILE`, so plain `docker compose`
picks up the right overlays with no `-f` arguments — the deployment modes are described in
`.env.example` next to that line, and the default is the recommended one (your load
balancer terminates TLS, the dashboard is reachable only on a private interface, backups
on). Generate the password hash without putting the cleartext in shell history or process
arguments:

```bash
read -rsp 'Dashboard password: ' DASHBOARD_PASSWORD; echo
CADDY_IMAGE="$(sed -n 's/^CADDY_IMAGE=//p' .env)"
printf '%s\n' "$DASHBOARD_PASSWORD" | docker run --rm -i --network none --read-only \
  --entrypoint caddy "$CADDY_IMAGE" hash-password
unset DASHBOARD_PASSWORD
```

### Prove it, from outside

`./chronicle verify` is the step worth not skipping: it calls the running server from
outside and checks the things you cannot eyeball — that the researcher dashboard API is
absent from the public listener, that the direct backend routes are refused, that mobile
ingest is rate limited, that every table really is encrypted and a key-free dump exists.
It exits non-zero if the deployment does not match `.env`.

`./chronicle check` is worth running before the first pull/start on a new host. It repeats the
configuration checks (in the same `config-guard` container, so the two can never
disagree) and adds three a container cannot make from inside its own network namespace:
whether the bind address is one this host actually has, whether the port is already taken,
and whether another Compose project of the same name would be adopted. On the plain
`docker compose up -d` path, Docker's own bind error is the fallback for the first two.

Then browse to `https://<your-domain>/chronicle`. Point a Chronicle app build (see
[Mobile apps](#mobile-apps)) at the same domain to enroll a device.

Other `./chronicle` subcommands: `up` (check, then `docker compose up -d`), `upgrade`
(validated previous-release upgrade plus automatic backup), `restore` (stop every writer,
restore a verified dump, and restart only after health passes), `rotate-secret` (one guarded
credential change or interrupted-operation recovery), `deletion-status`, `status`, `logs`,
`doctor` (actionable checks, or machine-readable `--json`), `monitoring` (status and private
Viewer accounts), `down`. Use `./chronicle up` for normal operation. Direct Compose is an
automation-level interface only after `.env`, submodules, and images are prepared; it skips
host-address, port-collision, and deployment-adoption checks. Restore and version
transitions always use their guarded commands.

> Everything below documents what that command does and how to change it.

## Required configuration

Beyond flipping overlays on/off, these are the decisions/values the deploying team must
set. The participant-facing override, legacy mobile compatibility, and email are optional;
setup supplies safe defaults or generated values for the remaining entries where possible:

| # | What | Where | Notes |
|---|---|---|---|
| 1 | **Listener hostname** | `DOMAIN` in `.env` | The FQDN served by this stack or its direct proxy listener. |
| 2 | **Participant-facing origin (optional)** | `CHRONICLE_PUBLIC_BASE_URL` | Exact HTTPS root used in enrollment links and signed manifests when it differs from `https://DOMAIN`; no path, query, fragment, or credentials. |
| 3 | **TLS strategy** | see below | The main decision on an institutional box. |
| 4 | **DB password** | `POSTGRES_PASSWORD` | Any strong secret; only this stack uses it. |
| 5 | **Legacy mobile compatibility (optional)** | `MOBILE_SIGNING_ENABLED`, `MOBILE_SIGNING_REQUIRED`, `MOBILE_SIGNING_SECRET` | Off and blank by default. Enable both booleans and generate the server-side key only for a controlled legacy/research-client fleet. Public clients use one-time enrollment links and per-device API keys. |
| 6 | **Dashboard access** | see [Securing the dashboard](#securing-the-dashboard) | Internal listener + Caddy password, optionally behind your institution's access layer. The release does not ship Keycloak. |
| 7 | **Listen address** | `HTTP_BIND`, `HTTP_PORT` | Where your proxy reaches the stack. **Must not be `127.0.0.1` if the proxy is on another host** — see below. |
| 8 | **Email (optional)** | `SMTP_*` | Only if the study sends participant notification emails. |

### TLS — the institutional decision

This stack does **not** manage certificates by default. Choose the model that fits your
infrastructure:

- **Behind your institution's load balancer (recommended).** Your F5 / nginx / Apache /
  cloud LB terminates TLS with the **institution's certificate** and forwards to
  `HTTP_BIND:HTTP_PORT`. Ensure it sends `X-Forwarded-Proto: https` — Caddy here honors it
  (`trusted_proxies static private_ranges`). This is the supported pattern behind an
  institutional TLS-terminating proxy. Do not enable the tls overlay.

  > **Set `HTTP_BIND` to an address your balancer can actually reach.** It defaults to
  > `127.0.0.1`, which is correct only when the proxy runs on this same machine. If it does
  > not, this is the one mistake nothing on the box can catch: the stack starts, every
  > startup check passes, and `./chronicle verify` passes too — it probes from inside the
  > host, so it sees a healthy server — while the balancer gets connection refused.
  > Startup warns whenever `HTTP_BIND` is loopback, and `verify` ends by printing the
  > one-line `curl` to run against your VIP. Run it.

  If your balancer **re-encrypts** to the pool member instead of forwarding plain HTTP,
  this mode is wrong — use "terminate TLS on the stack" below and give Caddy a certificate.
- **Terminate TLS on the stack with your own certificate.** Drop `cert.pem` + `key.pem`
  (institution-issued or commercial) into `./tls`, then put
  `overlays/mode-own-tls-internal.yml` in `COMPOSE_FILE`. No Let's Encrypt. This adds **no
  container** — it swaps the same Caddy onto `Caddyfile.split.tls`, and `cert-init` fixes
  the key's ownership so Caddy, which runs with every capability dropped, can read it.

The supported release intentionally has no public-dashboard mode: its built-in login is
safe only behind the private listener, while the unfinished SSO path is not shipped. The
old public listeners and Keycloak scaffold are retained only under `experimental/` in a
source checkout. See [Deployment compatibility](docs/DEPLOYMENT-COMPATIBILITY.md).

> If your certificate is issued by a **private/internal CA**, the mobile apps must be told
> to trust that CA — see [Mobile apps](#mobile-apps). A publicly-trusted certificate
> (including most institutional certs that chain to a public root) needs no device changes.

## Architecture

```
           ── pick ONE way to terminate TLS ──
   ┌─────────────────────┐   ┌─────────────────────────────────────┐
   │ institution LB / F5 │   │ OR  a mode-own-tls-* overlay — the   │
   │ (institutional cert)│   │     SAME web container, with your    │
   │                     │   │     cert.pem/key.pem. No ACME.       │
   └──────────┬──────────┘   └──────────────────┬──────────────────┘
              │  http (X-Forwarded-Proto: https) │
              └───────────────┬──────────────────┘
                              ▼
                      ┌───────────────┐
                      │  Caddy (web)  │  serves the dashboard's static files,
                      │   :8080       │  routes /chronicle/{v2,v3,v4,api/web,study,…} → backend,
                      └───────┬───────┘  and optionally terminates TLS — one container
                              │
                      ┌───────▼───────┐        ┌──────────────┐
                      │    backend    │───────▶│  PostgreSQL  │  plain (no TDE) → portable backups
                      │  (Spring)     │        └──────────────┘
                      └───────────────┘
```

The routing lives in three supported Caddyfiles, with the route lists factored into
`caddy/snippets.caddy`. All three import those same snippets, so their route
definitions cannot drift apart:

| File | Listens | Mounted by |
|---|---|---|
| `Caddyfile.split` | `:80` public, `:8081` internal (HTTPS) | `overlays/mode-behind-proxy-internal.yml` — the default |
| `Caddyfile.split.tls` | `:443` public, `:8081` internal (HTTPS) | `overlays/mode-own-tls-internal.yml` |
| `Caddyfile.split.local` | `:443` public (Caddy's own CA), `:80` CA download + redirect, `:8081` internal | `overlays/mode-local-https.yml` — trial only |

The overlay is what publishes the ports *and* what mounts the matching Caddyfile, in the
same file — so there is no combination of settings that mounts a config for a listener the
stack never publishes. `verify-config.sh` checks that pairing.

The base file publishes no ports. The selected mode publishes either plain HTTP to an
upstream TLS proxy or HTTPS using your certificate/private trial CA; there is no forced
Let's Encrypt.

Two traffic paths share the server:
- **Mobile ingest** (`/chronicle/v3/*`, `/chronicle/v4/*`) — public clients authenticate
  with the per-device API key returned by one-time enrollment, never by a dashboard login.
  Optional shared-HMAC verification exists only for an explicitly controlled legacy fleet.
  Never put a password gate in front of these paths.
- **Dashboard** (`/chronicle/…`) — for researchers. Protect it (see
  [Securing the dashboard](#securing-the-dashboard)).

## Modular overlays

`COMPOSE_FILE` in `.env` is the list of compose files, colon-separated. Docker Compose
reads it from `.env` itself, which is why plain `docker compose up -d` needs no `-f`
arguments. Exactly one of the three supported `mode-*.yml` files must be in it; the rest
are optional within the declared combinations:

| Overlay | Adds | Put it in `COMPOSE_FILE` when… |
|---|---|---|
| `overlays/mode-*.yml` | The listener config and the ports for one deployment mode | **Always — exactly one.** See `.env.example`. |
| `overlays/backups.yml` | Scheduled `pg_dump` with rotation → `./backups`, plus one dump at startup | **Always in production, and required whenever encryption is on.** |
| `overlays/monitoring.yml` | Private Grafana, VictoriaMetrics, VictoriaLogs, sanitized Chronicle logs, host/container/application/database/backup probes and visible alerts | Trusted observers need to see operational mistakes and failures. |

The authoritative supported/rejected combinations, including encryption and backup
requirements, are in
[docs/DEPLOYMENT-COMPATIBILITY.md](docs/DEPLOYMENT-COMPATIBILITY.md). CI renders every
declared row with monitoring both off and on and executes the same configuration guard
that gates startup.

```ini
# .env — default mode, backups, and monitoring:
COMPOSE_FILE=docker-compose.yml:overlays/mode-behind-proxy-internal.yml:overlays/backups.yml:overlays/monitoring.yml
```

There is **no observability stack in the base deployment**. Monitoring remains opt-in and
adds no required variable or health dependency when absent. `./chronicle setup` offers it
and writes the overlay, private bind, and retention values without manual Compose editing.

The backup sidecar waits for both PostgreSQL and the migrated backend before taking its
startup dump. That readiness check runs inside the container as well as through Compose,
so a host or Docker daemon restart cannot race the dump against database startup. Tune
`BACKUP_STARTUP_TIMEOUT_SECONDS` only when a deliberately slow migration needs longer.

Monitoring binds Grafana to `127.0.0.1:3000` by default. Use `GRAFANA_PORT` to avoid a
local collision or `GRAFANA_BIND` for one reviewed private interface; startup refuses a
wildcard bind. Reach the loopback default through an SSH tunnel. VictoriaMetrics retains
30 days and VictoriaLogs retains 14 days by default; each has a 5 GiB budget. The overlay
provisions immutable System, Application, Database and Storage, Containers, Operational
Events, and sanitized Operational Logs dashboards plus dashboard-visible alerts. It keeps
running when the application or configuration guard fails.

Create one read-only account per trusted observer; passwords are prompted without echo and
never appear in command arguments or receipts:

```bash
./chronicle monitoring status
./chronicle monitoring add-viewer alice
./chronicle monitoring reset-viewer alice
./chronicle monitoring remove-viewer alice
```

No notification leaves the host. Self-host alert routing is permanently muted, while firing and
historical states remain visible in Grafana. Start diagnosis with `./chronicle doctor`; each
alert links to the bundled [monitoring runbook](docs/MONITORING-RUNBOOK.md).

Backend and Caddy emit structured JSON envelopes, PostgreSQL emits a parseable timestamp and
SQLSTATE prefix, and guarded operator commands emit JSON events. Fluent Bit accepts only these
four Chronicle sources and keeps only finite operational fields. Raw messages, headers,
queries, payloads, SQL, addresses, identity fields, and stack traces never enter VictoriaLogs;
an unknown line becomes a generic service/severity event instead of being forwarded verbatim.

Guarded routine commands also append mode-0600 JSON receipts below
`${CHRONICLE_STATE_DIR}/operator-receipts/operations/`. Each receipt contains only the
operation, UTC timestamp, release version, outcome, and finite failure category. Viewer
passwords and deployment credentials are never included. These receipts exist whether or not
the monitoring overlay is enabled; monitoring additionally projects the latest result into the
Operational Events dashboard.

Asynchronous export artifacts live in the dedicated `export_data` volume rather than the
backend container filesystem, so downloads survive backend restarts and release upgrades. The
Database and Storage dashboard shows its current size alongside database and backup storage.

The generated [capability ownership table](docs/CAPABILITY-OWNERSHIP.md) records which
backend workflows belong to the researcher web UI, participant web UI, mobile clients,
operator CLI, Grafana, or are API-only by design. Local CI fails if a required self-host
workflow loses its declared user-facing owner or evidence.

Chronicle developers can run the complete self-host product gate locally with
`./scripts/local-ci.sh selfhost` from the release source root. It exercises the
noninteractive first-time setup, optional-monitoring privacy rules, supported Compose
matrix, sanitized-log fixtures, and generated release bundle; GitHub Actions is not an
acceptance dependency.

## Securing the dashboard

With one of the `mode-*-internal` overlays (the default in `.env.example`) the researcher
dashboard is **not served on the public listener at all** — the API returns
404 there — and the internal listener it does live on is protected by three independent
controls, all applied automatically. There is nothing to opt into.

**1. Source-address allowlist.** `DASHBOARD_ALLOWED_IPS` (space-separated CIDRs) decides
who may reach the dashboard at all. Narrow it to your own subnet; the default is every
private range:

```bash
DASHBOARD_ALLOWED_IPS='10.20.30.0/24'
```

It is matched against the real TCP peer address, **not** `X-Forwarded-For`, so a caller
cannot forge their way past it with a header. A disallowed source gets `403` and is never
offered a password prompt.

**2. A single global username and password.** Set once, shared by everyone who uses the
dashboard, and stored **only as a bcrypt hash**, so the cleartext cannot be recovered from
the server. (`./chronicle setup` asks you to choose it silently and writes just the hash.)
To change it without leaking it through shell history, process arguments, or an intermediate
file:

```bash
./chronicle rotate-secret dashboard
```

The command reads the password twice without echo, sends it to the digest-pinned Caddy
image over stdin, atomically updates `.env`, recreates `web`, and proves the new password.

This is a perimeter password in front of the whole dashboard. It is not per-user identity.
The old Keycloak scaffold is experimental and excluded from release bundles; see
[docs/CONFIGURATION.md](docs/CONFIGURATION.md#multi-user-login-experimental-not-shipped).

**3. TLS on the internal listener.** Basic authentication over plain HTTP puts the password
on the wire in clear, so the internal listener always runs HTTPS. The `cert-init` service
generates a self-signed certificate with the right SANs if none exists; add more names with
`INTERNAL_CERT_SANS`. Browsers will warn until you trust it; to use a real certificate,
replace `tls/internal-cert.pem` and `tls/internal-key.pem` and it will be left alone.

Startup refuses to bring anything up if the password hash is missing or is not a bcrypt
hash, or if the allowlist is empty — any of which would mean no gate at all.
`./chronicle verify` proves from outside that the gate is closed. Ask it to read the correct
password without putting that value in shell history or an environment assignment:

```bash
./chronicle verify --dashboard-password
```

> Participant traffic is deliberately never gated: phones and the participant forms
> (`/chronicle/survey`, `/chronicle/questionnaire`, `/chronicle/time-use-diary`) cannot
> answer a password prompt, and they are served from the public listener.

### Internal-only dashboard (split exposure)

You usually cannot simply put the whole server behind the VPN: participant phones upload
from cellular networks, so ingest has to stay publicly reachable. Setting
a `mode-*-internal` overlay splits the two — one file both selects the Caddy config and
publishes the ports, so they cannot disagree:

```bash
# in .env
COMPOSE_FILE=docker-compose.yml:overlays/mode-behind-proxy-internal.yml:overlays/backups.yml
# then: docker compose up -d
```

That serves two listeners:

| | Port | Carries | Publish to |
|---|---|---|---|
| **Public** | 80 | Mobile ingest, participant forms, static SPA | Your institutional proxy / the internet |
| **Internal** | 8081 | The above **plus** the researcher dashboard API | A VPN or management interface only |

Set `INTERNAL_BIND` in `.env` to that interface (e.g. `INTERNAL_BIND=10.0.0.5`). It
defaults to `127.0.0.1`, so if you forget, the dashboard API is exposed to nothing and you
reach it over an SSH tunnel — it fails closed. `./chronicle check` refuses to start if the
address is not one this host actually has, rather than letting Docker fail obscurely later
(that check needs the host's own network namespace, so it is the one thing the compose path
cannot do for you).

**This is the configuration that makes the dashboard usable without an SSO server.** Because
every researcher login path (`/chronicle/v3/auth/*`, including `testing-login`, which mints
an admin session) is refused on the public listener, you can turn on the simple built-in
login for your team:

```ini
# .env — only safe together with a mode-*-internal overlay
TESTING_LOGIN_ENABLED=true
REQUIRE_MFA=false             # the built-in login cannot prove MFA — see below
INTERNAL_BIND=10.0.0.5        # your VPN / management interface
```

`REQUIRE_MFA=false` is not optional here, and `./chronicle setup` writes both together when
you choose the internal dashboard. Dashboard tokens are normally required to carry an
`amr`/`acr` claim proving multi-factor authentication, and the built-in login mints its own
token with no such claim. Leave enforcement on and the dashboard signs in and then rejects
every API call with `401 Multi-factor authentication is required` — while
`/chronicle/v3/auth/session` still returns 200, so it looks like a broken deployment rather
than a setting. Startup refuses the combination and says so.

What protects the dashboard in that mode is the internal-only listener, the source
allowlist and the global password — not MFA. The current release does not claim a supported
multi-user SSO path. Startup refuses `REQUIRE_MFA=false` with a public dashboard.

Without a `mode-*-internal` overlay, `TESTING_LOGIN_ENABLED=true` would expose admin-session minting
to the internet. Leave it `false` unless the dashboard API is internal-only.

Verify the boundary after starting — every one of these must 404 from outside:

```bash
for path in /chronicle/v3/auth/testing-login /chronicle/v3/auth/session \
            /chronicle/api/web/study /datastore/ /chronicle/datastore/; do
  printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' http://<public-host>:8080$path)" "$path"
done
```

The boundary is **which port the request arrived on**, not the client IP, so it keeps
working when an upstream load balancer rewrites the source address.

Two things worth understanding before you deploy it:

- **The static dashboard files stay public, deliberately.** Participants open
  `/chronicle/survey`, `/chronicle/questionnaire` and `/chronicle/time-use-diary` on their
  own phones, and those pages ship in the *same* JavaScript bundle as the researcher
  screens. Serving the bundle publicly is harmless: with the dashboard API prefixes absent
  from the public listener, the researcher screens load and can fetch nothing. The security
  boundary is the API, not the assets.
- **A few researcher endpoints live under `/chronicle/v3/`.** `TimeUseDiaryController` and
  `SurveyController` are mounted at `/v3/time-use-diary` and `/v3/survey`, and each hosts
  both participant endpoints and bulk-data downloads. The public listener denies the
  download paths by regex while leaving the participant paths open. The backend authorizes
  all of them independently; the Caddy rule is defence in depth.

Verify after starting — the first two must 404 and the rest must succeed:

```bash
PUB=http://<public-host>:8080; INT=http://<internal-ip>:8081
curl -o /dev/null -w '%{http_code} api/web\n'    $PUB/chronicle/api/web/study        # 404
curl -o /dev/null -w '%{http_code} tud-data\n'   $PUB/chronicle/v3/time-use-diary/S/data  # 404
curl -o /dev/null -w '%{http_code} survey\n'     $PUB/chronicle/survey               # 200
curl -o /dev/null -w '%{http_code} ingest\n'     $PUB/chronicle/v4/                  # not 404
curl -o /dev/null -w '%{http_code} dashboard\n'  $INT/chronicle/api/web/study        # 200
```

## Rate limiting

Caddy rate-limits requests before they reach the backend, so a misbehaving device or a
scripted client cannot saturate the API. Two independent buckets, keyed per client IP:

| Zone | Matches | Default | Setting |
|---|---|---|---|
| `mobile_ingest` | `/chronicle/v2/*`, `/chronicle/v3/*`, `/chronicle/v4/*`, except `/chronicle/v3/auth/*` | 20 requests / second | `RATE_LIMIT_MOBILE_EVENTS`, `RATE_LIMIT_MOBILE_WINDOW` |
| `dashboard` | `/chronicle/api/web/*`, `/chronicle/limits/*`, `/chronicle/v3/auth/*` | 20 requests / second | `RATE_LIMIT_WEB_EVENTS`, `RATE_LIMIT_WEB_WINDOW` |

`/chronicle/v3/auth/*` is browser traffic that happens to live under the mobile prefix, so
it is metered with the dashboard. One dashboard page load spends two requests there
(`/auth/session`, then `/auth/testing-login`); at the mobile rate a reload or a second tab
was enough to turn a healthy deployment into *"Session initialization failed — Testing login
request failed with status 429"*. Brute-force protection does not depend on this: the backend
applies its own 10 requests/minute limit to the same paths.

Paths outside both lists — static dashboard assets, `/health` — are **not** rate limited.
Over the limit returns **HTTP 429**. `./chronicle verify` asserts the mobile limiter
actually fires, so a build that silently lost it fails the check.

Buckets are keyed on `{client_ip}`, not the connecting address. Behind a load balancer
every request arrives from the balancer, so keying on the connection would put all
participants in one bucket and let the first busy device throttle everyone. Caddy reads
the real client from `X-Forwarded-For`, which is why `trusted_proxies` has to be right.

Two things to know before you change anything:

- **A 429 during your own testing is usually the limiter working, not a bug.** Scripted
  checks fire far faster than a real device. `./chronicle verify` backs off and retries
  past the window for exactly this reason.
- **Rate limiting comes from a Caddy plugin.** The release pipeline builds, scans, attests,
  and digest-pins the dedicated Caddy image. Pointing `CADDY_IMAGE` at stock Caddy breaks
  startup because the stock binary cannot parse `rate_limit`; `./verify-config.sh` checks
  that the release image contract remains in Compose.

Real devices upload in batches on an interval, not in bursts, so the mobile default is
comfortable for normal enrollment. Raise it if you run large synchronous backfills.

## Managing studies, participants, export, and deletion

Day-to-day study and participant actions are done from the dashboard; the CLI reports the
durable deletion proof. See
[docs/CONFIGURATION.md](docs/CONFIGURATION.md#managing-studies):

- Create a **study**, toggle which data-collection modules are required/optional, set
  sensor sampling rates.
- Add **participants** (each gets an enrollment code / QR).
- **Export** from the study's **Bulk Downloads** tab, which is the one place that covers
  every data family:
  - *Full study export* — every participant, run server-side as a background job. Pick
    which data types to include, the format (Excel / CSV / JSON) and an optional date
    range; download the artifact from the job list when it finishes.
  - *Time Use Diary* — whole-study CSV per variant (DayTime / NightTime / Summarized).
  - *Questionnaire responses* — every response for a questionnaire, as CSV.

  For a subset of people, tick rows on the **Participants** tab and use *Download Data*,
  which takes the same data types plus a date range and filename.

  There is no cleaning step in Chronicle beyond the optional `Preprocessed` usage-events
  type: exports are raw tables. Clean and analyze offline in R, Python, etc. — nothing
  proprietary is needed to read any of the formats.

Participant and study deletion are delayed, verified workflows rather than volume removal.
They immediately quarantine live rows, then physically erase them after the seven-day
window when no retention hold applies. Backups follow their own retention policy. Read
[docs/UNINSTALL-DATA-DELETION.md](docs/UNINSTALL-DATA-DELETION.md) before either deleting
product data or removing an installation; those are deliberately different operations.

## Mobile apps

Participants need a Chronicle app pointed at *your* server. The Google Play build and the
public **"open" sideload build** both accept any valid public-HTTPS Chronicle server:

- **Android from Google Play:** open the one-time enrollment link issued by your dashboard.
  The link supplies your server URL, which remains visible on the enrollment screen for the
  participant to verify before continuing.
- **Android sideload:** build the `open` product flavor — `./gradlew :app:assembleOpenRelease`.
  Like Play, it trusts any `https` server using the device system trust store
  (`ALLOW_ANY_SERVER`).
- **iOS:** set `CHRONICLE_ALLOW_ANY_SERVER = YES` in `Chronicle.local.xcconfig` and build.

Do not put `MOBILE_SIGNING_SECRET` in a public Android or iOS build. From the dashboard,
issue a one-time enrollment link for the participant; the app exchanges it once and stores
the returned per-device API key. A normal setup writes `MOBILE_SIGNING_ENABLED=false`,
`MOBILE_SIGNING_REQUIRED=false`, and blank current/previous shared keys. Setup generates a
compatibility key only after an explicit yes for a controlled legacy/research-client fleet;
the startup guard rejects every partial opt-in. Details are in
[docs/CONFIGURATION.md](docs/CONFIGURATION.md#mobile-apps).

**Mobile apps and TLS trust.** The apps validate the server certificate against the device
trust store. If your server's cert chains to a **public CA** (most institutional and
commercial certs do), nothing extra is needed. The Play artifact intentionally does not
trust private CAs or plain HTTP. The local trial mode is therefore for operator-owned test
devices and is not compatible with the Play release without a publicly trusted endpoint.
For a private/internal CA on a development-only build, Android requires an explicit
network-security-config that trusts user CAs;
iOS: install + enable the CA profile (then it's system-trusted, no app change).

### Google Play reviewer access

Play Console needs an access credential that remains usable across review attempts, while
normal participant invitations must stay one-time. Chronicle keeps those roles separate:
the Console credential can call only `POST /chronicle/v4/mobile/reviewer-enrollment`; it
cannot authenticate dashboard, admin, export, or participant-data APIs. Each accepted call
returns a fresh 15-minute one-time enrollment code plus its consent manifest.

Prepare the pinned synthetic scope in the dashboard before enabling the credential:

1. Create a dedicated **Play reviewer** study whose start/end window includes the review
   period. Complete its participant policy (privacy/withdrawal/support URLs) and save an
   explicit versioned **Data Collection** setting before enrolling anything. Legacy
   `AndroidSensor`-only studies cannot issue public enrollment manifests.
2. In that study's **Participants** page, add one synthetic, non-PII participant such as
   `play-reviewer`, then explicitly set its status to `ENROLLED`. The public bootstrap does
   not change researcher-controlled participation state; never point this feature at a real
   participant.
3. Copy the study UUID and synthetic participant ID into the mode-`0600` `.env`:

```ini
CHRONICLE_REVIEWER_STUDY_ID=00000000-0000-0000-0000-000000000000
CHRONICLE_REVIEWER_PARTICIPANT_ID=play-reviewer
```

4. Leave `CHRONICLE_REVIEWER_ACCESS_ENABLED=false`, start the stack, and require
   `./chronicle doctor` to report `reviewer-scope` as `ok`. Configured scope IDs are checked
   even while the public credential is disabled; the doctor checks the live database, not
   just the four environment variables. If review left the participant paused or the study
   outside its dates, restore `ENROLLED` status and active dates in the
   dashboard, then rerun the doctor.
5. Generate and enable the credential without printing it:

```bash
./chronicle rotate-secret reviewer
```

The rotation command repeats the live scope check and refuses to publish a credential for
missing or inactive rows. For a later Play review, keep the same synthetic identity; reset
its dashboard status to `ENROLLED`, confirm the study remains active, run
`./chronicle doctor`, and rotate the reviewer credential for the new Console review window. If a prior
reviewer used destructive withdrawal, the operator must restore/reset this synthetic row
before reuse; the public route never bypasses a pending deletion.

Open `.env` in a trusted local editor and copy `CHRONICLE_REVIEWER_ACCESS_SECRET` directly
into Play Console. Do not place it in an enrollment URL, app storage, Git, logs, screenshots,
or support messages. The endpoint is IP-rate-limited and audited; repeated successful calls
intentionally issue a new one-time code and revoke an outstanding reviewer code. Rotating
the Console credential invalidates the old value immediately, so update Play Console in the
same maintenance window. To disable access, set `CHRONICLE_REVIEWER_ACCESS_ENABLED=false`
and recreate the backend; the route then answers `404`.

`./chronicle verify` exercises this authenticated endpoint when reviewer access is enabled.
That check mints a fresh invitation and replaces the prior outstanding reviewer code. Run
it before giving the reviewer a link, or issue a fresh link afterward.

## Day-2 operations

- **Backups & restore:** [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md)
- **Upgrades and rollback:** [docs/UPGRADE-ROLLBACK.md](docs/UPGRADE-ROLLBACK.md) — verify
  and extract the new bundle, then run `./chronicle upgrade --from /path/to/old/selfhost`.
  It validates both bundles, makes a pre-upgrade dump, waits for migrations/health, and
  records the recovery information.
- **Secret rotation and crash recovery:**
  [docs/SECRET-ROTATION.md](docs/SECRET-ROTATION.md) — guarded dashboard, JWT, internal,
  metrics, PostgreSQL, Grafana, mobile-overlap, and TDE procedures with automatic rollback.
- **Supported deployment combinations:**
  [docs/DEPLOYMENT-COMPATIBILITY.md](docs/DEPLOYMENT-COMPATIBILITY.md).
- **Participant/study deletion and complete uninstall:**
  [docs/UNINSTALL-DATA-DELETION.md](docs/UNINSTALL-DATA-DELETION.md).
- **Logs:** `docker compose logs -f backend` (or any service). For durable/aggregated
  logs, set a reviewed Docker logging driver. Loki is not part of this release.
- **Audit trail:** every audited action is written twice — to the `audit_logs` table and,
  as one JSON object per line for SIEM ingestion, to `audit.log` on the `audit_logs`
  volume (`docker compose exec backend cat /var/log/chronicle/audit.log`). That volume is
  separate from the container log stream, which is capped and rotated. The backend
  refuses to start if the volume is missing or unwritable, so the trail cannot be lost
  silently. Back the volume up alongside `./backups`.

## At-rest encryption

**On by default** (`ENABLE_ENCRYPTION=true`), using Percona `pg_tde`, which is already in
the pinned Postgres image — nothing extra to install and no extra deployment step. The key
is generated on first start, by the `db-init` service, and kept on its own Docker volume,
separate from the data, so a copy of `postgres_data` on its own is useless.

**What it protects:** a stolen disk, or a copied data volume.
**What it does not protect:** anyone with root on the running box. The key is on the box by
design — that is the trade for not having a passphrase you could lose.

### You cannot get locked out of your data

Losing the keyring makes the data volume permanently unreadable — `pg_dump` cannot rescue
it either. That risk is real, so the bundle is built so it cannot strand you:

- **The dumps in `./backups` need no key at all.** `pg_dump` reads through the running
  server, so its output is plain SQL with no encryption in it. A dump restores into *any*
  Postgres — including a stock `postgres:18-alpine` with no `pg_tde` present. It logs a
  block of errors on the way through (roughly 40 lines: `extension "pg_tde" is not
  available`, then one `function public.pg_tde_… does not exist` per key-provider function
  the dump tries to re-grant), and then restores every row. Those errors are noisy but inert
  — they only concern objects belonging to the extension itself. Tested against
  `postgres:18-alpine` with no `pg_tde` available: 4 errors, all 86 tables and every row
  arrive, as plain `heap`. Under the older pg_tde 1.0 this was two lines rather than forty;
  the count grew with the extension, not with any loss of data.

  **That applies to an empty target only.** Restoring into a database that still has the
  schema — which is the case whenever you are rolling back rather than rebuilding — skips
  every `CREATE` and then appends every `COPY`, so tables without a primary key end up
  holding each row twice while psql still exits 0. Use `./chronicle restore`, which stops
  application writers and then drops the schema first; see
  [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md).
- **Startup refuses `ENABLE_ENCRYPTION=true` without `overlays/backups.yml`**, because that
  combination would create encrypted data with no key-free copy of it. `config-guard` fails
  and nothing else starts.
- **A copy of the keyring is placed in `./backups/keyring`** so the backup set is
  self-contained and the volume itself can be remounted, not just rebuilt from SQL. That is
  safe precisely because the dumps beside it are already plain SQL — the copy adds no
  exposure they do not already carry. What stays apart is the key and the *encrypted
  volume*, and it does.
- **`./chronicle verify` checks all three**: every table encrypted, a keyring copy present,
  and a key-free dump present.
- **Online key rotation is guarded.** `./chronicle rotate-secret tde` takes a verified
  pre-rotation SQL dump, activates a new principal key, proves the table/key state, refreshes
  the keyring copy atomically, and leaves restart-safe recovery metadata until completion.

**So: back up `./backups` as a single unit and keep it somewhere the data volume isn't.**
That directory is `0700` and owned by the account that deployed the stack, so other local
users cannot read the dumps.

Two consequences worth knowing:

- Every table is encrypted from creation, not converted afterwards. `db-init` runs before
  the backend and sets the database default access method to `tde_heap`, so the tables
  Flyway creates on that first boot — and on every later migration — are born encrypted. It
  also re-sweeps on each start, which now finds nothing to do.
- Query parallelism is disabled cluster-wide (`max_parallel_workers_per_gather=0`). A
  parallel scan over an encrypted table segfaults Postgres and restarts the cluster; this
  removes the footgun. If you set `ENABLE_ENCRYPTION=false`, you can raise it again.

If you would rather not use database-level encryption, set `ENABLE_ENCRYPTION=false` and
use **full-disk/volume encryption at the OS level** (LUKS, or your cloud provider's disk
encryption) — transparent to Chronicle, with the key managed by your platform.

## Chile — Ley 21.719

If you process data about people in Chile, read
[docs/CHILE-LEY-21719.md](docs/CHILE-LEY-21719.md). Short version: the security standard is
**risk-based**, not a hard encryption mandate, so this trimmed stack can meet it — but
health/behavioral data is *sensitive*, which triggers **explicit consent** and a
**Data Protection Impact Assessment (EIPD)** you must complete before collecting. Confirm
specifics with your institution's data-protection officer; this document is not legal advice.

## FAQ

**Is 8 CPU / 16 GB required?** No — that figure is for the larger hardened reference stack. This
trimmed stack fits in ~5 GB; see [Sizing](#sizing).

**Which database?** PostgreSQL 18, the Percona distribution image — that is where `pg_tde`
comes from, so it is what makes encryption at rest work with no extra install. A stock
`postgres:18` image also works if you set `ENABLE_ENCRYPTION=false`.

**I already run an older release — am I on 18?** Not automatically. Your own
`.env` sets `POSTGRES_IMAGE`, and that line wins over the compose default, so an instance
created before this change stays on 17 silently. Postgres **major** version jumps also need a
dump/restore — the data directory is not forward-compatible, and there is an ordering trap
around `pg_tde` that will fail the restore if you get it backwards. Follow
[`docs/POSTGRES-18-UPGRADE.md`](docs/POSTGRES-18-UPGRADE.md). A brand-new install
needs none of it.

**Can participants use the Time Use Diary in Spanish?** Yes, and in German, Swedish and
Hebrew. The diary is fully translated — every string the diary asks for exists in each of
those languages, and participants get a language picker on the form itself. You can also fix
the language per study (the study's `language` setting) or per link by appending `&lang=es`
to a diary link. Hebrew additionally takes `&gender=male|female`, because the questions are
gendered in Hebrew.

What is **not** translated is the researcher dashboard: study configuration, the participant
table, exports and the survey/questionnaire chrome are English-only. Questionnaire and study
text you write yourself is whatever language you type it in, so participant-facing content is
not limited to English even where the surrounding buttons are.

**How do Chronicle developers check the browser flow end to end?** `./chronicle verify` probes the
exposure boundary, but it does not open a browser. For that there is a browser test that
drives a real deployment the way a person uses it — through the dashboard password prompt,
sign-in, creating a study, enrolling a participant, issuing that participant's one-time diary
link, and opening the diary as the participant in Spanish — and separately confirms the public
listener still hides the researcher API:

This optional developer test runs from a separate Chronicle source checkout; it is not an
installation dependency of this release bundle:

```bash
cd /path/to/chronicle-source/chronicle-web
CHRONICLE_PROXY_BASE_URL=https://127.0.0.1:8081 \
CHRONICLE_E2E_BASIC_AUTH_USER=researcher \
CHRONICLE_E2E_BASIC_AUTH_PASSWORD='the dashboard password you chose during setup' \
CHRONICLE_E2E_PUBLIC_BASE_URL=http://127.0.0.1:8080 \
  bun run e2e:selfhost
```

It fails on any uncaught JavaScript error too, so a green run is a statement about the
browser console and not only about what rendered. It needs `TESTING_LOGIN_ENABLED=true`
(the built-in dashboard login). It does not exercise the source-only experimental SSO
scaffold, which is absent from release bundles. It creates one study and one participant per
run and does not delete them.

**Do we have to coordinate upgrades with the app publisher?** No. Download a Chronicle release bundle
when you want an upgrade. Your running instance and data remain independent.

**Any non-open-source dependencies?** None on the **server** side — PostgreSQL, the JVM
backend, Caddy, VictoriaMetrics, Grafana, and the backup image are open source, and nothing
in the supported bundle needs a licence key. Keycloak is not part of the supported bundle.

One caveat on the **Android app**: two modules — `activity_recognition` and `sleep` — are
built on Google Play Services (`play-services-location`), which is proprietary and needs
Google Play on the handset. They are included in the `open` flavor but simply no-op on a
device without Play Services (e.g. Fire OS, de-Googled ROMs); every other module,
including all hardware sensors and usage events, is unaffected. Leave those two modules
disabled in your study config and the app has no proprietary runtime dependency.

### Sizing

Two different numbers matter here, and confusing them is how boxes get under-provisioned.

**Measured at idle** (one study, no devices enrolled): backend ~0.9 GB, Postgres ~0.1 GB,
Caddy ~40 MB, backup sidecar ~30 MB → **~1.1 GB actually resident**.

**Configured ceilings** are much higher, and they sum to more than a 4 GB box has:

| Setting | Default |
|---|---|
| `BACKEND_MEM_LIMIT` | 3 GB |
| `POSTGRES_MEM_LIMIT` | 2 GB |
| `FRONTEND_MEM_LIMIT` | 512 MB |
| `BACKUP_MEM_LIMIT` | 512 MB |
| `WEB_MEM_LIMIT` | 256 MB |
| **total** | **6.25 GB** |

Limits are ceilings, not reservations, so the stack starts fine on a smaller box — but
nothing stops it growing into them under load, and then the kernel OOM-kills a container.
On a 4 GB host, lower `BACKEND_MEM_LIMIT`/`BACKEND_XMX` and `POSTGRES_MEM_LIMIT` to fit.

| Scenario | Suggested |
|---|---|
| Pilot, a few devices | 2 vCPU / 4 GB, with the limits above reduced to fit |
| Comfortable, small study | 4 vCPU / 8 GB (stock limits fit) |
| Sensor-heavy (high-rate accelerometer) or many devices | scale **disk** first, then RAM |

CPU load is driven by ingest rate. **Disk** is the variable to plan around, and it is
dominated almost entirely by whether hardware sensors are on.

**If you give the box more RAM, raise the database settings with it.** Every container is
capped (`POSTGRES_MEM_LIMIT`, `BACKEND_MEM_LIMIT`, `WEB_MEM_LIMIT`, `BACKUP_MEM_LIMIT`),
and Postgres is tuned to the 2 GB default — `POSTGRES_SHARED_BUFFERS=512MB` at ~25% and
`POSTGRES_EFFECTIVE_CACHE_SIZE=1536MB` at ~75%. Raising only `POSTGRES_MEM_LIMIT` leaves
the extra memory unused, because Postgres' own defaults are far smaller than either value.
Keep `shared_buffers + (max_connections × work_mem) + maintenance_work_mem` under the
limit, or the kernel OOM-kills the database rather than Postgres returning an error. The
JVM heap is separate: `BACKEND_XMX` must stay below `BACKEND_MEM_LIMIT`.

Two defaults assume SSD/NVMe — `POSTGRES_RANDOM_PAGE_COST=1.1` and
`POSTGRES_EFFECTIVE_IO_CONCURRENCY=200`. On spinning disks set them to `4` and `2`, or the
planner will pick index scans that cost more than a sequential read.

Query parallelism is off (`max_parallel_workers_per_gather=0`) because a parallel scan over
an encrypted table crashes Postgres. Leave it off unless `ENABLE_ENCRYPTION=false`.

Container logs are capped at `LOG_MAX_SIZE=10m` × `LOG_MAX_FILES=5` per service. Docker
does not rotate logs by default, so removing these lets a chatty service fill the disk.

Measured on an internal dogfood deployment (Android phones + tablets, on-disk including
indexes):

| Module set | Per device per day |
|---|---|
| Usage events only (no hardware sensors) | **< 1 MB** — ~200 rows/device/day |
| Hardware sensors at default rate | **~23 MB** — ~63,000 rows/device/day |
| Hardware sensors, heaviest observed day | **~220 MB** — ~570,000 rows/device/day |

So: 10 devices on usage-only is a rounding error, while 10 devices on continuous
accelerometer is roughly **7 GB/month**. Sensor sampling rate and duty cycle are per-study
settings in the dashboard, so this is a dial you control, not a fixed cost. Provision
storage from your module choices and device count, and enable the backups overlay.

### Scale in this order

1. Add disk when the Database and Storage dashboard shows capacity or predicted-growth
   pressure.
2. Add RAM for sustained PostgreSQL/backend memory or connection pressure; add CPU for
   measured ingestion saturation after ruling out disk I/O.
3. Tune the documented container, PostgreSQL and JVM values together and compare the same
   dashboard window before and after.
4. The tested single-node ceiling is one backend container, one PostgreSQL container, and
   one instance of each selected sidecar on one Docker host. Device/study throughput is
   workload-dependent, so the capacity and growth alerts—not an invented participant
   count—are the supported cutover signal. There is no multi-node/HA or replica mode;
   `docker compose up --scale` is not a database or backend HA design. Move to a separately
   designed deployment when one host is no longer sufficient.
