# Chronicle Data Collection Modularization — Architecture Design Specification

Date: 2026-05-20
Status: design artifact (Phase 1 of `DATA-COLLECTION-MODULARIZATION-REFACTOR-PLAN.md`).
This document is the design contract that Phases 2–10 implement against. It does
not change runtime behavior; it specifies boundaries.

Grounded in the current `chronicle` submodule (single `:app` Gradle module,
`ChronicleDb` Room schema v9) and `chronicle-server`/`chronicle-api` as committed
on branch `refactor/data-collection-modularization`.

---

## 1A. Module Taxonomy

### 1A.1 Module ID naming rules

- Module IDs are lowercase `snake_case`, stable, and never reused.
- Each ID is declared exactly once as an enum constant (`CollectionModuleId`); no
  raw string literal duplication. Wire/diagnostics use `CollectionModuleId.id`.
- IDs are decoupled from class names and package paths so modules can move during
  the Gradle split (Phase 10) without an ID change.

### 1A.2 Active module IDs

| Module ID            | Responsibility (current code it wraps)                                              | Privacy class            |
|----------------------|-------------------------------------------------------------------------------------|--------------------------|
| `usage_events`       | `UsageEventsChronicleSensor` + `UsageCollectionDelegate` polling of `UsageStatsManager` | `BEHAVIORAL_METADATA`    |
| `device_lifecycle`   | `DeviceLifecycleEventRecorder` + `DeviceStateSampler` + lifecycle receivers          | `DEVICE_STATE_METADATA`  |
| `hardware_sensors`   | `HardwareSensorService` sensor runtime + `SensorSettingsRefreshWorker`               | `PHYSICAL_TELEMETRY`     |
| `user_identification`| `EnrollmentSettings.setTargetUser` + `UserQueueEntry` + `DeviceUnlockMonitoringService` | `LOCAL_PARTICIPANT_LABEL`|
| `upload_telemetry`   | `UploadServerEntity` state + `upload_stats` + worker results                         | `OPERATIONAL_DIAGNOSTICS`|
| `sensor_availability`| `SensorAvailabilityReporter` modeled-sensor inventory                                | `DEVICE_CAPABILITY`      |

### 1A.3 Reserved (inactive) module IDs

Declared in `CollectionModuleId` with `active = false`; no implementation, no
registry entry, fails the "module must be registered" guardrail if instantiated:
`time_use_diary`, `questionnaire`, `app_inventory`. Reserved only to freeze the ID
namespace; activating any requires its own privacy classification + tests (refactor
plan decision #17).

### 1A.4 Privacy classes (`CollectionPrivacyClass`)

| Class                     | Meaning                                              | Default enabled? |
|---------------------------|------------------------------------------------------|------------------|
| `BEHAVIORAL_METADATA`     | App-usage event metadata, study-controlled           | Study-controlled |
| `DEVICE_STATE_METADATA`   | Battery/network/screen/power lifecycle state         | Enabled (enrolled) |
| `PHYSICAL_TELEMETRY`      | Hardware sensor samples                              | Opt-in only      |
| `LOCAL_PARTICIPANT_LABEL` | Participant label chosen locally on-device           | Pref-controlled  |
| `OPERATIONAL_DIAGNOSTICS` | Upload/queue health, no participant data             | Enabled          |
| `DEVICE_CAPABILITY`       | Which modeled sensors the device exposes (report-only) | Enabled          |

`PHYSICAL_TELEMETRY` and `LOCAL_PARTICIPANT_LABEL` are **never** enabled implicitly;
resolver defaults must be `false` and only a server setting / explicit preference
flips them (refactor plan decision #15–17).

### 1A.5 Disallowed-by-default sources

No module may introduce: screenshots, accessibility text, raw notification content,
GPS/location, microphone, contacts, call logs, SMS, browser history (plan decision
#16, Non-Goals #7–12). No new Android permission is added by this refactor.

### 1A.6 Per-module obligations

Every active module declares: stable `CollectionModuleId`, `CollectionPrivacyClass`,
allowed output fields, required diagnostics, required tests, and the static
guardrail(s) that protect its boundary (catalog in §4).

---

## 1B. Shared Contracts (`chronicle-models`)

DTOs live in `chronicle-models` so Android, `chronicle-api` and `chronicle-server`
share one definition. All are added **additively** — no existing wire shape changes.

### 1B.1 `StudySettingType`

Keep `AndroidSensor` exactly as-is. Add `DataCollection` as a new polymorphic
`StudySetting` subtype. Servers and clients that only know `AndroidSensor` keep
working; `DataCollection` is read with a legacy fallback (§1B.4).

### 1B.2 `AndroidDataCollectionSetting`

```
AndroidDataCollectionSetting : StudySetting
  modules: Map<CollectionModuleId, CollectionModuleSetting>   // unknown IDs ignored, not fatal
  version: Int                                                // schema discriminator, default 1
```

```
CollectionModuleSetting
  enabled: Boolean                       // default per privacy class (§1A.4)
  collectionCadence: CollectionCadence
  uploadCadence: CollectionCadence
  batteryPolicy: BatteryPolicy
  networkPolicy: NetworkPolicy
  sensorPolicy: AndroidSensorSetting?     // bridge: only hardware_sensors populates it
```

`CollectionCadence { intervalSeconds, jitterSeconds }`,
`BatteryPolicy { minLevelPercent, stopBelowCriticalPercent, degradeInPowerSave }`,
`NetworkPolicy { requireUnmetered, requireConnected }`.

### 1B.3 `CollectionModuleDiagnostics`

Operational telemetry only. Hard rule (guarded by Semgrep): **no** `apiKey`,
`MOBILE_SIGNING_SECRET`, raw `participantId`, or raw request bodies. Participant
references are redacted (hash/prefix).

```
CollectionModuleDiagnostics
  moduleId, privacyClass, lastRunEpochMs, lastResult, itemsCollected,
  queueDepth, lastError (redacted message only), notTracked: Set<String>
```

### 1B.4 Compatibility / resolution rules

- **Serialization**: explicit Jackson polymorphic handling for the `StudySetting`
  hierarchy; no default typing. Unknown JSON fields ignored (`@JsonIgnoreProperties`),
  consistent with existing models.
- **Fallback order** (server→client precedence): `DataCollection` setting →
  legacy `AndroidSensor` setting → safe coded defaults.
- **Legacy bridge**: a missing `DataCollection` setting derives `hardware_sensors`
  from `AndroidSensor` (empty `AndroidSensor` ⇒ `hardware_sensors.enabled = false`).
- **Defaults are safe**: missing/invalid setting disables the affected module and
  logs; it never silently enables a privacy-sensitive module.
- **Validation**: negative sampling rate, `dutyActive > dutyPeriod`, non-positive
  cadence are rejected or explicitly clamped — never accepted silently.

---

## 1C. Mobile Internal Interfaces

Grounded in the real call graph (architecture map). All interfaces are introduced
in Phase 3 with no callsite switched; behavior changes module-by-module in 4–8.

### 1C.1 Core contracts

```
interface DataCollectionModule
  val id: CollectionModuleId
  val privacyClass: CollectionPrivacyClass
  fun status(): CollectionModuleStatus
  fun diagnostics(): CollectionModuleDiagnostics
  fun start(ctx): ModuleResult        // sensors/services
  fun stop(ctx): ModuleResult
  fun poll(ctx, window): ModuleResult // usage/lifecycle pull modules
  fun flush(ctx): ModuleResult

enum CollectionModuleStatus { DISABLED, IDLE, ACTIVE, DEGRADED, FAILED }
sealed ModuleResult { Ok(items:Int) | Skipped(reason) | Retry(reason) | Failed(error) }
```

A disabled module returns `Skipped` for every call and writes nothing — no-op,
not an exception.

### 1C.2 Sinks (the only sanctioned writers to persistence)

```
interface CollectionSink
interface UsageEventSink : CollectionSink   // wraps StorageQueue.insertEntries -> dataQueue
interface SensorSampleSink : CollectionSink // wraps SensorSampleDao.insertAll -> sensor_samples
interface UploadStatsSink : CollectionSink  // wraps UploadStatsDao -> upload_stats
```

Current direct writers that migrate behind sinks (architecture map):
`UsageCollectionDelegate.persistUsageQueueAndCheckpoint` and
`DeviceLifecycleEventRecorder.recordNow` (→ `dataQueue`); `HardwareSensorService`
`flushBuffer`/`onDestroy` (→ `sensor_samples`). The lifecycle sink composes the
usage sink — lifecycle events are system-origin usage-style rows (plan decision #13).
`QueueEntry`/`SensorSampleEntry` serialization is preserved byte-for-byte.

### 1C.3 Coordination contracts

```
CollectionSettingsResolver  // resolves AndroidDataCollectionSetting per §1B.4, with validation
CollectionModuleRegistry    // id -> DataCollectionModule; rejects unregistered/unknown IDs
CollectionModuleManager     // start/stop/poll fan-out; the single owner of module lifecycle
CollectionScheduler         // owns WorkManager unique-work names; intervals unchanged
CollectionUploadCoordinator // wraps runCombinedUpload ordering (usage then sensors)
CollectionLifecycleBridge   // receivers delegate here instead of recorder/sampler directly
CollectionBootCoordinator   // StartOnBoot/MainActivity/Enrollment call this, not services
CollectionBatteryPolicy / CollectionNetworkPolicy  // typed wrappers over BatteryPolicy/NetworkPolicy
```

`CollectionScheduler` keeps the exact existing unique-work names
(`combined_upload`, `usage`, `sensor_settings_refresh*`) and intervals so already
enqueued work and enrolled devices are unaffected (plan decisions #10–11).

### 1C.4 Migration safety

Each module keeps a compatibility shim (e.g. `DeviceLifecycleEventRecorder.recordAsync`
delegating to the lifecycle module) until parity tests pass; an internal migration
switch defaults to current behavior until a module proves parity. Direct service
starts (`HardwareSensorService.startService`) and direct queue writes become
forbidden outside the manager/sinks — enforced by ast-grep (§4).

---

## 1D. Backend / API Compatibility

This refactor is mobile-architecture-facing. Backend changes are minimal and
strictly additive; the verification gate is "existing client still works".

### 1D.1 Preserved, unchanged

- Mobile routes: `v4` enroll, `v4` `/android` usage upload, `v4` `/android/sensors`,
  `v4` `/android/sensors/availability`, `v3` `AndroidSensor` settings read.
- `ChronicleUsageEvent.activityClass` (nullable) and migration `V22` `activity_class`.
- Upload batch-size limits, participant/data-source auth checks, RLS request-scoped
  connection context, local Postgres target.
- No Redshift/AWS/Twilio/Firebase/Alertmanager re-introduction (plan Non-Goals).

### 1D.2 Additive only (Phase 9)

- A generalized `DataCollection` settings read may be added **after** Phase 2 model
  contracts land, and only with the legacy `AndroidSensor` fallback intact — no app
  update may be required for the server to accept current payloads.
- Any new endpoint/DTO ⇒ update `chronicle.yaml`, regenerate web types, add contract
  drift tests. Settings reads stay study-scoped and RLS-enforced; settings writes are
  admin-scoped.

### 1D.3 Compatibility matrix (acceptance)

| Client state           | Server state            | Required outcome                        |
|------------------------|-------------------------|-----------------------------------------|
| current app            | current server          | unchanged — regression baseline         |
| current app            | server + `DataCollection` | unchanged; server ignores app's unawareness |
| app + module settings  | current server          | app falls back to `AndroidSensor`        |
| app + module settings  | server + `DataCollection` | app reads generalized settings           |

---

## 4. Static Guardrail Catalog

Guardrails are authored in Phase 12 but specified here so each implementation
subphase knows its boundary. Each rule needs a positive fixture and a documented
allowed-path exception for legacy code; all run via `tests/security/run-all-security.sh`.

| # | Tool     | Rule                                                                          | Protects |
|---|----------|-------------------------------------------------------------------------------|----------|
| 1 | Semgrep  | every `DataCollectionModule` impl declares `id` + `privacyClass`              | 1A.6     |
| 2 | ast-grep | module IDs are `CollectionModuleId` refs, not raw strings                     | 1A.1     |
| 3 | ast-grep | `queueEntryData().insertEntry(...)` only in sanctioned sinks + tests          | 1C.2     |
| 4 | ast-grep | `sensorSampleDao().insertAll(...)` only in sensor sink/service + tests        | 1C.2     |
| 5 | ast-grep | `HardwareSensorService.startService/stopService` only via module manager     | 1C.3     |
| 6 | ast-grep | `DeviceLifecycleEventRecorder.recordAsync` only via lifecycle module/shim     | 1C.4     |
| 7 | ast-grep | `UsageMonitoringWorker` does not instantiate `ChronicleSensor` directly       | Phase 4  |
| 8 | Semgrep  | diagnostics/settings DTOs contain no `apiKey` / `MOBILE_SIGNING_SECRET`       | 1B.3     |
| 9 | Semgrep  | no enabled-by-default privacy-sensitive module in resolver defaults           | 1A.4     |
| 10| Semgrep  | upload endpoints keep size/batch validation                                   | 1D.1     |
| 11| ast-grep | settings service makes no direct RLS context-manager call                     | 1D.2     |
| 12| Semgrep  | collection modules add no new Firebase events / dangerous permissions          | Non-Goals|

---

## Phase 1 Acceptance

- Module taxonomy, privacy classes and reserved IDs are specified (§1A). ✅
- Shared-contract serialization plan covers API/server/mobile with safe,
  backward-compatible defaults (§1B). ✅
- Mobile interfaces are implementable without changing runtime behavior, and the
  current caller/callee graph is mapped (§1C, architecture map). ✅
- Backend stays compatible with the current client; new reads are additive (§1D). ✅
- No implementation change is part of this phase — design only. ✅
