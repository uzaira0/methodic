# Sensing Expansion Design

Design spec for four new data-collection capabilities, all delivered as
`:collection-*` modules under the existing modularization architecture and all
configurable per-study from the web study dashboard.

Status: **partially implemented.** Feature B (battery telemetry) is built and
shipped — the `:collection-battery` Android module, `CollectionModuleId
.battery_telemetry` (active), the `battery_telemetry` server table with
`V24__add_battery_telemetry.sql`, the `uploadBatteryTelemetryV4` endpoint
(`/chronicle/v4/study/{studyId}/participant/{participantId}/android/battery`, plus
the deprecated v3 variant), and `AuditAction.BATTERY_TELEMETRY_UPLOAD`. Feature A
(app audio), Feature C (interaction salience), and Feature D (participant outreach)
remain **design — not yet implemented**; their `CollectionModuleId`s
(`audio_activity`, `audio_content`, `interaction_events`) exist only as **reserved,
inactive** (`active = false`, namespace-frozen, no implementation). Companion to
`DATA-COLLECTION-MODULARIZATION-DESIGN.md` (the modularization this builds on).

## 1. Scope

Four capabilities, decided in design discussion:

| # | Capability | Streams | Default |
|---|------------|---------|---------|
| A | App audio | `audio_activity` (metadata) + `audio_content` (raw) | activity on, content opt-in |
| B | Battery telemetry | `battery_telemetry` | on |
| C | Interaction salience | `interaction_events` | opt-in |
| D | Participant outreach | server/web compliance + escalation | per-study |

Hard requirement: A–C are `:collection-*` Gradle modules following the existing
module pattern; A–D are **fully configurable per study from the study dashboard**,
with no code change needed to tune a study.

Explicitly **out of scope**: screenshots / screen-content capture, microphone
(ambient) audio, GPS/location, communication-log capture, and visual saliency
(it requires screen pixels — see §9).

## 2. What already exists (build on, do not reinvent)

The modularization refactor already provides the per-study configuration spine:

- `CollectionModuleId` (chronicle-models) — stable snake_case IDs, `active` flag,
  `CollectionPrivacyClass`.
- `CollectionPrivacyClass` — `defaultEnabled` policy; `PHYSICAL_TELEMETRY` and
  `LOCAL_PARTICIPANT_LABEL` are never enabled implicitly.
- `AndroidDataCollectionSetting` — polymorphic `StudySetting` bound to
  `StudySettingType.DataCollection`; `modules: Map<CollectionModuleId,
  CollectionModuleSetting>`. Tolerant deserialization (unknown IDs dropped).
- `CollectionModuleSetting` — per-module `enabled`, `collectionCadence`,
  `uploadCadence`, `batteryPolicy`, `networkPolicy`, and the nullable
  module-specific `sensorPolicy` (only `hardware_sensors` uses it).
- `CollectionDefaults` — safe-default factory; privacy-class-driven enablement.
- Android `:collection-base/core/upload/sensors/usage/lifecycle/notifications`
  Gradle modules.

**Gap:** the web study-setup form (`chronicle-web` `study-form-dialog.tsx` /
`study-form-helpers.ts`) still builds the **legacy** `AndroidSensorSetting`, not
`AndroidDataCollectionSetting`. Per-study module configuration from the dashboard
therefore needs the form migrated to the generalized model (§8).

## 3. Cross-cutting model changes (chronicle-models)

### 3.1 New `CollectionModuleId` entries

```
AUDIO_ACTIVITY     ("audio_activity",     BEHAVIORAL_METADATA,    active = true)
AUDIO_CONTENT      ("audio_content",      MEDIA_CONTENT,          active = false)
BATTERY_TELEMETRY  ("battery_telemetry",  DEVICE_STATE_METADATA,  active = true)
INTERACTION_EVENTS ("interaction_events", INTERACTION_METADATA,   active = false)
```

`active` here marks the *module exists*; per-study `enabled` is separate and
researcher-controlled. `audio_content` ships `active = false` until the IRB
consent path lands.

### 3.2 New `CollectionPrivacyClass` values

```
MEDIA_CONTENT       (defaultEnabled = false)  // first *content* class — raw audio
INTERACTION_METADATA(defaultEnabled = false)  // tap-region + scroll, content-free
```

`MEDIA_CONTENT` is Chronicle's first content-bearing class. It carries data-
classification and consent implications (§10) — treat its introduction as a
deliberate escalation, not a routine enum addition.

### 3.3 Module-specific policy DTOs

Following the `sensorPolicy` precedent — nullable, named, only the owning module
populates it — add to `CollectionModuleSetting`:

- `audioCapturePolicy: AudioCapturePolicy? = null` — owned by `audio_content`.
- `interactionPolicy: InteractionPolicy? = null` — owned by `interaction_events`.

`audio_activity` and `battery_telemetry` need no special policy; the uniform
cadence/battery/network fields suffice.

```
AudioCapturePolicy(
    captureWindowSeconds:    Int,      // length of one capture window
    captureIntervalSeconds:  Int,      // gap between windows (duty cycle)
    maxDailyCaptureMinutes:  Int,      // hard daily cap
    gateOnForegroundMedia:   Boolean,  // only capture while a media app is foreground + audio active
    excludedAppPackages:     Set<String> = emptySet(),  // study-defined app blocklist
)
InteractionPolicy(
    gridRows: Int,           // screen-region grid granularity
    gridCols: Int,
    captureClicks:  Boolean,
    captureScrolls: Boolean,
    // element TEXT / contentDescription is NEVER captured — not a configurable option
)
```

All DTOs validate in `init {}` (positive intervals, `captureWindowSeconds <=
captureIntervalSeconds`, grid dims `>= 1`), matching `CollectionCadence` /
`BatteryPolicy` convention. No DTO carries `apiKey` / participant identifiers.

## 4. Feature A — App audio (`:collection-audio`)

New Gradle module `:collection-audio`, two streams:

### 4.1 `audio_activity` — metadata (always-on, content-free)

- `AudioManager.registerAudioPlaybackCallback` → `AudioPlaybackConfiguration`
  list: which apps are playing audio, the `AudioAttributes` usage/content type,
  start/stop. No audio content.
- Privacy class `BEHAVIORAL_METADATA`; default-enabled.
- Doubles as **attribution** for `audio_content` and covers apps that opt out of
  playback capture.

### 4.2 `audio_content` — raw playback capture (opt-in)

- `AudioPlaybackCapture` via `MediaProjection` + a `mediaProjection`-typed
  foreground service. Requires the **`RECORD_AUDIO`** permission to open the
  `AudioRecord` (the mic is not used; the permission is still required) and
  `FOREGROUND_SERVICE_MEDIA_PROJECTION`.
- The OS hard-blocks `USAGE_VOICE_COMMUNICATION` — phone/VoIP call audio cannot
  be captured. App-level exclusion of messaging apps is handled by
  `AudioCapturePolicy.excludedAppPackages` → `AudioPlaybackCaptureConfiguration
  .excludeUid(...)`.
- Apps may opt out (`allowAudioPlaybackCapture="false"`); DRM video typically
  does — coverage is partial and skews to social/short-video/music.
- Duty-cycled by `AudioCapturePolicy`: windowed capture, gated on a media app
  being foreground with active playback, with a daily cap. Not continuous.
- Privacy class `MEDIA_CONTENT`; default-disabled; `active = false` until §10.

Server: new tables `app_audio_activity` and `app_audio_content` (the latter
storing object references, not inline blobs), Flyway migration, RLS enabled,
`pg_tde`. Ingested through the existing `/chronicle/v3/` upload path.

## 5. Feature B — Battery telemetry (`:collection-battery`)

New Gradle module `:collection-battery`, stream `battery_telemetry`.

- `BatteryManager` + the `ACTION_BATTERY_CHANGED` sticky broadcast: level,
  charging state, plug type (AC/USB/wireless), temperature, voltage, health.
- Privacy class `DEVICE_STATE_METADATA`; default-enabled. No new permission, no
  consent prompt.
- Event-driven on battery-state change, coalesced to `collectionCadence`.
- Server: `device_battery_telemetry` table + Flyway migration.

Decision taken: a **separate module**, not folded into `device_lifecycle` —
cleaner independent toggling and migration-switch parity.

## 6. Feature C — Interaction salience (`:collection-interaction`)

New Gradle module `:collection-interaction`, stream `interaction_events`.

- A new `AccessibilityService` (`BIND_ACCESSIBILITY_SERVICE`; the participant
  enables it in system settings — needs a dedicated onboarding screen).
- Captures `TYPE_VIEW_CLICKED` / `LONG_CLICKED` / `SCROLLED` → from
  `AccessibilityNodeInfo.getBoundsInScreen()`, a **coarse screen-region grid
  cell** (`InteractionPolicy.gridRows × gridCols`), the element *role*, the
  foreground package, and scroll direction/magnitude.
- **Element text / `contentDescription` is never logged** — content-free by
  construction; this is not a setting.
- Scope is **interaction salience** (where attention lands — tap-region density,
  scroll volume), explicitly **not** visual saliency (§9).
- Privacy class `INTERACTION_METADATA`; default-disabled (needs explicit
  Accessibility opt-in). `active = false` until the onboarding screen lands.
- Server: `interaction_events` table + Flyway migration.

## 7. Feature D — Participant outreach (server + web)

Not a collection module — a study-level compliance + escalation feature.

- **Compliance evaluator** — per participant, over existing signals
  (`StudyComplianceController`, `participant_stats`, `study_realtime_stats`):
  no upload in N days, a stream stopped, a questionnaire window missed,
  data-provision below threshold.
- **Escalation ladder on Temporal** (the `docker-compose.temporal.yml` overlay
  already exists) — a durable per-participant workflow with wait/escalate steps.
- **Tiers, both modes:**
  - *Automatic* — low-stakes nudges (missed questionnaire, short gap). Delivered
    by piggybacking the existing `NotificationsWorker` server poll: the server
    flags the participant, the app's periodic worker self-schedules a re-
    engagement notification. No FCM (out of scope per `AGENTS.md`).
  - *Human-in-the-loop* — high-stakes (withdrawal review). The dashboard surfaces
    an at-risk cohort panel; a researcher approves/sends. Researcher email via
    rhizome mail.
- **Per-study config** — `StudyOutreachPolicy` study setting: an ordered list of
  `ComplianceRule(signal, thresholdDays, tier, action)`, the `autoTierMax`
  boundary between automatic and approval-required, and nudge message templates.
  Defaults conservative (everything approval-required until the researcher opts
  a rule into automatic).

## 8. Study-dashboard configurability (chronicle-web)

The requirement: every parameter above tunable per study from the dashboard.

### 8.1 Migrate the study form to the generalized model

`study-form-helpers.ts` `buildSensorSetting` currently emits the legacy
`AndroidSensorSetting`. Add `buildDataCollectionSetting(form)` emitting
`AndroidDataCollectionSetting` (`@class`-discriminated, `StudySettingType
.DataCollection`). Keep legacy emission during transition for older app builds;
the server already accepts both and bridges via `AndroidDataCollectionSetting
.fromLegacy`.

### 8.2 Per-module configuration UI

Replace the single "Android Sensor Configuration" fieldset in
`study-form-dialog.tsx` with a **per-module panel list**, one card per
`CollectionModuleId.activeModules`:

- enabled toggle (default from `CollectionPrivacyClass.defaultEnabled`);
- collection + upload cadence (interval + jitter);
- battery policy (min level, critical-stop, power-save degrade);
- network policy (require unmetered / connected);
- module-specific controls, shown only for the owning module:
  - `audio_content` → capture window / interval, daily cap, foreground-media
    gate, app blocklist; plus an inline consent-language acknowledgement;
  - `interaction_events` → grid granularity, clicks/scrolls toggles;
  - `hardware_sensors` → the existing sensor list + sampling/duty-cycle.
- A new **Participant Outreach** section → `StudyOutreachPolicy` (rule rows,
  auto/approval boundary, message templates).

Privacy-sensitive modules (`audio_content`, `interaction_events`,
`hardware_sensors`) render with a distinct treatment and an explicit
enable-confirmation, never a silent default-on.

### 8.3 Contract

New DTOs go into `chronicle-api/chronicle.yaml`; regenerate web types via
`bun run generate:api-types`; `bun run check:api-types` guards drift.

## 9. Visual saliency — why it is out of scope

Visual saliency (predicting where gaze lands on a screen) inherently requires the
screen pixels: screenshot → on-device saliency model → heatmap. There is no
pixel-free path. MediaPipe offers segmentation/detection graphs but no saliency
model; a TFLite saliency model would be needed, and such models are trained on
natural images, not phone UIs. Because screen-content capture is a deliberate
exclusion, only **interaction** salience (§6) is in scope. (Note: raw audio
capture already invokes `MediaProjection`; screen capture rides the same token —
so the *capability* is near, but collecting screen content remains a separate,
larger IRB decision and is not part of this design.)

## 10. Privacy & IRB notes

- `audio_content` is the first `MEDIA_CONTENT` stream. It needs new participant
  consent language, a data-classification doc update (`docs/security/`), and a
  retention/deletion path. It ships `active = false` and default-disabled until
  that lands.
- `interaction_events` requires an Accessibility service — a sensitive
  capability — and explicit participant opt-in via its onboarding screen.
- `audio_activity` and `battery_telemetry` are metadata-class, comparable to the
  existing usage/lifecycle streams.
- All four remain per-study opt-in via §8; nothing privacy-sensitive is enabled
  implicitly — consistent with `CollectionDefaults`.

## 11. Open decisions

1. `audio_activity` privacy class — `BEHAVIORAL_METADATA` (proposed, parity with
   app-usage) vs. a stricter default-off class.
2. `audio_content` storage — object store vs. DB large-object; retention window.
3. `interaction_events` heatmap aggregation — on-device vs. server-side.
4. Outreach auto/approval default boundary — proposed: everything
   approval-required until a researcher opts a rule into automatic.

## 12. Build sequence

Each module follows the established migration-switch pattern (a `const val`
switch, parity-verified before flip).

1. chronicle-models — new `CollectionModuleId`s, `CollectionPrivacyClass`es,
   policy DTOs (+ tests).
2. `chronicle-api/chronicle.yaml` — new DTOs; regenerate web types.
3. `:collection-battery` — lowest risk, no new permission. Server table +
   migration.
4. `:collection-audio` — `audio_activity` first, then `audio_content` behind its
   `active = false` gate.
5. `:collection-interaction` — module + Accessibility onboarding screen.
6. chronicle-web — study-form migration to `AndroidDataCollectionSetting` +
   per-module config UI + Outreach section.
7. Feature D — compliance evaluator, Temporal escalation, dashboard at-risk panel.
8. Security guardrails — extend the `collection` layer in `run-all-security.sh`
   and the ast-grep rules to the new modules.
