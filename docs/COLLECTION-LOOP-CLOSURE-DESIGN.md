# Collection Loop Closure — Design

**Status:** Proposed (awaiting review) · **Date:** 2026-06-04
**Related:** `docs/SENSING-EXPANSION-DESIGN.md`, `docs/ANDROID-FEATURE-DELTA.md`,
the per-module config + immutable settings-audit work (chronicle-api PR#3,
chronicle-server PR#4, chronicle-web PR#102).

This is the **device-side counterpart** to the already-shipped server/web control
plane. The webapp can configure each `CollectionModuleId` per study (create + edit)
and every settings write is recorded in an immutable, module-granular audit trail —
but the enrolled Android app never reads that configuration, so today a toggle
changes a server record and **nothing on any participant's phone**. This design
closes that loop.

---

## 1. Current state — the loop is open

Verified 2026-06-04, primary-source:

- The app's entire network surface (`chronicle/app/.../api/ChronicleStudyApi.kt`)
  has exactly one settings method: `getAndroidSensorSettings()` →
  the **legacy** `AndroidSensorSetting` (`:95-98`). There is **no** method that
  fetches `AndroidDataCollectionSetting`.
- `CollectionSettingsResolver.resolveAll(generalized)` — the method that would
  apply the server's per-module config — has **zero** production call sites. The
  one `resolve(HARDWARE_SENSORS, generalized = null)` call
  (`SensorSettingsRefreshDelegate.kt:168`) always passes `null`.
- Collection modules gate on **enrollment + local prefs only**
  (`ParticipationStatus.ENROLLED`; local `isUserIdentificationEnabled()`),
  never a server `enabled` flag.
- Even `hardware_sensors` is inert via its per-module toggle: `buildSensorSetting`
  (web) keys only off `features` + `selectedSensors`, so toggling the module off
  still writes a non-empty legacy `AndroidSensorSetting`, which is the only thing
  the device reads → it keeps collecting.

**What already exists (de-risks the build):**

- The mobile-public serve endpoint: `GET /chronicle/v3/study/{id}/settings/type/DataCollection`
  (`StudyController.getStudySetting`), with a safe legacy fallback chain.
- The 6h poll worker (`SensorSettingsRefreshWorker`) — the guaranteed propagation
  mechanism (see push caveat below).
- An FCM scaffold that is **non-functional in this deployment**:
  `StudySettingsNotificationService.notifySettingsChanged(studyId)` (called at
  `StudyController.kt:437`) and the device subscribe/handler
  (`Enrollment.kt:256`, `ChronicleFirebaseMessagingService`) exist, but there is
  **no Firebase Admin service account**, so the server cannot publish — the call
  no-ops/logs a warning. Push is therefore **not** part of this design's
  implementation; propagation relies entirely on polling. The dormant FCM path is
  left in place (lights up for free if Firebase is ever provisioned), and a
  **self-hosted** push channel (no Google) is a fully viable future option —
  see **Appendix A**.
- The resolver itself (`CollectionSettingsResolver.resolveAll`, full 3-tier
  fallback) and the module registry (`CollectionModuleRegistry`, `CollectionModules`).

So most of the actuator scaffolding is present; this design mostly **wires it**
and adds the consent / disposition / acknowledgment pieces.

---

## 2. Goals & non-goals

**Goals**
- An enrolled device fetches `AndroidDataCollectionSetting` and gates each module on
  its `enabled` flag — live on **existing and new** enrollees.
- Disabling a module mid-study carries a researcher-chosen **disposition** for
  already-collected-but-unsent data.
- **Every** newly-enabled module requires explicit **participant acknowledgment**
  before it starts collecting.
- Changes propagate via **FCM push + 6h poll**, and the participant is **notified**
  on any collection-scope change. A per-participant **acknowledgment trail** is
  recorded server-side.

**Non-goals**
- No change to *what* each module collects or to upload formats.
- No change to the legacy `AndroidSensorSetting` path for old app builds (must keep
  working untouched).
- Reserved/inactive modules stay inactive; not in scope.

---

## 3. Locked decisions (from review)

1. **Close the loop** — build device-side consumption; live on existing + new enrollees.
2. **Mid-study OFF** — disposition specified **at the time of disabling** (per disable action).
3. **Toggle-ON** — require participant acknowledgment for **ALL** newly-enabled modules.
4. **Propagation** — the participant is notified on every scope change (a **local**
   app notification, no FCM). Since there is **no Firebase Admin service account**,
   server→device push is unavailable, so propagation is **poll-based** (tightened
   interval + piggyback on the existing upload work). Worst-case latency for "stop
   collecting now" = one poll interval, for an online device — see §5.5 / §11.
5. **Ack trail** — device **reports acknowledgments back**; recorded server-side (auditable).

---

## 4. End-to-end data flow

```
Researcher (web study edit)
  │  toggle module on/off; on OFF → pick disposition (flush/discard/hold)
  ▼
PATCH /chronicle/api/web/.../study/{id}/settings/type/DataCollection
  │   AndroidDataCollectionSetting{ modules{ id → {enabled, …, disableDisposition?} }, version }
  ▼
chronicle-server
  ├─ store in study.settings[DataCollection]
  └─ recordSettingsAuditDiff() → immutable, module-granular audit entry
        │
        │   (NO push — no Firebase Admin service account; device polls instead)
        ▼
Android app  (existing + new enrollees) — poll: piggyback on upload worker + periodic floor
  ├─ getDataCollectionSettings(studyId)  → AndroidDataCollectionSetting     [NEW]
  ├─ resolver.resolveAll(generalized = fetched)  → per-module resolved map  [WIRE]
  ├─ diff vs local applied state → transitions                             [NEW]
  │     • newly ENABLED  → mark pending-ack, DO NOT collect, notify +
  │                        in-app acknowledgment screen
  │     • newly DISABLED → act on disableDisposition (flush / discard / hold),
  │                        stop collecting
  ├─ persist resolved + ack state locally (Room)                           [NEW]
  └─ on participant acknowledge → start module + POST collection-ack        [NEW]
        ▼
POST /chronicle/v4/study/{id}/participant/{pid}/android/collection-ack      [NEW]
        ▼
chronicle-server → record participant-awareness entry (immutable)          [NEW]
        ▼
Web audit view shows both researcher changes and participant acknowledgments
```

---

## 5. Component changes

### 5.1 `chronicle-models` (shared)
- **New** `enum class CollectionDataDisposition { FLUSH_THEN_STOP, DISCARD_AND_STOP, HOLD_PENDING }`
  (lowercase `@JsonValue` wire ids, mirroring `CollectionModuleId` style).
- **Add** `disableDisposition: CollectionDataDisposition? = null` to
  `CollectionModuleSetting`. Set only when `enabled = false`; `null` (ignored) when
  enabled. Rides the existing settings object — **no new transport channel**. Old
  app builds ignore it (`@JsonIgnoreProperties(ignoreUnknown = true)` already on the
  DTO). Backward/forward compatible.
- Rationale for in-setting (vs a separate per-participant command): the device
  already polls/receives the whole setting; the disposition is a property of *this*
  disable event and the device clears its local effect once applied.

### 5.2 `chronicle-api` (`chronicle.yaml` + Kotlin `StudyApi`)
- **New** mobile endpoint
  `POST /chronicle/v4/study/{studyId}/participant/{participantId}/android/collection-ack`
  (device id via `X-Chronicle-Device-Id` header, API key via `X-Api-Key` — same auth
  as the other v4 android writes). Body: `CollectionAcknowledgment { acknowledgedModules: [CollectionModuleId], acknowledgedAt, appVersion? }`.
- **Add** `disableDisposition` to the `CollectionModuleSetting` schema; add
  `CollectionDataDisposition` enum + `CollectionAcknowledgment` schema.
- The mobile **read** endpoint (`getStudySetting` / `DataCollection`) is unchanged.
- Regenerate `chronicle-web` types (`bun run generate:api-types`).

### 5.3 `chronicle-server`
- **collection-ack controller + service**: validate study + participant, persist the
  acknowledgment, and record a participant-awareness entry. Storage: a dedicated
  **append-only** table `participant_collection_acknowledgment` (rhizome `Upgrade`
  class + `VNN__*.sql`, role-level `REVOKE DELETE, UPDATE` like V25), so the ack
  trail is as tamper-evident as the settings audit. The web audit feed surfaces acks
  alongside settings changes (union in the audit query or a sibling endpoint — see
  Open Questions §11).
- **No push work**: `notifySettingsChanged` stays as-is (dormant, no-ops without a
  Firebase Admin service account). No server change needed for propagation — the
  device polls. If Firebase is ever provisioned later, push becomes a free
  optimization on top of the poll.

### 5.4 `chronicle-web`
- **Disable-time disposition picker**: in `study-form-dialog.tsx`, when the user
  toggles a module from on→off, prompt for the disposition (flush / discard / hold);
  thread it into `buildDataCollectionSetting` so the written module entry carries
  `disableDisposition`. Default = `FLUSH_THEN_STOP` (no data loss) unless changed.
- **Audit page**: optionally render participant acknowledgments inline with the
  existing `changeSummary` rows (`study-settings-audit-page.tsx`).

### 5.5 `chronicle` (Android) — the core of the build
- **API**: add `getDataCollectionSettings(studyId): AndroidDataCollectionSetting` and
  `reportCollectionAck(...)` to `ChronicleStudyApi`.
- **Fetch wiring** (poll-based — no push): call `getDataCollectionSettings` at
  **enrollment**, **piggybacked on the existing upload worker** (so propagation
  tracks the upload cadence at ~no extra wake-ups), and on a **1h periodic floor**
  (tightened from 6h); feed the result into
  `resolver.resolveAll(generalized = fetched)` (replacing today's `generalized =
  null`). The dormant FCM `settings_updated` handler is also pointed at this fetch,
  so it contributes for free should push ever be provisioned — but is not relied on.
- **Local store** (`collection-base`, Room — new `CollectionModuleStateEntity`):
  per module → `{ serverEnabled, acknowledgedAt?, appliedVersion, lastDisposition? }`.
  This is the device's source of truth for gating and for computing transitions.
- **Transition engine** (pure Kotlin, JVM-testable): given previous local state +
  newly-resolved settings, produce a list of `ModuleTransition`
  (`NEWLY_ENABLED_NEEDS_ACK`, `NEWLY_DISABLED(disposition)`, `UNCHANGED`,
  `STILL_ENABLED_ALREADY_ACKED`). No Android types — thin adapters call it.
- **Gating**: each module holder's predicate becomes
  `enrolled && serverEnabled(id) && acknowledged(id)`.
- **Acknowledgment flow**: on `NEWLY_ENABLED_NEEDS_ACK`, post a participant
  notification and present an in-app acknowledgment screen listing the pending
  module(s) with human-readable descriptions + privacy class; the module stays **off**
  until the participant acknowledges; on acknowledge → persist `acknowledgedAt`,
  `POST collection-ack`, then start the module.
- **Disposition handling**: on `NEWLY_DISABLED`, apply the disposition to *that
  module's* local queue — `FLUSH_THEN_STOP` (drain/upload then stop),
  `DISCARD_AND_STOP` (drop unsent then stop), `HOLD_PENDING` (stop, retain queue) —
  then stop the module.
- **Scope-change notification**: any enable/disable transition posts a participant
  notification summarizing the change (decision 4).

---

## 6. Mid-study state machine (per module)

States: `INACTIVE` (server-disabled), `PENDING_ACK` (server-enabled, not yet
acknowledged — **not collecting**), `ACTIVE` (server-enabled + acknowledged —
collecting).

| From | Event | To | Side effects |
|------|-------|----|--------------|
| INACTIVE | server enables | PENDING_ACK | notify + show ack screen; **no collection** |
| PENDING_ACK | participant acknowledges | ACTIVE | persist ack; POST collection-ack; start module |
| PENDING_ACK | server disables again (before ack) | INACTIVE | dismiss ack prompt; nothing collected, nothing to dispose |
| ACTIVE | server disables (disposition D) | INACTIVE | apply D to queue; stop; notify |
| INACTIVE | server re-enables after a prior ack | PENDING_ACK | **re-ack required** (decision 3 = ALL newly-enabled) |
| any | unchanged config | same | none |

Edge cases:
- **Offline device**: no fetch → no transition; converges on next push/poll. Safe
  (collection only continues for already-ACTIVE modules).
- **New enrollee**: enrollment fetch yields the current config; newly-enabled
  modules start in PENDING_ACK exactly like existing enrollees.
- **Re-enable after ack**: a fresh ack is required every time a module goes
  INACTIVE→enabled (no "sticky" ack), matching decision 3.
- **Partial ack**: each module is acknowledged independently; acknowledging one
  doesn't start the others.

---

## 7. Privacy & consent semantics

- No module ever **persists** data without (a) the server enabling it **and** (b) the
  participant acknowledging it on-device. "Enabled without participant awareness" is
  prevented at the data-persistence chokepoint, not merely at a start/stop owner.
- **Device enforcement (where the gate physically lives).** Each module consults
  `CollectionGate.collects(ctx, <id>)` (fail-closed: any read error ⇒ no collection)
  at the point its data would be persisted:
  - **usage_events** — early-guard in `UsageModuleCollectionDelegate.monitorUsage`
    before polling/persisting.
  - **device_lifecycle / user_identification / battery_telemetry** — the module
    holder's collection seam is `enabled && CollectionGate.collects(...)`.
  - **hardware_sensors** — this one runs in a long-lived foreground service that
    legacy paths (`Enrollment`, `SensorSettingsRefreshWorker.doLegacyRefresh`,
    `MainActivity`) can start independently, so the gate is injected into
    `SensorRuntimeController` and consulted at the **persistence chokepoint**
    (`flushBuffer` drops the buffered batch while the gate is closed) **and** the duty
    cycle (no continuous-sensor registration while closed). The service may be started
    by a legacy path, but no sample reaches `sensor_samples` without acknowledgment —
    that is the structural guarantee, independent of who owns start/stop.
- **Ack scope = gated scope (no theater).** Only the five `CollectionGate`-gated modules
  above enter the PENDING_ACK lifecycle (`CollectionStateMachine.ACK_GATED_MODULES`). The
  operational modules — `upload_telemetry` (diagnostics), `sensor_availability` (device
  capability), `questionnaire` (local notification scheduling; the questionnaire is a web
  form) — are **excluded** from the acknowledgment screen even though their privacy classes
  default-enable them, because the acknowledgment does not gate them: listing them would
  imply a control that doesn't exist. They keep running under their own existing seams. The
  invariant is enforced in code: `ACK_GATED_MODULES` must equal the set of
  `CollectionGate.collects(...)` call sites (a unit test pins both).
- The acknowledgment is reported back and stored append-only, giving researchers a
  per-participant, tamper-evident record of *when each participant was made aware of
  and accepted* each module — useful for IRB/consent audit.
- **In-app fallback route.** If `POST_NOTIFICATIONS` is denied/dismissed, the local
  scope-change notification can't reach the participant; `MainActivity` therefore
  checks `pendingAcknowledgmentModules()` on open and routes to the acknowledgment
  screen (once per session, so "Not now" doesn't loop). Without this, a server-enabled
  module could sit PENDING_ACK — and so never collect — indefinitely.
- Disabling never silently strands collected data: the researcher chooses the
  disposition, and the default is no-loss (`FLUSH_THEN_STOP`).

### 7.1 Known caveats (honest scope)

- **DISCARD on a shared queue (and why the web picker hides it there).**
  `DISCARD_AND_STOP` does a true per-module drop only for modules with a **dedicated**
  queue: `battery_samples` (hardware ⇒ `sensor_samples`), `userQueue`
  (`user_identification`). `usage_events` and `device_lifecycle` share the `dataQueue`
  table with no per-module tag column, so a blanket clear would destroy the other
  (possibly still-enabled) module's pending rows. Critically, the upload worker drains
  `dataQueue` **module-blind** (`UploadWorkerDelegate` ships everything, then prunes by
  cursor), so *leaving* the rows is **not** a discard either — they upload on the next
  cycle, the exact inverse of what DISCARD means. Because neither "clear" nor "retain"
  can honor DISCARD for these two, the web disposition picker offers only
  `FLUSH_THEN_STOP` and `HOLD_PENDING` for `usage_events` / `device_lifecycle` — the two
  outcomes the device can actually keep (both ⇒ the already-collected rows still upload;
  they differ only in immediacy). DISCARD is offered only for the dedicated-queue
  modules. A per-module tag column on `dataQueue` is the follow-up that would make
  selective discard of the shared queue honorable. (Not in prod / no ongoing study.)
- **Idle sensor service notification — closed.** The per-sample persistence gate stops
  un-acknowledged *writes*, but on its own it would let a legacy start path
  (`StartOnBoot`, `PowerSaveModeReceiver`, `Enrollment`, ...) leave
  `HardwareSensorService` running with its foreground notification while the gate is
  closed and nothing is collected. `HardwareSensorService.onCreate` now re-checks
  `CollectionGate` off the main thread (the gate reads Room) once the foreground
  notification is up — the foreground-service contract requires `startForeground()`
  within ~5s, before the async gate read can complete — and `stopSelf()`s when
  `hardware_sensors` is not server-enabled-AND-acknowledged. So a gated start posts the
  notification only momentarily before the service stops itself, instead of leaving it up.
  `device_lifecycle` events are unaffected (their `DeviceLifecycleReceiver` is also
  registered, independently, by the always-on `DeviceUnlockMonitoringService`). The
  remaining residue is a sub-second notification flicker on a gated start attempt, the
  unavoidable cost of the `startForeground`-within-5s contract.

---

## 8. Backward compatibility & rollout

- **Old app builds** (no DataCollection fetch) keep working unchanged — they read
  only the legacy `AndroidSensorSetting`; the new `disableDisposition` field and the
  collection-ack endpoint are simply unused by them. No server change breaks them.
- The mobile read endpoint stays public + study-scoped (unchanged). The new
  collection-ack write is authenticated like the other v4 android writes.
- Model is forward-compatible (`ignoreUnknown`), so a server ahead of an app, or an
  app ahead of a server, both degrade safely.
- Protected-branch workflow: each submodule via PR + rebase-merge; bump root
  pointers; regenerate `gradle/verification-metadata.xml` only if dependencies
  change (they won't).

---

## 9. Testing strategy

- **JVM unit tests** (no device): the transition engine, disposition decisions, the
  ack state machine, and the `resolveAll` wiring — all pure/extractable. This is the
  bulk of the correctness surface.
- **Backend**: controller + service tests for collection-ack; audit recording;
  migration roundtrip for the new append-only ack table (mirrors V25); push-fires
  -on-DataCollection-change.
- **Web**: disposition-picker UI + `buildDataCollectionSetting` carrying
  `disableDisposition`; full `bun run check` gate; idempotent api-types.
- **On-device constraint (known blocker):** the `androidTest` path is destructive
  (wipes enrollment → emulator only) and the emulator SIGSEGVs in SwiftShader on
  this host. So end-to-end on-device verification is limited; I'll cover logic with
  JVM tests and do a best-effort manual smoke on the enrolled SM-T510 tablet where
  feasible, and explicitly call out anything not exercised on real hardware.

---

## 10. Build sequence

1. `chronicle-models`: `CollectionDataDisposition` + `disableDisposition` field (+ tests).
2. `chronicle-api`: schema additions + collection-ack endpoint (+ `StudyApi`), regenerate web types.
3. `chronicle-server`: ack table migration + Upgrade + controller/service + audit + push-on-DataCollection (+ tests).
4. `chronicle-web`: disposition picker + write path + audit surfacing (+ tests, full gate).
5. `chronicle` (Android): API + fetch wiring + local store + transition engine + gating + ack flow + disposition handling + notifications (+ JVM tests).
6. Root: bump submodule pointers; verify.

Each step is independently buildable/testable; the device step depends on 1–3.

---

## 11. Open questions / risks

- **Audit surfacing of acks**: union participant acks into the existing
  `getStudySettingsAudit` feed, or a sibling `…/settings/acknowledgments` endpoint?
  (Leaning: a sibling endpoint + the web page merges both — keeps the immutable
  settings-audit schema clean.)
- **Notification copy & ack-screen UX**: needs participant-facing wording; will draft
  and flag for review (this is consent-facing text).
- **HOLD_PENDING semantics**: held data sits in the local queue indefinitely until
  the module is re-enabled (and re-acked) or the disposition is later changed to
  flush/discard. Acceptable? (Leaning: yes, with a local cap so a held queue can't
  grow unbounded.)
- **Propagation latency (poll-only — chosen)**: **FCM** is unavailable (no Firebase
  Admin service account); **self-hosted push is possible but deferred** (see Appendix
  A). So polling is the chosen mechanism. Worst-case latency for a mid-study toggle
  (e.g. "stop collecting now") to reach a device = **one poll interval, and only
  while the device is online**. **Decided:** piggyback the settings fetch on the
  existing upload worker (propagation ≈ upload cadence, near-free) **plus** a **1h
  periodic floor** (tightened from 6h). Adding push later is purely additive — it
  changes only *when to fetch*, not the core loop.

---

## Appendix B — Participant-facing copy (DRAFT — needs sign-off)

This is **consent-facing wording** that goes on the on-device acknowledgment screen and
in the scope-change notification. It is a **draft for review** — IRB/study staff should
approve the exact wording before it ships. Placeholders in `{braces}`.

### Acknowledgment screen (shown when one or more modules need acknowledgment)
- **Title:** "Review what this study collects"
- **Intro:** "The study **{studyTitle}** would like to collect the following on this
  device. Collection does **not** start until you tap **I agree** below. You can review
  this at any time; if you have questions, contact your study team."
- **Per-module row:** "**{moduleLabel}** — {plain-language description}. ({privacyClass})"
  (e.g. "**Battery Telemetry** — your device's battery level and charging state. No
  personal content. (Device-state metadata)")
- **Primary button:** "I agree — start collection"
- **Secondary:** "Not now" (dismisses; modules stay off, nothing is collected)
- **Footer:** "Agreeing records the date and time of your acknowledgment with the study."

### Scope-change notification (a module was enabled or disabled mid-study)
- **Enabled (needs ack):** Title "Action needed: {studyTitle}". Body "A data collection
  option was added. Open the app to review and agree before it starts."
- **Disabled:** Title "{studyTitle} updated". Body "A data collection option was turned
  off. No action needed."

### Notes for the reviewer
- The "I agree" gate is **load-bearing**: with the absolute-ack decision, no module
  collects until the participant taps it, so this copy is the actual consent moment.
- Wording must match the study's IRB-approved consent language; the descriptions above
  are engineering placeholders, not approved consent text.

---

## Appendix A — Future direction: real server→device push (deferred)

This loop ships **poll-only** (decision above) to avoid new persistent-connection
infra. Real push is a known, ready option, captured here so it's a deliberate future
choice rather than a rediscovery. **Push only changes *when the device fetches* — the
fetch → `resolveAll` → gate → ack → disposition core is unchanged — so it is purely
additive on top of this design.** In every variant the **poll remains the guaranteed
floor**.

### What's blocked, and what isn't
- **FCM is the only thing actually blocked.** Its server-side send needs a Firebase
  Admin service account, which this deployment lacks. The dormant FCM path
  (`StudySettingsNotificationService.notifySettingsChanged` @ `StudyController.kt:437`;
  device subscribe `Enrollment.kt:256`; handler `ChronicleFirebaseMessagingService`)
  lights up with **no redesign** if a service account is ever provisioned.
- **Self-hosted push (no Google) is fully viable**, because the enabling pieces
  already exist:
  - **App host for a persistent connection:** `DeviceUnlockMonitoringService` is a
    `START_STICKY` foreground service (`foregroundServiceType="specialUse"`,
    `FOREGROUND_SERVICE_SPECIAL_USE`), and the app already prompts for battery-
    optimization exemption (`BatteryOptimizationExemptionDialog`).
  - **Backend:** Spring Boot (native `SseEmitter` / WebSocket) + Hazelcast already
    in-stack (`ITopic` for cross-instance fan-out, so a change applied on one server
    instance reaches devices connected to any instance) + Traefik passes WS/SSE
    through.

### Options (ranked)
1. **Self-hosted SSE (recommended).** The foreground service holds a long-lived
   authenticated `GET` (e.g. `/chronicle/v4/study/{id}/participant/{pid}/events`);
   server emits a minimal "settings changed" event → device runs the same
   `getDataCollectionSettings` fetch. One-way (device→server is already HTTP), least
   machinery, no new container. Reconnect via EventSource semantics; periodic
   heartbeat/comment lines to survive proxy idle reaping.
2. **Self-hosted WebSocket.** Same host/infra, bidirectional — could also carry the
   `collection-ack` upstream and device presence, not just settings pings.
3. **MQTT (self-hosted broker, e.g. Mosquitto/EMQX in the docker stack).** Most
   battery-efficient persistent push to a device fleet; cost = running + securing a
   broker.
4. **UnifiedPush + self-hosted ntfy.** Open push ecosystem, no Google; needs a
   distributor app on each device + ntfy infra.

### Implementation deltas vs poll-only
- **Backend:** a streaming endpoint + a per-device/per-study connection registry +
  Hazelcast `ITopic` fan-out keyed by study; emit on the same `recordSettingsAuditDiff`
  trigger that already exists.
- **Android:** a persistent-connection client owned by the foreground service, with
  exponential-backoff reconnect + heartbeat; on event → the existing fetch path.
- **Core loop:** unchanged.

### Honest caveats
- Persistent-connection push is **best-effort under Doze / OEM battery management on
  personal phones** — exactly the problem FCM's OS-privileged channel exists to solve.
  It is reliable on **managed, battery-exempt, power/Wi-Fi devices** (this app's
  typical deployment). The poll floor covers the gap either way.
- Long-lived connections traverse **F5 → Traefik → backend**; confirm proxy idle
  timeouts and send periodic heartbeats so an idle stream isn't reaped (this
  deployment's F5 path is sensitive to such settings).
