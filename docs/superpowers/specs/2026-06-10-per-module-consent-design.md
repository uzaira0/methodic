# Per-Module Consent & "Data Sharing" Management — Design

**Date:** 2026-06-10
**Status:** Approved design (pre-implementation)
**Supersedes:** the in-flight "Not now" / deferred-event increment on the single
`CollectionAcknowledgmentActivity` consent screen.
**Builds on:** `docs/COLLECTION-LOOP-CLOSURE-DESIGN.md` (the collection loop,
`CollectionStateMachine`, the server consent trail) and
`docs/DATA-COLLECTION-MODULARIZATION-DESIGN.md` (per-module settings).

---

## 1. Goal

Replace the current single, all-at-once "I agree / Not now" consent screen with a
modern, per-module consent model that matches how mainstream apps onboard:

1. **Study config marks each collection module Required or Optional.**
2. **Enrollment becomes a guided one-screen-per-module orientation wizard** that
   explains, for each study-enabled module, *what it collects* and *what it does
   not* — Required modules first (declining blocks enrollment), Optional modules
   after (declining is confirmed against mistaps, then proceeds).
3. **The server is told which modules each participant accepted and which they
   declined** — at enrollment and on every later change.
4. **A persistent "Data Sharing" tab** lets the participant turn Optional modules
   on/off at any time; Required modules are shown locked ("uninstall the app to
   stop this").
5. **Mid-study setting changes flow to the device automatically** through the
   existing settings-sync + `reconcile()` path: a module becoming Required,
   Optional, or no-longer-collected produces the correct participant-facing
   outcome without bespoke wiring per module.

This is an **evolution** of the existing collection loop, not a rewrite: the
state machine, settings resolver, coordinator, store, gate call-sites, and
consent-before-enroll ordering are all retained and extended.

---

## 2. Current state (what exists today)

- `CollectionModuleSetting` (chronicle-models) holds `enabled` + cadence/battery/
  network/sensor policy + `disableDisposition`. **No `required` flag.**
- `AndroidDataCollectionSetting` carries a `Map<CollectionModuleId,
  CollectionModuleSetting>` + `version` (currently `1`). Polymorphic `StudySetting`
  subtype, tolerant deserialization (unknown module IDs/fields dropped).
- `CollectionModuleState` (collection-core) derives a 3-value `phase`
  (`INACTIVE / PENDING_ACK / ACTIVE`) from two booleans: `serverEnabled` and
  `acknowledged` (`acknowledgedAtEpochMillis != null`). **No "declined" state.**
  Consent is implicitly a single positive acknowledgment, never a decline.
- `CollectionStateMachine` is a pure engine with two entry points: `reconcile()`
  (server-driven: resolved settings vs. persisted state, per `settingVersion`) and
  `acknowledge()` (participant-driven). `ACK_GATED_MODULES` = `{usage_events,
  device_lifecycle, hardware_sensors, user_identification, battery_telemetry}`.
  Gate to collect = `serverEnabled && acknowledged`.
- `CollectionLoopCoordinator.sync()` fetches public settings, resolves, reconciles,
  persists to `CollectionLoopStore`, and posts a single notification on `NEEDS_ACK`.
  `CollectionAcknowledgmentActivity` is the one screen listing all pending modules;
  "I agree" calls `coordinator.acknowledge(...)` → `reportCollectionAck` (v4).
- Server consent trail: append-only `participant_collection_acknowledgment` table +
  `ParticipantCollectionAcknowledgmentService.recordAcknowledgment(...)`, exposed via
  `CollectionAcknowledgment` DTO and the `reportCollectionAcknowledgmentV4` endpoint
  (`/chronicle/v4/study/{studyId}/participant/{participantId}/android/collection-ack`).
  Records **accepted** modules only.
- chronicle-web study form lists modules via `COLLECTION_MODULES` (`study-constants.ts`)
  and toggles each module's `enabled`.

---

## 3. Data model changes (chronicle-models)

### 3.1 `CollectionModuleSetting.required`

Add one additive field:

```kotlin
val required: Boolean = false,
```

Defaults to `false` (Optional). Backward compatible: old clients ignore it
(`@JsonIgnoreProperties(ignoreUnknown = true)`); a study that never sets it keeps
every module Optional. `required` is only meaningful when `enabled == true`.

### 3.2 `AndroidDataCollectionSetting.CURRENT_VERSION`

Bump `1 → 2` to mark the schema evolution. Reads stay tolerant; the version is
informational (the device already diffs by `settingVersion`).

### 3.3 Server consent-trail DTO

Generalize the consent report from "accepted modules" to a **per-module decision
snapshot**. Extend `CollectionAcknowledgment` (chronicle-models) additively:

```kotlin
val acknowledgedModules: Set<CollectionModuleId>,        // = ACCEPTED (existing)
val declinedModules: Set<CollectionModuleId> = emptySet(), // NEW
val trigger: ConsentTrigger = ConsentTrigger.ENROLLMENT,   // NEW
val acknowledgedAt: OffsetDateTime,
val appVersion: String? = null,
```

`ConsentTrigger` (new enum): `ENROLLMENT`, `PARTICIPANT_TOGGLE`,
`SETTINGS_CHANGE`, `WITHDRAWAL`. Relax the current
`require(acknowledgedModules.isNotEmpty())` to require **at least one** of
`acknowledgedModules`/`declinedModules` non-empty (a pure-decline report is valid).
`CollectionAcknowledgmentEntry` (the persisted server-side shape) gains the same
`declinedModules` + `trigger`.

A snapshot is the participant's decision **at that moment** for the modules in
play (not necessarily all modules) — diffable into a full history by the server.

---

## 4. Participant decision states & state machine (collection-core)

### 4.1 `CollectionModuleState`

Replace the single `acknowledgedAtEpochMillis: Long?` with an explicit tri-state
decision plus the required-flag last applied (so `reconcile` can detect
Required↔Optional flips):

```kotlin
val decision: ParticipantDecision,        // UNDECIDED | ACCEPTED | DECLINED
val decidedAtEpochMillis: Long?,          // when the decision was last set
val requiredApplied: Boolean,             // `required` from the last version applied
```

`ParticipantDecision` (new enum): `UNDECIDED`, `ACCEPTED`, `DECLINED`.

Phase derivation becomes:

| serverEnabled | decision | phase |
|---|---|---|
| false | (any) | `INACTIVE` |
| true | `ACCEPTED` | `ACTIVE` |
| true | `DECLINED` | `DECLINED` |
| true | `UNDECIDED` | `AWAITING_DECISION` |

`collectsWhenEnrolled = serverEnabled && decision == ACCEPTED`.

`CollectionModulePhase` becomes `{ INACTIVE, AWAITING_DECISION, ACTIVE, DECLINED }`
(`PENDING_ACK` → `AWAITING_DECISION`; `DECLINED` is new). The gate invariant is
unchanged in spirit: **no module collects without `serverEnabled` AND an explicit
`ACCEPTED`.**

**Room migration:** existing persisted rows map `acknowledgedAtEpochMillis != null`
→ `ACCEPTED` (carry the timestamp), `null` + enabled → `UNDECIDED`,
`requiredApplied = false` (every legacy module was Optional). Append a Room
schema-version migration; do not wipe state (preserves enrollment + active modules
on upgrade).

### 4.2 `ResolvedModuleSetting`

Add `val required: Boolean get() = setting.required` (mirrors the existing
`enabled` convenience). No resolver logic change beyond carrying the flag.

### 4.3 `CollectionStateMachine`

**`reconcile()`** now diffs `(enabled, required)` from `resolved` against
`(serverEnabled, requiredApplied, decision)` from `previous`, emitting the
transition set in §5. `ACK_GATED_MODULES` is unchanged (consent still applies to
exactly the gated modules). The construction invariant holds: a server enable
alone never yields `ACTIVE` — only an explicit `ACCEPTED` decision does.

**`acknowledge()` → `decide()`** generalizes the participant entry point:

```kotlin
fun decide(
    previous: Map<CollectionModuleId, CollectionModuleState>,
    decisions: Map<CollectionModuleId, ParticipantDecision>, // ACCEPTED | DECLINED
    nowEpochMillis: Long,
): DecisionResult   // newStates + activated:Set + deactivated:Set
```

`ACCEPTED` on an `AWAITING_DECISION`/`DECLINED` module → `ACTIVE` (activated).
`DECLINED` on an `ACTIVE`/`AWAITING_DECISION` Optional module → `DECLINED`
(deactivated; collection stops). Idempotent on no-op transitions. Required modules
cannot be set to `DECLINED` via `decide()` from the management surface (guarded);
declining a Required module only happens through the mandatory mid-study/enrollment
path, which routes to withdrawal, not a `DECLINED` state.

---

## 5. Mid-study reconcile matrix (the setting-change wiring)

For each gated module, `reconcile()` maps `(previous decision/required)` ×
`(new enabled/required)` to one transition. New intent is derived as:
**Required** = `enabled && required`; **Optional** = `enabled && !required`;
**Not collected** = `!enabled`.

| prev decision ↓ \ new intent → | Required | Optional | Not collected |
|---|---|---|---|
| **ACCEPTED** (ACTIVE) | `STILL_ACTIVE`; if was Optional → `NOW_REQUIRED_INFORM` (lock toggle, gentle notice) | `STILL_ACTIVE`; if was Required → `NOW_OPTIONAL_INFORM` (unlock, "you may turn off") | `FORCIBLY_DISABLED` (gate off, apply disposition, inform) |
| **DECLINED** | `NEWLY_REQUIRED_NEEDS_CONSENT` (mandatory: Accept or Leave study) | `STILL_DECLINED` (no change) | `FORCIBLY_DISABLED` (already off; clear, optional notice) |
| **UNDECIDED / new** | `NEWLY_REQUIRED_NEEDS_CONSENT` (mandatory) | `NEEDS_DECISION` (notify; not collected until accepted) | `UNCHANGED_INACTIVE` (drop the pending ask) |

### 5.1 Resulting `ModuleTransitionType` set

Retained / renamed: `UNCHANGED_INACTIVE`, `STILL_ACTIVE`,
`NEEDS_DECISION` (was `NEEDS_ACK`), `STILL_AWAITING_DECISION` (was
`STILL_PENDING_ACK`), `FORCIBLY_DISABLED` (folds `DISABLED_AFTER_ACTIVE` +
`DISABLED_BEFORE_ACK`; still carries `disposition` when the prev phase was ACTIVE).

New: `STILL_DECLINED`, `NEWLY_REQUIRED_NEEDS_CONSENT`, `NOW_REQUIRED_INFORM`,
`NOW_OPTIONAL_INFORM`.

### 5.2 Three confirmed judgment calls

1. **Halt ALL collection only on an EXPLICIT decline of a required module
   (reversible); grace window for undecided.** *(Implementer decision 2026-06-11,
   superseding both the earlier "Accept / Leave the study + withdraw primitive"
   design and an interim "halt on any not-accepted" reading.)* When the study makes a
   module required:
   - **Undecided (grace window):** already-accepted modules **keep collecting**; only
     the newly-required module itself does not collect (it isn't accepted). The
     participant is prompted to Accept or Decline. No global halt yet.
   - **Explicitly declined:** the device collects **nothing** — not even
     already-accepted modules — until the module is re-accepted.
   There is **no withdraw primitive** and no enrollment clear: declining makes the app
   go silent (the researcher infers withdrawal from the data stopping), and the
   participant can re-accept in Data Sharing at any time to resume — reversible, no
   reinstall. The halt is *derived* from module state
   (`any { serverEnabled && requiredApplied && decision == DECLINED }`), so it is
   intrinsic to `CollectionGate.collects(...)` and every collection site honors it
   automatically; it lifts the instant the required module is re-accepted.
2. **Required→Optional keeps the module ON by default**; the participant *gains*
   the ability to turn it off (one-time notice), rather than being re-prompted.
3. **→Not-collected is informational only** (no consent needed to stop) and still
   honors the researcher's `disableDisposition` for the on-device queue.

Only transitions that record a **participant decision** write to the consent
trail: accepting **or declining** a `NEWLY_REQUIRED_NEEDS_CONSENT` module
(`trigger = SETTINGS_CHANGE`, the decline carried in `declinedModules`) and deciding
a `NEEDS_DECISION` module (`trigger = PARTICIPANT_TOGGLE`). So a mid-study required
decline *is* reported (one explicit trail row) and then the device goes silent;
`WITHDRAWAL` stays a reserved trigger value, unused by this reversible flow. The
**informational** transitions
(`NOW_REQUIRED_INFORM`, `NOW_OPTIONAL_INFORM`, `FORCIBLY_DISABLED`) are
server-initiated scope changes the server already knows about — they update local
state and surface a notice, but do **not** post a trail row (and so never produce
an empty accepted+declined report).

---

## 6. Enrollment orientation wizard (Android)

After the participant enters study + participant ID, the app fetches the study's
`DataCollection` settings (existing public unauthenticated GET) — **no server
enroll yet** (consent-before-enroll preserved). It then runs a wizard:

- **One screen per study-enabled gated module.** Order: all **Required** modules
  first, then all **Optional** modules. Screens are generated from the per-module
  template (§8): title, *what it collects*, *what it does NOT collect*, privacy
  class, and **Accept / Decline**.
- **Required + Decline** → confirm screen "You can't take part without this." If
  still declined → **enrollment aborts** (nothing enrolled; return to start).
  Accept → next.
- **Optional + Decline** → confirm screen "Decline this? (in case of a mistap)" →
  either choice proceeds (declined = not collected).
- **After the last screen:** enroll on the server, seed `CollectionLoopStore` from
  the decisions (`ACCEPTED` → ACTIVE, `DECLINED` → DECLINED), and report the
  per-module decision snapshot (`trigger = ENROLLMENT`).

If the study enables **zero** gated modules, the wizard is skipped (enroll
directly), matching today's behavior for usage-only-disabled studies.

New activity (e.g. `CollectionOrientationActivity`) hosting a stepper over a
single reusable per-module screen. The current `Enrollment` consent dialog and
`CollectionAcknowledgmentActivity` are retired (their roles move here and to §7).

---

## 7. "Data Sharing" management tab (Android)

The existing **Sensors** bottom-nav tab becomes **Data Sharing** (still four tabs:
Overview · Uploads · Data Sharing · Settings). It is a container with two sections:

- **App & Device Usage** — `usage_events`, `device_lifecycle`, `battery_telemetry`,
  `user_identification`.
- **Sensors** — `hardware_sensors` (the existing sensor UI moves in as a section).

Each row shows the module label + short description and:

- **Optional, enabled:** a working toggle. Flipping it calls `decide(...)`
  (`ACCEPTED` ↔ `DECLINED`), opens/closes the gate, and reports the change
  (`trigger = PARTICIPANT_TOGGLE`).
- **Required + accepted:** a locked control reading "Required — collecting.
  Uninstall the app to stop" (steady-state withdrawal stays an OS uninstall — no
  self-withdraw button on a routine settings screen).
- **Required + undecided** (mid-study addition, grace window): a consolidated
  **attention list** at the top of the tab offers **Accept** and **Decline** for
  each. Already-accepted modules keep collecting; the row reads "Required — accept
  above to start sharing." No banner yet (not halted).
- **Required + declined** (the participant declined → global halt): a "collection
  paused" banner at the top, and the attention row offers **Accept** (to resume).
  The inline row reads "Declined — all collection paused."
- **Not collected by the study:** shown disabled/greyed as "not collected by this
  study", no toggle.

`AWAITING_DECISION` modules (mid-study additions) appear in the attention list as
above. The Overview "Collection status" card keeps its tap-through, now pointing at
the Data Sharing tab instead of the retired ack screen.

**Mandatory mid-study consent** (`NEWLY_REQUIRED_NEEDS_CONSENT`): a high-priority
notification ("A data type is now required — accept it, or declining pauses all
collection") deep-linking to the Data Sharing tab, where the attention list presents
**Accept / Decline**. There is **no blocking full-screen and no Leave-the-study
button** — the reversible global halt (§7.1) is the enforcement.

### 7.1 Mid-study required halt (reversible, explicit-decline, no withdraw primitive)

When the study makes a module required, the device does not unenroll or clear any
local state. The halt is gated on an **explicit decline**, with a grace window for
the undecided:

1. **Grace window (undecided):** already-accepted modules **keep collecting**; the
   newly-required module itself does not collect until accepted. Reconcile emits
   `NEWLY_REQUIRED_NEEDS_CONSENT` and prompts (notification + attention list). No
   global halt.
2. **Global halt (declined):** `CollectionGate.collects(moduleId)` returns false for
   **every** module while `CollectionModuleStateDao.countRequiredDeclined() > 0` (any
   enabled+required module the participant explicitly `DECLINED`). The halt is
   intrinsic to the gate, so every seam, worker, and self-gating service honors it
   with no separate flag. `decide()` permits declining a required module (the only
   surface that offers it is the attention list's **Decline**); reconcile preserves a
   declined-required module as `STILL_DECLINED` so a later settings poll does not
   silently lift the halt.
3. **Resume** — accepting in the attention list reports `trigger = SETTINGS_CHANGE`,
   flips the module to `ACCEPTED`, drops `countRequiredDeclined()` to zero, and lifts
   the halt — collection resumes immediately (the coordinator re-evaluates the
   hardware-sensor service against the effective gate so an already-accepted sensor
   module restarts too).
4. **No server report for the refusal itself beyond the decline row** — declining
   posts a per-module `declinedModules` consent-trail row (`trigger = SETTINGS_CHANGE`);
   beyond that the app simply goes silent. There is no `WITHDRAWAL` trail row and no
   server-side unenroll call (participant removal/purge stays the researcher's
   `deleteStudyParticipants`, unchanged).

Steady-state required modules (accepted at enrollment) are still stopped only by
uninstalling the app. Both paths leave server-side enrollment intact; they differ
only in framing.

**`user_identification` note:** it is a normal gated module here — its holder
consults `CollectionGate.collects(...)`, so accept/decline controls its gate like
the other four. "Preference-driven" describes only its collection *trigger*
(`setTargetUser()`), not its gate, so it fits the `decide()` model unchanged.

**Informational notices** (`NOW_REQUIRED_INFORM`, `NOW_OPTIONAL_INFORM`,
`FORCIBLY_DISABLED`): a notification, deep-linking to Data Sharing where the row's
lock state / presence already reflects the change. `NOW_*_INFORM` post a "Data
collection updated" notice ("now required, can't be turned off" / "now optional,
you may turn it off"); `FORCIBLY_DISABLED` posts the existing "turned off" notice.
No participant action required.

---

## 8. Per-module copy templates

Extend `CollectionConsentCopy` from a flat label/description map into a structured
template per gated module:

```kotlin
data class ModuleTemplate(
    val label: String,
    val whatItCollects: List<String>,     // bullet points
    val whatItDoesNotCollect: List<String>, // bullet points — the new "and what it doesn't"
    val privacyClass: String,
)
```

Copy is **app-canonical** (pre-specified, consistent across studies), not study-
authored — the study only enables + marks Required. The same templates feed the
enrollment wizard, the Data Sharing rows, and the mid-study screens. Wording stays
mirrored to chronicle-web's `COLLECTION_MODULES` so researchers and participants see
matching language; final consent wording remains the study/IRB's responsibility.

---

## 9. Server consent trail (chronicle-server + chronicle-api)

- **Migration V27** (next after V26, append-only): add `declined_modules` and
  `trigger` columns to `participant_collection_acknowledgment`; keep the V26
  DELETE/UPDATE revokes so the trail stays append-only.
- `ParticipantCollectionAcknowledgmentService.recordAcknowledgment(...)` extended to
  persist `declinedModules` + `trigger`. `getAcknowledgments(...)` returns them so
  researchers can see, per participant, exactly which modules were accepted/declined
  and when, across enrollment and every change.
- `StudyController.reportCollectionAcknowledgmentV4` accepts the extended payload
  (same endpoint/path; additive fields). Audit logging unchanged in shape.
- **chronicle-api** `chronicle.yaml`: extend the `CollectionAcknowledgment` and
  `CollectionAcknowledgmentEntry` schemas with `declinedModules` + `trigger`;
  regenerate web types (`bun run generate:api-types`) — contract drift gate must
  stay green.
- **No new server-side withdraw/unenroll endpoint.** A `WITHDRAWAL`-triggered report
  is an audit/notification record only (§7.1); it does not deactivate the
  participant server-side. Researcher-side removal remains `deleteStudyParticipants`.

---

## 10. Web study form (chronicle-web)

For each enabled module in the study DataCollection form, add a **Required**
toggle (writes `required` into that module's `CollectionModuleSetting`). Default
off (Optional). Surface the per-module "what it collects / doesn't" copy alongside
so researchers configure with the same language participants see. The researcher-
facing consent-trail view (existing acknowledgments read) is extended to show
declines and the trigger.

---

## 11. Surfaces & dispatch (CollectionLoopCoordinator)

`sync()` keeps its shape: fetch → resolve → `reconcile()` → persist → dispatch.
`dispatch()` is extended to route each transition type to its surface:

| transition | surface |
|---|---|
| `NEEDS_DECISION` | notification + Data Sharing "Review" badge |
| `NEWLY_REQUIRED_NEEDS_CONSENT` | high-priority notification + blocking single-module screen on foreground |
| `NOW_REQUIRED_INFORM` / `NOW_OPTIONAL_INFORM` / `FORCIBLY_DISABLED` | notification + one-time Data Sharing banner |
| `STILL_ACTIVE` / `STILL_DECLINED` / `STILL_AWAITING_DECISION` / `UNCHANGED_INACTIVE` | no surface |

The existing first-enrollment suppression (don't notify when `previous.isEmpty()`)
is preserved — enrollment decisions come from the wizard, not notifications.
Notification copy/visibility carries the dark-mode + visible-button fixes already
made for the consent screen.

---

## 12. Build sequence (phased)

1. **Model + state machine + server trail** — `required` flag (models), tri-state
   decision + `DECLINED` + new transition types + `decide()` (collection-core) with
   the Room migration; V27 + service/endpoint/OpenAPI consent-trail extension.
   Fully JVM-/contract-testable before any UI.
2. **Enrollment orientation wizard** — the per-module screen + stepper; retire the
   old enrollment consent dialog.
3. **Data Sharing tab** — container with App & Device Usage + Sensors sections;
   toggles, locked-Required rows, mid-study mandatory/optional/informational
   surfaces; retire `CollectionAcknowledgmentActivity`.
4. **Web study form** — Required/Optional per module + extended trail view.

Each phase is independently buildable/testable; phase 1 is the contract every other
phase depends on.

---

## 13. Testing

- **collection-core (JVM):** exhaustive `reconcile()` matrix tests (every cell of
  §5), `decide()` activation/deactivation, the Required-decline guard, and the Room
  migration mapping. Extend the existing `CollectionStateMachineTest`.
- **chronicle-models / contract:** serialization round-trip for `required`,
  `declinedModules`, `trigger`; `DataCollectionSettingContractTest` updates.
- **chronicle-server:** `ParticipantCollectionAcknowledgmentService` accept+decline
  persistence + append-only enforcement; `StudyController` endpoint accepts the
  extended payload.
- **chronicle-api:** `check:api-types` (no drift).
- **chronicle-web:** study-form Required toggle unit/component tests.
- **On-device QA:** drive the full enrollment wizard + each mid-study transition on
  the existing prod test study against the SM-X210 / Pixel / Fire tablets (the same
  rig used for the collection-loop QA), verifying gate behavior and the server trail.

---

## 14. Non-goals / out of scope

- No new transport channel — all settings (incl. `required`) ride the existing
  `DataCollection` study setting and public GET; all decisions ride the existing v4
  consent endpoint.
- No change to the non-gated operational modules (`upload_telemetry`,
  `sensor_availability`, `questionnaire`) — they remain ungated and out of the
  consent surface.
- No per-sensor (sub-module) opt-out — consent stays at module granularity.
- TUD/Survey/Questionnaire web flows are untouched.
- No auto-withdrawal automation beyond the explicit participant *Leave the study*
  tap.

---

## 15. Open items

None blocking. The container tab label is **"Data Sharing"** (adjustable at
implementation without design impact). Exact per-module "what it doesn't collect"
bullet wording is finalized during phase 2 against the IRB-reviewed language.
