# Chronicle Android — Feature Delta (fork vs upstream OpenLattice)

**Scope.** This document inventories what the **new app** (the BCM fork, `uzaira0/chronicle`,
package `com.openlattice.chronicle`) supports that the **old app** (upstream OpenLattice
`chronicle-android`) did not. The old-app baseline is: a monolithic `:app`, a single
hard-wired OpenLattice server, device-ID-only auth (device ID carried in the URL path),
plaintext SharedPreferences + plaintext Room, usage-event + hardware-sensor collection, and
awareness/questionnaire deep-link notifications. Those baseline capabilities are **excluded**
from the "new" lists below.

Status legend: **SHIPPED** = implemented and live in production wiring · **DESIGNED-ONLY** =
spec/design exists, no implementation · **RESERVED** = `CollectionModuleId` enum entry frozen
(`active = false`), no implementation.

Evidence is the Android submodule git history (HEAD `0cb5a01`, 46 commits since the
2026-04-05 fork import), the six root design/audit docs in `docs/`, and the source tree.

---

## 1. New data the app collects

| Feature | Status | Notes / evidence |
|---|---|---|
| **Battery telemetry** | SHIPPED | First sensing-expansion module. `:collection-battery` → `BatteryTelemetryCollectionModule` → `battery_samples` Room table (`Migration9to10`) → v4 `POST …/android/battery`. Captures level%, charging state, plug type, temperature, voltage, health. `CollectionModuleId.battery_telemetry` active; privacy class `DEVICE_STATE_METADATA`. |
| **Persistent event/wake-up sensor capture** | SHIPPED | Behavioral fix, not just refactor: event/on-change/one-shot sensors (tiltDetector, significantMotion, light, proximity, stepCounter, Samsung motion, screenOrientation) were duty-cycled by the old monolith and recorded **zero rows for every participant**. Now registered persistently at `start()` and stay armed. Commit `0cb5a01`. |
| **Sensor-availability reporting** | SHIPPED | `SensorAvailabilityReporter` probes every modeled sensor type and reports the device inventory to v4 `POST …/android/sensors/availability`. `CollectionModuleId.sensor_availability` active (`DEVICE_CAPABILITY`); realized by the reporter (no module class). |

## 2. Collection engine (the data-collection modularization refactor)

| Feature | Status | Notes / evidence |
|---|---|---|
| **8-module split** | SHIPPED | Monolithic `:app` → `:app` + `:collection-base / -core / -usage / -lifecycle / -sensors / -upload / -notifications / -battery`, behind a `DataCollectionModule` contract. Dependency inversions (`preferences→collection` back-edge, `collection→HardwareSensorService` cycle) broken behind interfaces; acyclic graph; merged manifest byte-identical. Phases 3–10. |
| **`CollectionModuleId` registry** | SHIPPED | Every collector keyed by a stable lowercase snake_case wire ID (never a raw string). 8 active, 5 reserved (see §7). Lives in `chronicle-models`. |
| **`CollectionPrivacyClass` taxonomy** | SHIPPED | Each module tagged with a privacy class carrying a `defaultEnabled` policy; `PHYSICAL_TELEMETRY` / `LOCAL_PARTICIPANT_LABEL` / `MEDIA_CONTENT` / `INTERACTION_METADATA` can never be implicitly enabled; resolver defaults off-on-missing/invalid. |
| **Combined-upload orchestrator** | SHIPPED | `runCombinedUploadCore`: deterministic usage-first → sensor-second (both always run), success only when both report 0 failures, retry cap 5, `-1` (delegate threw) treated as failure. Pure / WorkManager-free / unit-testable. |
| **Upload-telemetry module** | SHIPPED | `upload_telemetry` (`OPERATIONAL_DIAGNOSTICS`): observe-only health surface (queue depth, last upload `WorkInfo.State`, malformed/partial-failure counts) with hard redaction (drops apiKey/secret/participantId). No upstream equivalent. |
| **Static guardrail catalog** | SHIPPED | 12 Semgrep + ast-grep rules enforcing module discipline: module-ID-not-raw-string, sanctioned-sinks-only writers, no-direct-service-start, no-secret-in-DTO, no-default-on privacy-sensitive module, no new Firebase events / dangerous permissions. |
| **Questionnaire module** | SHIPPED | `questionnaire` (`BEHAVIORAL_METADATA`): wraps the AlarmManager questionnaire-notification scheduling formerly inline in `NotificationsWorker`. The instrument itself stays a web form (no native capture). |

## 3. Enrollment & multi-tenancy

| Feature | Status | Notes / evidence |
|---|---|---|
| **Multi-server enrollment** | SHIPPED | Up to `MAX_SERVERS = 3` concurrent servers, each its own study/participant/device/auth row + upload cursors in Room table `upload_servers`. `ServerEnrollmentActivity` (add/edit/delete + per-server upload-history stats). |
| **Deep-link / App-Links / QR enrollment** | SHIPPED | `Enrollment` activity accepts `chronicle://enroll` and `https://…/enroll` App-Links with `studyId`/`participantId`/`serverUrl` params; studyId validated UUID, serverUrl forced HTTPS. |
| **Idempotent re-enrollment** | SHIPPED | `updateEnrollmentByUrl` updates matching `upload_servers` rows before insert, so a re-enroll never keeps a stale `sourceDeviceId`. |
| **Legacy → multi-server migration** | SHIPPED | One-shot `ServerMigrationHelper` bootstraps a BCM `upload_servers` row from the legacy single-server EncryptedPrefs enrollment; gated by `server_migration_v6_done`. |
| **User-identification** | SHIPPED (see §6) | `UserIdentificationActivity` (child vs other target user) + `user_identification` module + `TargetUserRouter`. |

## 4. Auth & at-rest security

| Feature | Status | Notes / evidence |
|---|---|---|
| **Per-device API-key auth (v4)** | SHIPPED | `enroll()` returns `{chronicleId, apiKey}` (was a bare `UUID`); key persisted per server, sent as `X-Api-Key`. |
| **Dual auth modes** | SHIPPED | `AUTH_MODE_API_KEY` vs `AUTH_MODE_DEVICE_ID` per server; chosen by whether enroll returned a key. |
| **HMAC request signing** | SHIPPED | `MobileApiSigningInterceptor`: signs `METHOD\|path\|timestamp\|nonce\|sha256(body)` → `X-Chronicle-Signature/-Timestamp/-Nonce`; added only when `BuildConfig.MOBILE_SIGNING_SECRET` non-blank. |
| **EncryptedSharedPreferences** | SHIPPED | AndroidX `EncryptedPrefsHelper` (Keystore `MasterKey`); one-shot migration from plaintext prefs. Graceful plaintext fallback on Keystore failure. |
| **SQLCipher-encrypted DB** | SHIPPED | Room DB `chronicle_encrypted` via SQLCipher; 32-byte passphrase wrapped by an AndroidKeyStore AES/GCM key (`DatabaseKeyManager`). |
| **Stop leaking Android ID** | SHIPPED | Device identity is a per-enrollment random UUID; `Settings.Secure.ANDROID_ID` no longer sent; Crashlytics user-id blanked; participant/device IDs never sent to Crashlytics. |
| **Backward-compatible enroll deserializer** | SHIPPED | Dual-shape Jackson deserializer accepts both the BCM `{chronicleId, apiKey}` object and the upstream bare-UUID string — same client talks to either backend. |
| **Privacy-class guardrails** | SHIPPED | See §2; enforced both at runtime (resolver) and statically (guardrail catalog). |

## 5. Sync / upload durability & API

| Feature | Status | Notes / evidence |
|---|---|---|
| **Durable cursor-based sync** | SHIPPED | `ChronicleSyncWorker` + `UsagePollCheckpoint` (Room migration 7→8); single-flight guarded; survives process death. |
| **Selectable sync strategies** | SHIPPED | `ChronicleSyncStrategy`: `SPLIT_PERIODIC`, `COORDINATED_COLLECT_THEN_UPLOAD` (default), `COORDINATED_UPLOAD_THEN_COLLECT`. |
| **Runtime-tunable sync config** | SHIPPED | `SyncRuntimeConfig` (strategy / interval ≥15 min / requiresBatteryNotLow), plus debug-only `DebugSyncConfigReceiver` (`SET_SYNC_CONFIG`, `run_now`) for `adb am broadcast` tuning. |
| **Per-server failure handling** | SHIPPED | Consecutive-failure tracking; auto-disable a server after `MAX_SERVER_FAILURES = 50`; per-server cursors with MIN-cursor retention so a down server's data isn't trimmed. |
| **Multi-generation API client** | SHIPPED | v4 enroll/uploads (device ID in `X-Chronicle-Device-Id` header) + v3 settings/verify + legacy v1 status/notifications/questionnaires + v2 edm — one client. |

## 6. Notifications

| Feature | Status | Notes / evidence |
|---|---|---|
| **Deep-link notification types** | SHIPPED | `NotificationType { AWARENESS, QUESTIONNAIRE }`; AlarmManager notifications deep-link to the web survey/questionnaire pages (no in-app survey UI). |
| **`:collection-notifications` wrapper** | SHIPPED | Questionnaire-notification path extracted into its own module (`QuestionnaireCollectionModule`, `QuestionnaireSchedule`, `QuestionnaireNotificationAction`). AWARENESS stays inline (not modularized). |
| **FCM settings topic** | SHIPPED | On enroll, subscribes to `study_<studyId>_settings` for server-pushed settings refresh. |

## 7. `CollectionModuleId` — active vs reserved

- **Active (8):** `usage_events`, `device_lifecycle`, `hardware_sensors`, `user_identification`,
  `upload_telemetry`, `sensor_availability`, `questionnaire`, `battery_telemetry`.
- **Reserved (5, `active = false`, namespace-frozen, no implementation):** `time_use_diary`,
  `app_inventory`, `audio_activity`, `audio_content`, `interaction_events`.

## 8. Build / CI / toolchain

| Feature | Status | Notes / evidence |
|---|---|---|
| **Modular Gradle + toolchain uplift** | SHIPPED | AGP 9.0.1, Kotlin 2.3.21, KSP 2.3.7, Crashlytics gradle 3.0.7, Gradle 9.3, compile/target SDK 36, `allWarningsAsErrors=true`. |
| **App signing config** | SHIPPED | `signingConfigs.chronicle` from gitignored `app/signing.properties`; build types `debug / release / debugMinified / releaseMinified` (R8 minify + shrinkResources on minified). |
| **CI workflows** | SHIPPED | `signing-verify`, `gitleaks`, `dependabot` (gradle + github-actions). |

---

## 9. Designed / reserved — NOT built yet

| Item | Status | Source |
|---|---|---|
| App-audio: `audio_activity` (playback metadata) + `audio_content` (MediaProjection capture, IRB-gated) | DESIGNED-ONLY; IDs RESERVED | `SENSING-EXPANSION-DESIGN.md` §4 |
| Interaction salience: content-free tap/scroll grid regions via AccessibilityService | DESIGNED-ONLY; ID RESERVED | `SENSING-EXPANSION-DESIGN.md` §6 |
| App inventory (`app_inventory`) and on-device Time-Use-Diary (`time_use_diary`) | RESERVED | enum + CLAUDE.md |
| Participant outreach: compliance ladder + Temporal escalation + dashboard at-risk panel | DESIGNED-ONLY (server/web) | `SENSING-EXPANSION-DESIGN.md` §7 |
| New privacy classes `MEDIA_CONTENT` / `INTERACTION_METADATA`, policy DTOs `AudioCapturePolicy` / `InteractionPolicy` | DESIGNED-ONLY | `SENSING-EXPANSION-DESIGN.md` §3 |
| Per-study per-module config UI (study dashboard) — web form still emits legacy `AndroidSensorSetting` | DESIGNED-ONLY (the gap) | `SENSING-EXPANSION-DESIGN.md` §2 |
| SSL certificate pinning | DESIGNED-ONLY (TODO in OkHttp builder) | `utils/Utils.kt` |

---

## 10. Modularization end-state remediation

The modularization had two incomplete edges at HEAD `0cb5a01`. **Both are now closed**
(working-tree changes, not yet committed; verified by `:app:assembleDebug` + 270 green unit
tests + on-device runtime check).

1. **`user_identification` module activated (was shadowing).** Parity was confirmed
   byte-for-byte — `UserIdentificationCollectionModule.setTargetUser` performs the same
   `userQueue` insert + `current_user` pref write as the legacy `EnrollmentSettings`
   body, and `TargetUserRouter` only routes to the module when identification is enabled, so
   the unconditional disable→`user_unassigned` write still lands via the legacy path and no
   write can be lost. `UserIdentificationMigration.USE_MODULE_MANAGER_USER_IDENTIFICATION_PATH`
   is now `true`; `UserIdentificationMigrationTest` pins the activated value (mirroring the
   other 7 flipped modules' guard tests); the two stale docstrings were updated. All 8 module
   paths are now live.

2. **`CollectionModuleRegistry` now driven at runtime (was scaffolding).** A new
   `CollectionModules` provider (`app/.../collection/CollectionModules.kt`) builds a
   process-wide registry **lazily** (on the first consumer's background thread — never on the
   startup main thread) and **crash-safe** (a module that fails to register is logged and
   skipped, never propagated), registering the 6 holder-backed active modules
   (`battery_telemetry`, `device_lifecycle`, `hardware_sensors`, `questionnaire`,
   `upload_telemetry`, `user_identification`). `ChronicleSyncWorker` drives `registry.all()`
   every sync via a read-only, redaction-safe `id=status` module-health line. `usage_events`
   (built per-collection in its delegate with run-scoped cursor state) and `sensor_availability`
   (a reporter, not a `DataCollectionModule`) remain **intentionally** non-registry-managed —
   architecture, not a gap. Worker module resolution still goes through the per-module holders;
   the registry is a faithful view over the same singleton instances, so the live collection
   paths are unchanged. A property-based hardening test (`CollectionModulesContractTest`) locks
   the invariants (every managed id active + non-reserved + privacy-class-consistent; managed
   set == active modules minus the two documented non-module ids). Verified on-device: the sync
   run logs `Collection module registry built: [...6 modules]` and a `Collection module health:
   ...` line.

   A further, deliberately-deferred escalation — routing worker module *resolution* through the
   registry instead of the holders — touches live collection paths and is **not** done here; it
   would be a separate, separately-reviewed change.
