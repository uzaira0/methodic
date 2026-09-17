# Changelog

Release headings use the bundle version: `YYYY.M.D` with no leading zeros (`2026.9.14`),
matching the `chronicle-selfhost-<version>` bundle, its image tags, and `./chronicle update`.
One bundle per calendar day: a same-day suffix such as `-2` is a semver prerelease and
would sort below the day's release, so `./chronicle update` would refuse it.

## [Unreleased]

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
