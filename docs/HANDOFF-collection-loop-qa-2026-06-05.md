# Handoff — Collection-Loop-Closure On-Device QA (2026-06-05)

**2026-06-06 supersession note:** the code changes described below have since
been committed. Android app changes were pushed to `uzaira0/chronicle@edde015`;
server changes were pushed to the `device-enrollment-server-events` branch and
opened as `uzaira0/chronicle-server#7`. Treat older "uncommitted" wording in this
handoff as historical session state.

**Status:** paused for tablet access. All non-device work is done and test-green; the
remaining steps are blocked on physical USB to the SM-T510. Tracking issue:
**[uzaira0/methodic#50](https://github.com/uzaira0/methodic/issues/50)**.

This document is self-contained — you can resume from it cold.

---

## 1. TL;DR

On-device QA of the collection-loop-closure feature (Android collector gates each module on
`serverEnabled && acknowledged`, reports to an append-only server trail) surfaced **three
findings** and produced **three durable, test-green code fixes** (all uncommitted on submodule
`develop` working trees). One device-side cleanup step is deferred until the test tablet can be
reached over USB.

| # | Finding | Status |
|---|---------|--------|
| **F-1** | `usage_events` ack-gate bypassed on the **coordinated** sync path (the strategy the device runs) | **FIXED + proven on-device** (uncommitted) |
| **Immutability** | Backend runs as a Postgres **superuser** → REVOKE-based audit immutability + RLS are cosmetic against the app's own principal | **V27 trigger fix written + tested** (one table); systemic fix is a deployment decision |
| **F-2** | Web study-ops may collide with mobile request-signing (`MOBILE_SIGNING_REQUIRED=true`) | **SUSPECTED** — needs a 1-step browser repro |

Nothing was deployed. No production code is live with these changes; they apply on the next
normal build/deploy.

---

## 2. The findings in detail

### F-1 — usage_events ack-gate bypass (FIXED)

The loop invariant is "fail-closed until the participant acknowledges." It held for
`battery_telemetry` and `hardware_sensors` but **not** for `usage_events` (and the device-state
rows that ride with it) on the **coordinated** strategy (`coordinated_collect_then_upload`) —
which is the strategy the device actually runs.

- `ChronicleSyncWorker.runUsageCollection()` hardcoded the legacy **ungated**
  `UsageCollectionDelegate`. The ack-gated `UsageModuleCollectionDelegate` (gate at
  `UsageModuleCollectionDelegate.kt:137`, `CollectionGate.collects(context, USAGE_EVENTS)`) was
  only used by the split-periodic `UsageMonitoringWorker`. The module-pipeline migration gated the
  periodic path and missed the coordinated one.
- **Empirical proof of the bug:** with `usage_events` + `battery_telemetry` both
  PENDING-never-acknowledged, usage collected + uploaded (`upload_buffer` grew) while battery
  stayed at 0 rows — same ack state, opposite behavior.
- **False assurance:** both the `ACK_GATED_MODULES` call-site test and `UsageWorkerMigrationTest`
  pass, because neither exercises the coordinated path.

**Fix:** both workers now route through one `collectUsage(context)` selector — a single
delegate-construction site — so the gate is enforced identically on every strategy.

**Proven on-device (before the fix's value could regress):** with `usage_events` driven to
PENDING via the absolute-ack disable→re-enable cycle, a coordinated `ChronicleSyncWorker` run
logged `usage_events not server-enabled/acknowledged yet; skipping collection` and collected
**zero** usage rows (DB 115→115) — the exact inverse of the bug.

> **Caveat (carry forward):** the new `UsageCollectionRoutingTest` is **weak** — it only
> re-asserts the flag→path mapping; it will **not** catch someone re-introducing a direct
> `UsageCollectionDelegate(...)` in `ChronicleSyncWorker`. The real guard is the **structural
> refactor** (the single construction site), not the test. `device_lifecycle` still has no
> independent gate (it rides the `usage_events` gate via the shared queue write — an independent
> gate is Phase 5, by design).

### Immutability — append-only trail not enforced against the runtime role

**Not a data breach.** Study isolation still holds at the app layer (`AuthorizationManager` +
controllers' `ensureReadAccess`). This is **defense-in-depth nullified**, not exposure.

The backend connects to Postgres as role **`chronicle`, which is `rolsuper = true` (SUPERUSER,
BYPASSRLS)** — verified via `pg_roles` + live JDBC conns in `pg_stat_activity`. The documented
least-privilege roles **`chronicle_app` / `chronicle_admin` do not exist** in the prod DB (only
`chronicle` + `keycloak` can log in). Consequences:

- The append-only immutability on `participant_collection_acknowledgment` (V26),
  `study_settings_audit` (V25), `audit_logs` (V15) is enforced **only** by `REVOKE UPDATE/DELETE`.
  A superuser bypasses privilege checks, so the REVOKE is cosmetic against the principal the app
  runs as (and `TRUNCATE` is still granted). RLS is bypassed across ~31 tables.
- The V26 migration comment conflates `BYPASSRLS` with `SUPERUSER` (REVOKE binds the former, not
  the latter).
- **Same false-assurance mechanism as F-1:**
  `MigrationRoundtripTest.testParticipantCollectionAcknowledgmentImmutabilityUpgrade` does
  `CREATE ROLE chronicle` as a **non-superuser**, then asserts REVOKE works — green while prod is
  unprotected.
- **`HANDOFF.md` Issue 1 (RLS Context Bypass) is moot** while the runtime role is a superuser —
  fixing RLS-context propagation changes nothing if the role bypasses RLS regardless of context.

**Fix written (one table): `V27` trigger immutability** for
`participant_collection_acknowledgment`. A `BEFORE UPDATE/DELETE/TRUNCATE` trigger
(`pca_enforce_append_only`) fires for **every** role including superusers; an authorized retention
purge opts in per-transaction via `SET LOCAL chronicle.allow_acknowledgment_purge = 'on'`. New
roundtrip tests prove it blocks a **superuser** (Testcontainers connects as one, mirroring prod)
while INSERT/SELECT + the escape hatch still work.

> Implementation note: `SqlMigrationUpgrade.splitSqlStatements` only handles anonymous `$$`
> dollar-quoting, **not** `$tag$` — the trigger function body must use `$$`.

**NOT applied to live prod.** It applies on the next backend deploy. Never hand-apply DDL to the
prod HIPAA DB, and don't restart the backend.

**Systemic remediation (deployment decision — NOT done):** provision a non-superuser
least-privilege `chronicle_app` runtime role + repoint the datasource → restores RLS + makes the
REVOKE-based immutability real across `audit_logs` / `study_settings_audit` too. Extend the same
trigger hardening to those two tables.

### F-2 — web study-ops vs mobile request-signing (SUSPECTED)

`MOBILE_SIGNING_REQUIRED=true` in prod. `MobileApiSignatureFilter` runs on the single Spring
security chain **pre-auth**, self-scoping by URI prefix (`/chronicle/v3/study/`,
`/chronicle/v4/study/`) with **no auth-type exemption**. The web client
(`chronicle-web/.../study-operations-api.ts`) uses `baseUrl:'/chronicle/v3'` + `fetchWithCsrf`
(cookie + `X-CSRF-Token`, **no HMAC anywhere in the bundle**); `updateStudySettings` →
`/chronicle/v3/study/{id}/settings/type/{type}`.

Direct evidence: an unsigned PATCH to `/chronicle/v3/study/{id}/settings/type/DataCollection`
(even **with** a Bearer JWT) returns **401 "Missing required signature headers"** from the
backend (backend JSON, not Traefik). By consequence, the browser's session+CSRF study-ops calls
would 401 in prod — **unless** an exemption exists that wasn't found.

**Open contradiction (why SUSPECTED):** memory `chronicle-per-module-collection-config` says the
FE settings PATCH was observed working — likely a dev/e2e backend with signing off.

**1-step repro to confirm/refute:** log into the prod dashboard, open any study, observe whether
`GET /chronicle/v3/study/{id}` returns **200** (exemption exists → F-2 false) or **401** (F-2 real
and severe — the web study surface is broken under prod signing).

---

## 3. Uncommitted code changes (resume point)

All on branch **`develop`** in each submodule, **uncommitted**. Commit only when the user asks.

### `chronicle` (Android collector)
```
 M app/src/main/java/com/openlattice/chronicle/collection/state/CollectionLoopCoordinator.kt
 M app/src/main/java/com/openlattice/chronicle/services/sync/ChronicleSyncWorker.kt
 M app/src/main/java/com/openlattice/chronicle/services/usage/UsageMonitoringWorker.kt
?? app/src/test/java/com/openlattice/chronicle/collection/state/CollectionDispositionPlanTest.kt
?? app/src/test/java/com/openlattice/chronicle/services/usage/UsageCollectionRoutingTest.kt
```
- **UsageMonitoringWorker.kt** — added top-level `UsageCollectionPath` enum,
  `selectedUsageCollectionPath()`, and `collectUsage(context)` (the single delegate-construction
  site, respecting `UsageWorkerMigration.USE_MODULE_MANAGER_USAGE_PATH`); `doWork` calls
  `collectUsage(applicationContext)`.
- **ChronicleSyncWorker.kt** — `runUsageCollection()` now calls `collectUsage(applicationContext)`;
  import swapped from `UsageCollectionDelegate` to `collectUsage`; removed unused
  `UsageMonitoringWorker` import.
- **CollectionLoopCoordinator.kt** — refactored `applyDisposition` to use a pure
  `planDisposition()`; appended `DispositionQueue` enum, `DispositionAction` sealed interface,
  `dedicatedQueueFor()`, `planDisposition()`. Log strings preserved exactly.
- **CollectionDispositionPlanTest.kt** (new) — C1–C6 disposition matrix
  (FLUSH / DISCARD-dedicated / DISCARD-shared-not-honorable / HOLD).
- **UsageCollectionRoutingTest.kt** (new) — asserts `selectedUsageCollectionPath() == MODULE_GATED`
  (weak — see F-1 caveat).

### `chronicle-server`
```
 M src/main/kotlin/com/openlattice/chronicle/pods/ChronicleConfigurationPod.kt
 M src/test/kotlin/com/openlattice/chronicle/upgrades/MigrationRoundtripTest.kt
?? src/main/kotlin/com/openlattice/chronicle/upgrades/ParticipantCollectionAcknowledgmentTriggerImmutabilityUpgrade.kt
?? src/main/resources/db/migration/V27__participant_collection_acknowledgment_trigger_immutability.sql
```
- **V27__…sql** (new) — `pca_enforce_append_only()` trigger fn (`$$`-quoted) + BEFORE
  UPDATE/DELETE row trigger + BEFORE TRUNCATE statement trigger + GUC escape hatch
  (`chronicle.allow_acknowledgment_purge`) + INSERT INTO `upgrades`.
- **ParticipantCollectionAcknowledgmentTriggerImmutabilityUpgrade.kt** (new) — extends
  `SqlMigrationUpgrade`, `requiredTableName = "participant_collection_acknowledgment"`.
- **ChronicleConfigurationPod.kt** — added the `@Bean` for the upgrade (wildcard
  `import com.openlattice.chronicle.upgrades.*` already present).
- **MigrationRoundtripTest.kt** — added the trigger-immutability case (proves superuser
  UPDATE/DELETE/TRUNCATE blocked, INSERT/SELECT + GUC escape hatch allowed) + idempotency test +
  `assertOperationBlocked()` helper. Harness uses Testcontainers `postgres:16-alpine` as superuser
  `testuser`.

---

## 4. Build / verify

Backend toolchain is **JDK 21**. Set `JAVA_HOME="$HOME/.local/jdks/temurin-21"` (or the
`~/.local/jdk21` symlink) for any Gradle invocation — the host default is JDK 17, which fails
`chronicle-models` (targets release 21).

```bash
# server — V27 trigger immutability roundtrip
cd /home/opt/chronicle/chronicle-server
JAVA_HOME="$HOME/.local/jdks/temurin-21" ../gradlew :chronicle-server:test --tests "*MigrationRoundtripTest"

# Android — disposition matrix + routing
cd /home/opt/chronicle/chronicle
JAVA_HOME="$HOME/.local/jdks/temurin-21" ./gradlew :app:test --tests "*CollectionDispositionPlanTest" --tests "*UsageCollectionRoutingTest"
```
(All of the above were last run green this session. CI on the GitHub mirror is infra-broken —
verify locally.)

---

## 5. Pending tablet work (BLOCKED on USB)

The test tablet (**SM-T510**, wifi-adb `10.51.178.241:40511`) was stranded off its live study by
an `adb reboot` (wifi-adb via `adb tcpip 40511` is **non-persistent across reboot**; re-enabling
needs physical USB). It is **safe** — on the network, running the F-1-fixed APK, collecting
`device_lifecycle` + `battery` to the **disposable** study, `usage_events` PENDING (harmless).

**The disposable study is being KEPT ALIVE — the purge is DEFERRED.** Deleting it would strand the
device on a dead `studyId`. **Do NOT fabricate a DB ack/enrollment to fake a restore** — that
forges a consent record (exactly what the V27 trigger exists to prevent).

### Recovery sequence (run when USB is connected)
1. USB-connect the tablet → authorize the on-screen RSA prompt.
2. Re-enable wifi-adb:
   ```bash
   adb=~/.local/android-sdk/platform-tools/adb
   $adb tcpip 40511
   $adb connect 10.51.178.241:40511
   ```
3. Re-enroll to **Mini** (grant the usage gate first so it doesn't detour to PermissionActivity):
   ```bash
   PKG=com.openlattice.chronicle.bcmtest.debug
   $adb shell appops set $PKG android:get_usage_stats allow
   $adb shell "am start -a android.intent.action.VIEW -d 'chronicle://enroll?studyId=54a6a4ea-ae90-483f-bbdb-0d9113fe40ca&participantId=tablet-upload-20260519-144146&serverUrl=https://chronicle-screentime-app.research.bcm.edu'"
   ```
   Then tap **ENROLL DEVICE** (`R.id.button`) — `uiautomator dump /sdcard/wd.xml` to locate it.
4. Open the **47001** ack notification → **I AGREE**.
5. Force a sync and confirm collect+upload to Mini:
   ```bash
   $adb shell am broadcast -a com.openlattice.chronicle.debug.SET_SYNC_CONFIG \
     -p $PKG --ez run_now true --ez reschedule false \
     -n $PKG/com.openlattice.chronicle.debug.DebugSyncConfigReceiver
   ```
   Success looks like `UploadExecutor: Starting upload for server 'BCM' (authMode=apiKey)` →
   `SensorUploadWorkerDelegate: [BCM] Uploaded N sensor samples` →
   `CombinedUploadOrchestrator: ... usageFailures=0, sensorFailures=0` →
   `ChronicleSyncWorker: ... result=Success`. Verify server-side: `api_keys.usage_count` climbing
   + fresh `upload_buffer.uploaded_at` for the new `device_id`.

### THEN purge the disposable study
Only **after** Mini is confirmed restored. As the `chronicle` superuser, one transaction,
child→parent FK order. Delete: the disposable study's usage/upload/ack rows → candidate →
`loopqa-tablet-001` participant → the study row.

```bash
docker exec chronicle-postgres bash -lc \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```
Keep PHI reads to identifiers/timestamps only — never select sensor/battery/health values.

---

## 6. Key facts, IDs & seams

| Item | Value |
|------|-------|
| Disposable study (purge target) | **Loop QA 2026-06-05** = `0196d3bb-a256-40ad-82ea-3538363ed671`, participant `loopqa-tablet-001` |
| Live study (restore target) | **Mini** = `54a6a4ea-ae90-483f-bbdb-0d9113fe40ca`, participant `tablet-upload-20260519-144146` |
| Tablet | SM-T510, Android 11 / API 30, wifi-adb `10.51.178.241:40511`, app `com.openlattice.chronicle.bcmtest.debug` |
| adb | `~/.local/android-sdk/platform-tools/adb` (not on PATH) |
| Prod stack | this host; backend `chronicle-backend` :40320 (never restart); Postgres `chronicle-postgres` |
| Debug sync seam | `am broadcast -a …debug.SET_SYNC_CONFIG -n PKG/….DebugSyncConfigReceiver --ez run_now true` |
| Enroll deep-link | `chronicle://enroll?studyId=…&participantId=…&serverUrl=https://chronicle-screentime-app.research.bcm.edu` (single-quote the URL so the shell keeps `&`); ENROLL button id `R.id.button` |
| Settings read path | DB-direct (`studies.settings` jsonb) → device sees a settings change with **no backend restart** |
| Admin JWT (web API) | committed CI token in `.maestro/setup-test-data.sh` (`sub: local-admin`); if it 401s on prod, mint HS256 from `docker/.env` `JWT_SECRET` |

**adb reboot warning:** never `adb reboot` the wifi tablet — `adb tcpip 40511` does not survive a
reboot and re-enabling needs physical USB. There is no FCM/push fallback (FCM unconfigured) and
wireless-debugging mDNS doesn't cross the 10.23↔10.51 subnet split.

---

## 7. Tracking & guardrails

- **Issue:** [uzaira0/methodic#50](https://github.com/uzaira0/methodic/issues/50) — consolidated
  F-1 / immutability / F-2, plus a comment on the deferred purge + stranded device.
- **Memories updated:** `chronicle-usage-gate-bypass-coordinated` (F-1 FIXED),
  `chronicle-prod-superuser-immutability-signing` (new), `chronicle-android-ondevice-testing`
  (reboot lesson + stranded-state recovery).
- **Guardrails:** no production code deployed; backend never restarted; no secrets/keystores/APKs/
  `.env` staged; commits only when the user explicitly asks. Mini was touched only by the planned
  restore. The disposable study + its immutable ack rows are intentional residue until the purge.

---

*Generated 2026-06-05. Source-of-truth for resuming: this file + issue #50 + the three memory
files above.*
