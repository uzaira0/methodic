# Finding: Row-Level Security is dormant in the running deployment

**Date:** 2026-06-02
**Severity:** High (defense-in-depth control documented as active is not enforcing)
**Scope:** The running `chronicle-backend` + `chronicle-postgres` stack on host `10.23.4.137` (the F5-fronted deployment). No production changes were made while investigating this; this is a write-up only.

## Summary

Chronicle's architecture documents **Row-Level Security (RLS)** as a defense-in-depth
control: *"Study isolation enforced at DB level"* (CLAUDE.md), with *"Two app roles:
`chronicle_app` (NOSUPERUSER, RLS-enforced) and `chronicle_admin` (BYPASSRLS)."*

In the running deployment **RLS enforces nothing**, for two compounding reasons:

1. **The RLS-enforced role was never created.** The database has only two non-system
   roles — `chronicle` (`rolsuper=t`, `rolbypassrls=t`) and `keycloak`. The intended
   `chronicle_app` / `chronicle_admin` roles **do not exist**.
2. **The application connects as the bootstrap superuser.** `docker/.env` sets
   `POSTGRES_USER=chronicle`, and the backend's platform datasource uses it. A
   superuser bypasses RLS unconditionally, so every policy — `V1` study isolation,
   `V14` candidates, the newly wired `V24` battery telemetry — is inert for all app
   traffic (reads and writes alike).

The per-table policies and the request-scoped context-setter
(`RLSAwareHikariDataSource`, which sets `app.authorized_studies` / `app.is_admin`)
are therefore present but unreachable: `chronicle_has_study_access()` is never
consulted because the connecting role is never subject to RLS.

## Evidence

```
-- Roles actually present (only chronicle + keycloak; no chronicle_app/chronicle_admin):
SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname NOT LIKE 'pg_%';
  chronicle  super=t  bypassrls=t
  keycloak   super=f  bypassrls=f

-- The app's configured DB user:
docker/.env:  POSTGRES_USER=chronicle

-- Tables carry the policies, but the writer bypasses them:
chronicle_usage_events   rls=on  force=on   (policy present, never evaluated)
upload_buffer            rls=on  force=on
battery_telemetry        rls=on  force=on   (after V24 was wired — this change)
android_sensor_data      rls=off            (never had an RLS upgrade either)
```

The intended design is spelled out in `docker/init-db-roles.sql` (creates
`chronicle_app` NOSUPERUSER RLS-enforced + `chronicle_admin` BYPASSRLS, and states
*"Configure your application to use `chronicle_app` for normal operations"*) and
`docker/migrations/C7-create-app-user.sql`. **Neither was applied to this database**,
and the application config was never repointed off the superuser.

## Impact

- The DB-level study-isolation backstop is **absent**. If application-layer
  authorization (`AuthorizationManager` + controller enrollment checks) is bypassed —
  e.g. a SQL-injection or an authz logic flaw — there is **no database-level
  containment**. Cross-study data access would not be stopped by RLS.
- This contradicts the security posture asserted in `CLAUDE.md` and `docs/security/`,
  which matters for HIPAA representations ("study isolation enforced at the database
  level").
- It is not a battery-specific issue. Battery telemetry merely surfaced it; the gap is
  deployment-wide and predates the battery feature.

## Why remediation is not a one-line role swap

Naively setting `POSTGRES_USER=chronicle_app` (after creating the role) would **break
all mobile uploads**, not just enable isolation:

- The mobile-upload write paths (`BatteryTelemetryUploadService`,
  `AppDataUploadService`, `AndroidSensorDataUploadService`, …) obtain
  `storageResolver.getPlatformStorage().connection` and `INSERT` **without setting any
  RLS session context**. They rely on the writer being a bypass role.
- `RLSAwareHikariDataSource` only sets `app.authorized_studies` / `app.is_admin` when
  there is a request-scoped principal (`RLSRequestContext.current()`); mobile uploads
  (API-key / HMAC) are not request-scoped, so the connection is returned with **no
  context**.
- Under an RLS-enforced role, `chronicle_has_study_access()` returns **false** with no
  context, and a `FORCE ROW LEVEL SECURITY` + `WITH CHECK (...)` policy would **reject
  the INSERT**. Every mobile-upload table (usage, sensor, battery) would start
  rejecting writes.

So a correct migration to `chronicle_app` requires the mobile write paths to first
establish an RLS context (e.g. set `app.is_admin=true` for the trusted server-side
upload connection, or set `app.authorized_studies` to the enrolled study after the
existing enrollment check). This is a backend change spanning all upload services, not
a config flip.

## Suggested remediation (not applied)

1. **Provision the roles.** Run `docker/init-db-roles.sql` against the database; set
   role passwords from secrets (Vault is already in the stack — see
   `docker/vault/`).
2. **Establish RLS context in the trusted write paths.** In the upload services (or a
   shared `getPlatformStorage()` wrapper used by the mobile path), `set_config` an
   appropriate `app.*` context per request so RLS-enforced inserts satisfy the policy.
   Decide policy intent: server-side ingest as `app.is_admin=true` (simplest, keeps
   the controller enrollment check as the gate) vs. per-study `app.authorized_studies`
   (tighter, requires threading the study through).
3. **Repoint the app** to `chronicle_app` for normal operations and `chronicle_admin`
   (or the superuser) for the DDL/upgrade path (the `PreHazelcastUpgradeService`
   migrations issue `ALTER TABLE … ENABLE ROW LEVEL SECURITY`, `CREATE TABLE`, etc.,
   which `chronicle_app` is not privileged for).
4. **Retrofit RLS on `android_sensor_data`** (no upgrade wires it today) so the sensor
   table matches the others once enforcement is live.
5. **Verify with a non-bypass role:** repeat the read/write checks connected as
   `chronicle_app` (not the container superuser) and confirm cross-study isolation
   actually holds and uploads still succeed.

## Relationship to the battery V24 change

The battery `V24` RLS migration was wired in this same session (it was previously
orphaned — no runner class). That brings `battery_telemetry` to **parity** with
`chronicle_usage_events` / `upload_buffer`: it now carries the policy but, like them,
the policy is dormant under the superuser. Wiring V24 does **not** make battery worse
or better than its siblings under the current role; it makes it consistent, and it
means battery is already correct for the day the deployment-wide remediation above
lands.
