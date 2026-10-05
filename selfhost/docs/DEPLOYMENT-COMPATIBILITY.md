# Supported deployment combinations

A combination is supported only when it appears below.

## Components and status

| Component or family | Status in the self-host release | Meaning |
|---|---|---|
| Base PostgreSQL, backend, prebuilt dashboard, and Caddy | **Supported** | Digest-pinned, source-free base stack. |
| `mode-behind-proxy-internal.yml` | **Supported production mode** | An upstream proxy terminates TLS; mobile traffic is public and researcher routes use a private HTTPS listener. |
| `mode-own-tls-internal.yml` | **Supported production mode** | Caddy uses the supplied certificate; mobile traffic is public and researcher routes use a private HTTPS listener. |
| `mode-local-https.yml` | **Supported trial mode** | Caddy's private CA is for operator-owned test devices on one LAN, never study participants. |
| `backups.yml` | **Supported** | Required in both production modes and whenever TDE encryption is enabled. Optional only for an unencrypted local trial. |
| `monitoring.yml` | **Supported optional overlay** | cAdvisor, VictoriaMetrics, VictoriaLogs, Fluent Bit, operational probes, and private Grafana. It is not required by the base stack and is tested with every row below. |

The supported release has no public researcher dashboard. Its built-in login mints a single
admin session without an MFA claim, so it is accepted only with an internal mode,
`TESTING_LOGIN_ENABLED=true`, and `REQUIRE_MFA=false`. If no login method is configured,
startup fails instead of producing an apparently healthy but unusable dashboard.

## Researcher API keys on the public listener

The public listener forwards only the study-scoped read-only download routes accepted by
the backend researcher API-key table: Time Use Diary `/data` and `/participants/data`, and
survey questionnaire `/data`. These requests must use `X-Api-Key`; public bearer tokens and
browser cookies do not pass this boundary. The Caddy route is only an exposure filter: the
backend still validates the key, its READ_ONLY scope, the study, and the creator's current
access. Treat an API key as a bearer credential, keep it out of URLs and logs, and grant it
only the studies and lifetime its integration needs. The researcher dashboard and its other
API routes remain on the internal listener.

## Declared profiles

Each profile works with or without `overlays/monitoring.yml`.

| Profile ID | Mode overlay | `ENABLE_ENCRYPTION` | Backups overlay | Intended use |
|---|---|---:|---:|---|
| `proxy-encrypted` | `mode-behind-proxy-internal.yml` | `true` | required | Recommended production configuration. |
| `proxy-plain` | `mode-behind-proxy-internal.yml` | `false` | required | Production only when the host/storage layer supplies approved encryption at rest. |
| `tls-encrypted` | `mode-own-tls-internal.yml` | `true` | required | Production with an operator-supplied certificate and TDE. |
| `tls-plain` | `mode-own-tls-internal.yml` | `false` | required | Production with an operator-supplied certificate and approved host/storage encryption. |
| `trial-encrypted` | `mode-local-https.yml` | `true` | required | LAN trial that exercises the production TDE and recovery path. |
| `trial-plain-backed-up` | `mode-local-https.yml` | `false` | present | LAN trial without TDE, retaining scheduled logical dumps. |
| `trial-plain-no-backup` | `mode-local-https.yml` | `false` | absent | Disposable LAN evaluation only; Docker volumes still persist, but there is no recovery copy. |

`ENABLE_ENCRYPTION=false` disables database-level TDE; it does not prove that the host disk
is encrypted.

## Container network and client IPs

The base Compose file creates a dedicated bridge on `CHRONICLE_SUBNET` (default
`172.28.0.0/16`) and passes that same CIDR to the backend's trusted-proxy resolver. The
startup guard accepts one canonical private IPv4 subnet and rejects a mismatch, so the
backend will not silently treat Caddy as untrusted after Docker chooses another address
pool. If this range overlaps a host, VPN, or existing Docker network, set `CHRONICLE_SUBNET`
in `.env` to an unused RFC1918 subnet such as `192.168.240.0/24`; the compose network and
backend `CHRONICLE_TRUSTED_PROXY_CIDRS` value use the same input and are checked for exact
consistency at startup.

Caddy separately trusts upstream load balancers through `CADDY_TRUSTED_PROXIES`, a
space-separated list of explicit CIDRs. It defaults to loopback only; set it to the exact
source ranges used by your TLS-terminating proxy. All split modes process the forwarded chain
from right to left, so a forged leading X-Forwarded-For value does not replace the nearest
untrusted client address. Direct clients continue to use their socket address, regardless of
an X-Forwarded-For header they send themselves.

## Rejected combinations

The startup guard rejects these before any dependent service starts:

- no mode overlay, more than one mode overlay, or an unknown mode/exposure pair;
- either production mode without `overlays/backups.yml`;
- any encrypted mode without `overlays/backups.yml`;
- a public dashboard without a separately reviewed authentication overlay;
- the built-in login on a public dashboard;
- no dashboard login method at all;
- the built-in login with `REQUIRE_MFA=true`, or a public dashboard with MFA disabled;
- placeholder, missing, or undersized credentials;
- non-boolean values for the boolean controls;
- monitoring with a default/short Grafana password or wildcard Grafana bind;
- own-TLS mode without nonempty `tls/cert.pem` and `tls/key.pem`.

## Select a profile

The default encrypted/proxied profile is already in `.env.example`:

```ini
ENABLE_ENCRYPTION=true
COMPOSE_FILE=docker-compose.yml:overlays/mode-behind-proxy-internal.yml:overlays/backups.yml
```

Append monitoring without changing anything else:

```ini
COMPOSE_FILE=docker-compose.yml:overlays/mode-behind-proxy-internal.yml:overlays/backups.yml:overlays/monitoring.yml
```

For a production mode, do not remove `overlays/backups.yml`. For a disposable unencrypted
trial, use exactly:

```ini
ENABLE_ENCRYPTION=false
COMPOSE_FILE=docker-compose.yml:overlays/mode-local-https.yml
```

After editing `.env`, run `./chronicle check`; after startup, run
`./chronicle verify --dashboard-password` and supply the password on the prompt or stdin.

## Export limits

The backend receives all five export limits from Compose. These defaults apply when a value is
unset or empty; set any of them in `.env` to tune exports for the host:

| Variable | Default | Meaning |
|---|---:|---|
| `CHRONICLE_EXPORT_MAX_ROWS` | `1000000` | Maximum rows in one export |
| `CHRONICLE_EXPORT_MAX_BYTES` | `536870912` | Maximum bytes in one export |
| `CHRONICLE_EXPORT_MAX_RUNTIME_SECONDS` | `1800` | Maximum runtime for one export |
| `CHRONICLE_EXPORT_MAX_TOTAL_BYTES` | `8589934592` | Maximum managed export artifacts |
| `CHRONICLE_EXPORT_MIN_FREE_BYTES` | `1073741824` | Free space required before a new export |

Use positive decimal integers. The backend validates every supplied value and fails backend
startup when a value is malformed, zero, negative, or outside the supported integer range.

## Researcher session idle timeout

The backend expires researcher sessions after a bounded idle interval. Set
`CHRONICLE_SESSION_IDLE_MINUTES` in `.env` to a decimal integer from `1` through `120`;
the public example and Compose default are `15` minutes. The startup guard rejects a
malformed or out-of-range value before dependent services start.

Public TLS modes accept publicly delegated DNS names and globally routable IP addresses.
The setup wizard and `guard-config.sh` both reject reserved or private-use suffixes including
`.corp`, `.home`, `.mail`, `.internal`, `.home.arpa`, `.lan`, and `.local`. The `local-https`
trial remains available for a private LAN address; it does not require a public DNS suffix.

## Server and app versions

The dashboard is the frontend image of the same release; it is never mixed across releases.

| Server release | Android build shipped with it | Server change the app depends on |
|---|---|---|
| 2026.10.5 | versionCode 68 (Play internal, open flavor) | V114/V115 keep erased device-key hashes so an offline phone can learn NOT_ENROLLED after participant or study erasure; V116/V117 preserve those markers through restore |
| 2026.10.3 | versionCode 67 (Play internal) | as 2026.10.2 |
| 2026.10.2 | versionCode 67 (Play internal) | V113 accepts the access-missing diagnostic; an older server rejects it and the app keeps it until the server is upgraded |
| 2026.10.1 | versionCode 66 (Play internal); needs Android 8.0 or newer | none |
| 2026.9.30 | versionCode 65 (not uploaded to Play; replaced by 66) | none |
| 2026.9.29 | versionCode 64 (Play internal) | none (V108/V109 are server-side: erased diagnostics and purged data cannot be re-inserted by a device replay; new tables are encrypted automatically because self-host makes `tde_heap` the database default) |
| 2026.9.28 | versionCode 63 (Play internal) | V107 accepts the full diagnostic catalog and keeps diagnostics for the life of the study |
| 2026.9.27 | versionCode 62 (Play internal) | V106 accepts the discarded-data diagnostic codes |
| 2026.9.25 | versionCode 61 (Play internal) | V104 accepts sensor dead-letter, crash and ANR diagnostic codes |
| 2026.9.17, 2026.9.18, 2026.9.22 | versionCode 60 (Play internal); 61 carries the 2026.9.18 exact-alarm fix | none |
| 2026.9.14 | versionCode 59 (not published) | V103 settings `ETag`/`If-Match` (optional on the server) |

Newer apps work against older servers: a server before V107 answers the newer diagnostic
codes with 400, and the app parks those counts on the phone and offers them again on every
upload, so an upgraded server receives them
(`LocalUploadDiagnosticsStore.parkUnsupportedByLegacyServer`). Servers before V107 also delete
diagnostics after 30 days; the phone keeps its copy and re-sends it once a day. Update the
server first anyway.
