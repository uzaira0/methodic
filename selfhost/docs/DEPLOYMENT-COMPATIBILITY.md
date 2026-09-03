# Supported deployment combinations

This file is the release compatibility contract. A combination is supported only when it
appears below. `tests/security/selfhost-combination-matrix.sh` renders every row twice—once
without monitoring and once with monitoring—and executes the same `guard-config.sh` used by
`docker compose up -d`.

## Components and status

| Component or family | Status in the self-host release | Meaning |
|---|---|---|
| Base PostgreSQL, backend, prebuilt dashboard, and Caddy | **Supported** | Digest-pinned, source-free base stack. |
| `mode-behind-proxy-internal.yml` | **Supported production mode** | An upstream proxy terminates TLS; mobile traffic is public and researcher routes use a private HTTPS listener. |
| `mode-own-tls-internal.yml` | **Supported production mode** | Caddy uses the supplied certificate; mobile traffic is public and researcher routes use a private HTTPS listener. |
| `mode-local-https.yml` | **Supported trial mode** | Caddy's private CA is for operator-owned test devices on one LAN, never study participants. |
| `backups.yml` | **Supported** | Required in both production modes and whenever TDE encryption is enabled. Optional only for an unencrypted local trial. |
| `monitoring.yml` | **Supported optional overlay** | cAdvisor, VictoriaMetrics, VictoriaLogs, Fluent Bit, operational probes, and private Grafana. It is not required by the base stack and is tested with every row below. |
| Public-dashboard modes and Keycloak | **Experimental, source-only** | Kept together under `experimental/public-dashboard/`; excluded from release archives because authentication-enabled frontend, bootstrap, MFA, upgrade, and end-to-end tests are incomplete. |
| Kafka, Loki, OpenSearch, Temporal, Vault, SIEM containers, legacy `docker/` Compose, and Kubernetes packages | **Not self-host release options** | They are absent from this bundle. Some remain tenant-specific or historical source-workspace infrastructure; adding their files to `COMPOSE_FILE` is unsupported. |

The supported release has no public researcher dashboard. Its built-in login mints a single
admin session without an MFA claim, so it is accepted only with an internal mode,
`TESTING_LOGIN_ENABLED=true`, and `REQUIRE_MFA=false`. If no login method is configured,
startup fails instead of producing an apparently healthy but unusable dashboard.

## Declared profiles

Each profile below is tested with `overlays/monitoring.yml` absent and present. That makes
**14 concrete supported combinations**. The monitoring overlay never changes the mode,
database, authentication, or backup requirements.

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
is encrypted. Production operators remain responsible for an approved storage-encryption
control. `trial-plain-no-backup` is not a production shortcut.

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

## Promotion rule

An experimental or absent component becomes supported only after it is dependency-pinned,
included in the release builder, documented here, rendered by the matrix test, exercised in
the source-free smoke test when runtime behavior matters, and covered by upgrade/restore
behavior. Moving a Compose file into `overlays/` without those changes is not promotion.
