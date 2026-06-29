# Per-Sensor Collection Modules — Handoff

**Date:** 2026-06-12
**Status:** Complete, on-device QA'd, committed/pushed, backend+web redeployed to prod.
**Branches:** `develop` (chronicle / chronicle-api / chronicle-server / chronicle-web / root `methodic`), `main` (chronicle-models).
**Design spec:** `docs/superpowers/specs/2026-06-11-per-sensor-modules-design.md`

---

## What shipped

Each of the 14 `AndroidSensorType` values is now its own first-class
`CollectionModuleId` — a sensor is configured exactly like a usage module:

```
sensor_accelerometer      sensor_gyroscope          sensor_magnetometer
sensor_gravity            sensor_linear_acceleration sensor_rotation_vector
sensor_step_counter       sensor_light              sensor_proximity
sensor_significant_motion sensor_tilt_detector      sensor_screen_orientation
sensor_samsung_grip_wifi  sensor_samsung_motion
```

- **Per-sensor required/optional/unavailable** (`enabled+required` / `enabled+!required`
  / `!enabled`), same consent gate, same Data Sharing row.
- **Per-sensor sampling** — each carries its own `samplingRateHz` +
  `dutyCycleActiveSeconds` + `dutyCyclePeriodSeconds` on
  `CollectionModuleSetting.sensorPolicy`, defaulting to the legacy **5 Hz / 30 s on /
  300 s period** (untouched = identical to before).
- **Surfaces:** web study form + backend are fully editable per sensor (rate/duty +
  required/optional/unavailable). Mobile shows each sensor's Hz/duty **read-only** in its
  Data Sharing row; the participant can still consent-toggle optional sensors.
- **`hardware_sensors` retired** to a decode-only alias (`active=false`) so legacy
  persisted settings/acks still deserialize. The legacy `AndroidSensor` bridge now
  populates the per-sensor modules.

`SensorCollectionModules` (chronicle-models) owns the `AndroidSensorType ↔
CollectionModuleId` mapping. `ACK_GATED_MODULES` = `{usage_events, device_lifecycle,
user_identification, battery_telemetry} + SensorCollectionModules.sensorModuleIds`.

## Blast radius (what changed, by repo)

- **chronicle-models** (`main`): `CollectionModuleId` (14 `sensor_*` + `hardware_sensors`
  decode alias), new `SensorCollectionModules.kt`, `CollectionModuleSetting` (sensorPolicy
  docs + `AndroidDataCollectionSetting.hasAnySensorModule()`), `CollectionDefaults`
  per-sensor defaults, `AndroidDataCollectionSetting.fromLegacy` → per-sensor, model +
  serialization tests.
- **chronicle (android, `develop`):** `CollectionSettingsResolver` (per-sensor authority),
  `CollectionStateMachine` (ACK_GATED_MODULES), `SensorRuntimeController` (per-sensor
  duty-cycle scheduling + `reconcile()`), `SensorGateway`, `SensorRuntimeSettings`,
  `SensorSettings`, `SensorSettingsRefreshDelegate` (availability-only),
  `CollectionLoopCoordinator` (single hardware-gated `resolveCollectableSettings()` +
  sensor-service lifecycle owner), `CollectionModules` registry, `CollectionConsentCopy`,
  `DataSharingFragment` per-sensor rows + read-only Hz/duty, layout, `Enrollment.kt`
  (legacy-blob gate). Retired `SettingsActivity` + its layout/prefs. Tests across
  `:app` + `:collection-*`.
- **chronicle-server** (`develop`): legacy-bridge + per-sensor coverage in
  `StudyControllerTest` / `StudyTests` (per-sensor support flows through the
  chronicle-models dependency; no main-code change needed).
- **chronicle-api** (`develop`): `chronicle.yaml` `CollectionModuleId` enum.
- **chronicle-web** (`develop`): `study-constants`, `study-form-helpers`,
  `study-form-dialog` (per-sensor editable form), `study-participants-page`, regenerated
  `chronicle-api.generated.ts`, tests.
- **root (`methodic`, `develop`):** security guardrails (below) + design spec +
  submodule pointer bumps.

## Four QA-found bugs the redesign introduced — all fixed

1. **Legacy sensor-settings refresh clobbered the per-sensor config.**
   `SensorSettingsRefreshDelegate` fetched the retired device-wide `AndroidSensor` setting
   (empty for per-sensor studies) and `store.save(empty)` → wiped the coordinator-owned
   per-sensor set. **Fix:** delegate is now availability-only (reports the coordinator set,
   never save/clear/fetch/start/stop). Coordinator is the sole owner of per-sensor config
   + service lifecycle.
2. **Service didn't re-register sensors enabled mid-session.** Controller's scheduled set
   was fixed at `start()`. **Fix:** `SensorRuntimeController.reconcile()` (idempotent,
   `scheduledContinuous`/`armedPersistent` tracking) called from `onStartCommand` when
   already started — schedules only newly-enabled sensors, no restart.
3. **Sensor consent ignored device hardware.** A study-enabled sensor the device
   physically lacks (e.g. a Samsung-only sensor on a Pixel) got a walkthrough consent
   screen + post-enrollment notification for hardware that can never collect. **Fix:**
   `CollectionLoopCoordinator.retainCollectableSensors(resolved, availableSensorModules())`
   (`SensorManager.getDefaultSensor` per sensor) drops device-absent sensor modules
   **before** reconcile, applied through one `resolveCollectableSettings()` helper at all
   3 call sites (`consentPlanFor`, `sync`, `seedAndApplyDecisions`).
4. **Removing a sensor from a per-sensor study didn't turn it off on enrolled devices.**
   `CollectionSettingsResolver` fallback order is GENERALIZED → LEGACY_BRIDGE →
   SAFE_DEFAULT. A study-removed sensor fell through Tier-1 and got **re-enabled** by
   Tier-2 from the device-persisted legacy `AndroidSensor` blob. **Fix + defense-in-depth
   (2 layers):** (a) resolver suppresses the legacy bridge for a sensor module when the
   generalized config carries **any** `sensor_*` entry — a migrated config is authoritative
   for every sensor, so an omitted one falls to the disabled SAFE_DEFAULT; (b)
   `Enrollment.kt` gates the legacy `getAndroidSensorSettings`+`save`+startService block
   behind `if (!fetched.hasAnySensorModule())`, so per-sensor studies never persist the
   stale legacy blob in the first place.

## Regression guards added

- **ast-grep** `tests/security/ast-grep/collection-settings-resolver-only-via-coordinator.yml`
  — `CollectionSettingsResolver(...)` may only be constructed in
  `CollectionLoopCoordinator.resolveCollectableSettings` (the single hardware-gate +
  per-sensor-authority point). Any other construction = a resolution path that bypasses
  the gate (bug #3) and the legacy-bridge suppression (bug #4). Fixture:
  `fixtures/collection/astgrep/collection/other/DirectResolverConstructionFixture.kt`.
- **semgrep mirror** in `tests/security/collection-rules/collection-modularization.yaml`,
  id `chronicle-collection-resolver-construction-only-in-coordinator` (cross-engine).
  Positive fixture in `SemgrepPositiveFixtures.kt`.
- Both wired into `run-all-security.sh` (collection real-code list) and
  `collection-guardrail-fixtures.sh` (fire-on-bad-fixture self-check). Verified both
  directions.
- **Tests:** resolver matrix `perSensorConfigIsAuthoritativeForEverySensorEvenAgainstAFullLegacyBridge`
  (+ omitted-sensor + legacy-still-applies cases) in `CollectionSettingsResolverTest`;
  `testHasAnySensorModuleDetectsPerSensorConfig` in `CollectionModelsTest`;
  hardware-gate guard `CollectionLoopCoordinatorSensorGatingTest` (bug #3);
  `collection-module-id-no-raw-string` already covers all 14 sensor strings.
- **Reconciled 2 pre-existing red guardrails the redesign outgrew:**
  `collection-hardware-service-only-via-manager` now ignores
  `CollectionLoopCoordinator.kt` (the new sensor-service lifecycle owner);
  `chronicle-collection-dto-no-secret-fields` excludes `CollectionAcknowledgmentEntry.kt`
  (server-side consent trail — must carry the real participantId as the audit anchor).

## Verification (run locally — GitHub Actions is infra-broken on these repos)

- `:chronicle-models:test` — green.
- `:collection-core:test`, `:app:testDebugUnitTest`, `:collection-*:testDebugUnitTest` — green.
- `:chronicle-server:test` (collection/study tests) — green.
- `bun run check` (typecheck + biome + ast-grep + e2e-dsl) — green; `check:api-types` no drift.
- `tests/security/run-all-security.sh collection` — semgrep 0, ast-grep 0/8 rules,
  fixture self-check 10/10, **exit 0**.
- `:app:assembleRelease` — green (versionCode 47, R8 disabled for `release`, signing
  secret injected via `providers.environmentVariable`).

**Pre-existing unrelated failure (not introduced here):** chronicle-api
`AuditActionEnumTest.testAuditActionCount` / `testAuditActionOrdinalDataDeletion` assert a
stale hard-coded `AuditAction` enum count/ordinal — untouched audit code, predates this
work.

## On-device QA (Pixel 10a, study 47e2579c)

Full per-sensor path verified end-to-end: web/DB per-sensor config → device → read-only
Hz/duty per Data Sharing row → per-sensor consent toggle → `SensorRuntimeController`
registers at the configured rate → flush → upload → `android_sensor_data` storage.

- **Hardware gate proven live (fresh destructive re-enroll, all-14 study v8):** gate log
  fired synchronously at all 3 call sites — `Hardware-gated out 2 device-absent sensor
  module(s): [sensor_samsung_grip_wifi, sensor_samsung_motion]`. Wizard rendered **"Step 1
  of 16"** (not 18); no Samsung screen. Consent trail: 16 accepted (0 Samsung), 0 declined.
- **Bug #4 fix proven live:** after narrowing the study 14→5 sensors, the removed sensors
  log `resolved to safe default (enabled=false)`. Data Sharing shows the **three distinct
  states**: "On — collecting · 5 Hz · 30s on / 270s off" (the 5), "Not collected by this
  study" (study-removed), "Not available on this tablet" (Samsung, hardware-absent).

## Official beta study config (`47e2579c-a17f-48d6-9189-e26af2f3c201`)

`Chronicle Beta Study`, version 9, 12 modules:
- `usage_events` — **Required**.
- Optional: `device_lifecycle`, `user_identification`, `battery_telemetry`,
  `questionnaire`, `upload_telemetry`, `sensor_availability`.
- Sensors (optional): `sensor_accelerometer`, `sensor_light`, `sensor_proximity`,
  `sensor_screen_orientation`, `sensor_step_counter` — high-context + low-power
  (step_counter is near-zero battery, a sedentary covariate).
- The other 9 sensors (gyro / magnetometer / gravity / linear_accel / rotation_vector /
  significant_motion / tilt_detector + 2 Samsung) removed.

Edits applied DB-direct via chained `#-` deletes + `jsonb_set` version bump (single inline
`-c`; heredoc / `-c -v` forms both fail). Pre-narrowing usage-only baseline backed up at
`/tmp/beta_study_settings_pre_official.json`.

## Deploy state

- **Backend (`chronicle-backend`):** redeployed to prod from committed source
  (`docker compose -f docker-compose.traefik.yml build chronicle-backend && up -d`). Serves
  per-sensor `DataCollection` settings (the typed `AndroidDataCollectionSetting` round-trip
  requires the per-sensor models — the pre-redesign image strips unknown `sensor_*` keys on
  deserialize). `MOBILE_SIGNING_REQUIRED=true` kept.
- **Web frontend:** redeployed to prod from committed source — researchers get the
  per-sensor editable study form.
- **Tablets:** Pixel 10a runs the fixed + defense-in-depth APK on study v9 (verified).

## Open follow-ups

- **SM-X210 + Fire still run the OLD APK** (no resolver fix) — they'd hit bug #4 and keep
  collecting the 9 removed sensors via `LEGACY_BRIDGE` until reinstalled. **Blocked on their
  current wifi-adb endpoints** (ports rotate; supply them, e.g. `adb connect <ip:port>`).
  APK ready at `chronicle/app/build/outputs/apk/release/app-release.apk`; reinstall recipe:
  `install -r` (preserves enrollment) → `am force-stop` → `monkey` cold-start → confirm the
  resolver log shows 5 GENERALIZED + the rest safe-default.
- The chronicle-api `AuditAction` enum-count test (pre-existing, unrelated) should be
  reconciled separately.
