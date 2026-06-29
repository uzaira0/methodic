# methodic-labs Backwards Feature-Parity Audit

**Date:** 2026-06-03
**Direction:** *backwards* parity only — does the `uzaira0/*` fork still do everything the
upstream `methodic-labs/*` version does? (Fork-only additions are out of scope.)
**Baselines:** upstream `develop` tips, shallow-cloned 2026-06-03 —
chronicle-web `73f9d3d`, chronicle-server `a7cbc1f`, chronicle-api `35f9ded`,
chronicle (Android) `e31f21b`. `chronicle-models`/`rhizome`/`rhizome-client` have **no**
upstream repo (their shared model/enum code is compared against where it lives inside
upstream's chronicle-api / chronicle-server / Android app).

**Method:** five independent auditors, each enumerating the upstream surface *fresh* and
reporting what it could **not** find *wired* in the fork (negative findings, evidence on
both sides). The prior `PARTICIPANT-FORMS-AND-PARITY.md` was deliberately **not** used as a
frame — its "all frontend gaps closed" claim was treated as a claim to re-test, not a fact.
"File exists" was never accepted as parity; each fork equivalent was checked for being
actually registered/reachable (route mounted, endpoint wired, collector scheduled).

---

## Verdict

**Two genuine backwards regressions were found and BOTH ARE NOW CLOSED (2026-06-03).** Both
were the same class: a *study-setting-driven variant* that upstream applies automatically had
been collapsed in the fork to a single path / a manual URL flag, so a study configured for the
variant silently served the wrong form. The fix in each case makes the study's configured
setting authoritative (read from a new participant-readable endpoint), keeping the fork's URL
params as a manual override. See **Resolution** below.

| # | Surface | Regression | Severity | Status |
|---|---------|-----------|----------|--------|
| **R1** | chronicle-web | **Hourly app-usage survey variant not ported** — survey route is daily-only; `appUsageFreqType` never read. | Live, conditional | **CLOSED** |
| **R2** | chronicle-web | **TUD web ignores `TimeUseDiarySettings`** — OSU / Sherbrooke / clockFormat / clockFormatLocked / language honored only via URL query params, not the study's configured settings. | Live, conditional; OSU/Sherbrooke change the clinical instrument | **CLOSED** |

Everything else is at parity or fork-ahead. All other upstream/fork deltas are either
fork-additive (superset) or **documented intentional divergences**. One **authorization
nuance** (not a feature regression) is flagged for the security owner.

## Resolution (2026-06-03)

Both regressions are closed. Each fix adds a **participant-readable backend endpoint** that
exposes the relevant (non-sensitive) study setting, plus a frontend read that makes the
configured setting authoritative (URL params retained as a manual override). The new endpoints
are unauthenticated/`permitAll` — consistent with the existing participant survey/TUD endpoints
and strictly less sensitive than the app-usage *data* already exposed there.

**R1 — hourly survey**
- Backend: `GET /chronicle/v3/survey/{studyId}/app-usage-frequency` → flat
  `AppUsageFrequencyResponse` (`SurveyController.getAppUsageFrequency`); reads
  `ChronicleDataCollectionSettings.appUsageFrequency` (default DAILY); one `permitAll` line added
  (`ChronicleServerSecurityPod`). `SurveyApi` + `chronicle.yaml` + generated web types updated.
- Frontend: `useGetAppUsageFrequencyQuery`; `survey-page.tsx` branches DAILY vs HOURLY (load-gate;
  error → daily). New `ParticipantHourlySurveyForm` is a faithful port of upstream `HourlySurvey`
  with the wizard/bucketing/submission logic in a pure, unit-tested core (`hourly-survey-core.ts`):
  hour-bucketing in the record's timezone, the child-only / shared / resolve-primary /
  resolve-remaining steps, and the `users: ['Target Child']` submission. (Fixes upstream's lexical
  bucket-sort bug as a side benefit.)
- Tests: backend `SurveyControllerTest` (+2: HOURLY→HOURLY, absent→DAILY); web
  `hourly-survey-core.test.ts` (12).
- **Persistence verified (not just mocked):** the only concrete type ever written to the
  `StudySettingType.DataCollection` slot is `ChronicleDataCollectionSettings` (via
  `setChronicleDataCollectionSettings` + `StudyLimitsUpgrade`); `AndroidDataCollectionSetting`
  is only a read-side `fromLegacy` fallback, never persisted. `DtoSerializationTests` (+assert)
  confirms that slot round-trips via `@class` back to a concrete `ChronicleDataCollectionSettings`
  with `appUsageFrequency` intact, and `OrganizationTests` does a real set/get HOURLY round-trip —
  so the reader's `as? ChronicleDataCollectionSettings` cast resolves HOURLY for configured studies.

**R2 — TUD reads `TimeUseDiarySettings`**
- Backend: `GET /chronicle/v3/time-use-diary/{studyId}/settings` → flat
  `TimeUseDiarySettingsResponse` (`TimeUseDiaryController.getTimeUseDiarySettings`); already
  `permitAll` (TUD GET tree). `TimeUseDiaryApi` + `chronicle.yaml` + generated web types updated.
- Frontend: `useGetTimeUseDiarySettingsQuery`; `time-use-diary-page.tsx` seeds `TudSettings` and
  base language from the study setting (load-gate; error → URL/defaults) via the pure
  `resolveTudSettings`/`resolveBaseLang` (`tud-page-settings.ts`); URL params override when present.
- Tests: backend `TimeUseDiaryControllerTest` (+2: configured→projected, absent→defaults); web
  `tud-page-settings.test.ts` (13).

**Verification:** chronicle-server `:chronicle-server:test` = 1244 tests, 0 failures (JDK 21).
chronicle-web `typecheck` + `biome` (211 files) + `lint:ast` + `test` (3167) + `test:components`
(188) all green; `generate:api-types` regenerated (the generated diff is exactly the four new
operations/schemas). **Security note:** R1 adds one new unauthenticated `permitAll` GET — flagged
for the security owner, though it follows the existing participant-endpoint pattern and exposes
only the DAILY/HOURLY flag.

Both regressions share a root cause and were invisible to existence-level checks (the survey
and TUD **routes are mounted and wired**; only the *settings-gated sub-variant* is missing).
The prior `PARTICIPANT-FORMS-AND-PARITY.md` marked these "closed" because it verified the
URL-param path, not the study-settings path.

---

## R1 — Hourly app-usage survey (web) — CONFIRMED REGRESSION

Upstream's app-usage survey has **two variants**, selected by the study setting
`DataCollection → APP_USAGE_FREQUENCY`:

- `DailyAppUsageSurvey` (default) — apps grouped by package.
- `HourlyAppUsageSurvey` → `HourlySurvey` — apps **bucketed into hourly time ranges**
  (`getTimeRange(dateTime)`), submitted with `appUsageFreqType: HOURLY`.

Branch point: `upstream/src/containers/survey/SurveyContainer.js:84`
(`if (appUsageFreqType === AppUsageFreqTypes.HOURLY)`); the saga groups the same
`getAppUsageSurveyData` response into hour buckets client-side
(`sagas/getAppUsageSurveyData.js:58`).

**The fork backend fully supports HOURLY** — so this is a live, reachable configuration,
not a dead setting:
- `chronicle-models/.../settings/AppUsageFrequency.kt:6-9` → `{ DAILY, HOURLY }`
- `chronicle-api/.../organizations/OrganizationSettings.kt:15` →
  `appUsageFrequency: AppUsageFrequency = DAILY`
- `ChronicleDataCollectionSettings(AppUsageFrequency.HOURLY)` is a valid study setting
  (`chronicle-server/.../util/tests/TestDataFactory.kt:75`); referenced by
  `StudyLimitsUpgrade.kt:171`, `StudySettingsUpgrade.kt`, etc.

**The fork web never reads it.** `rg 'appUsageFreqType|AppUsageFrequency|hourly'
chronicle-web/src/modern` → **no matches**. `participant-survey-form.tsx` (210 lines) is
annotated *"verbatim from upstream methodic-labs daily app-usage survey"* and renders the
daily variant unconditionally; `survey-page.tsx` mounts only that form.

**Impact:** a study/org configured `appUsageFreqType = HOURLY` serves fork participants the
**daily** survey instead of the hour-bucketed one — a silently wrong participant experience
and wrong-shaped survey submission. Default (DAILY) studies are unaffected.

**Classification — definitively a *backwards* regression** (not upstream-added-post-
divergence): daily and hourly are siblings in the same upstream `SurveyContainer`, and the
fork ported the daily one *"verbatim from upstream methodic-labs"* while dropping the hourly
sibling — so the hourly variant demonstrably existed at the fork's branch point.

**Status: CLOSED (2026-06-03)** — `HourlyAppUsageSurvey`/`HourlySurvey` ported to
`participant-hourly-survey-form.tsx` (+ pure `hourly-survey-core.ts`); `survey-page.tsx` reads
`appUsageFrequency` from the new participant endpoint and branches daily/hourly. See **Resolution**.

---

## R2 — TUD ignores study-configured `TimeUseDiarySettings` (web) — CONFIRMED REGRESSION

Upstream's TUD instrument is shaped by the **study setting** `TimeUseDiarySettings`, read from
the `[TIME_USE_DIARY, …]` study-settings slice:
- `getEnableChangesForOhioStateUniversity(settings)` →
  `settings.getIn([TIME_USE_DIARY, 'enableChangesForOhioStateUniversity'])`
  (`upstream/src/containers/tud/utils/getEnableChangesForOhioStateUniversity.js:4`), consumed
  across `DaySpanSchema`, `ContextualSchema`, `NightTimeActivitySchema`, `isWakeUpPage`,
  `isSummaryPage` — i.e. **OSU changes which questions are asked**. Sherbrooke and
  `clockFormat`/`clockFormatLocked`/`language` are read the same way.

**The fork backend carries the setting, byte-identical to upstream** (so it is researcher-
configurable and persisted):
`chronicle-models/.../timeusediary/TimeUseDiarySettings.kt:7-15` →
`enableChangesForSherbrookeUniversity`, `enableChangesForOhioStateUniversity`, `language`,
`clockFormat`, `clockFormatLocked`.

**The fork web reads none of it from settings.** `time-use-diary-page.tsx:33-38` builds the
entire `TudSettings` from URL query params:
```
clockFormat:        parseClockFormat(searchParams.get('clockFormat')) ?? 12,
clockFormatLocked:  searchParams.get('lockClockFormat') === 'true',
enableOsu:          searchParams.get('osu') === 'true' || searchParams.get('osu') === '1',
enableSherbrooke:   searchParams.get('sherbrooke') === 'true' || searchParams.get('sherbrooke') === '1',
```
The route fetches **no** study settings (a grep for any settings read across the TUD route +
`components/tud/` returns nothing). The fork's TUD core (`tud-schema.ts`, `tud-flow.ts`)
*correctly implements* OSU and Sherbrooke — it is only the **activation source** that
regressed from study-settings to URL-param.

**Impact:** a study configured `enableChangesForOhioStateUniversity = true` (or Sherbrooke,
or `clockFormat = 24`, or `clockFormatLocked`, or a non-`en` `language`) has that setting
**silently ignored** on the fork unless the participant's link happens to carry the matching
`?osu=` / `?sherbrooke=` / `?clockFormat=` / `?lockClockFormat=` / `?lang=` param. For OSU/
Sherbrooke that means serving the **wrong clinical instrument** (different questions, wrong-
shaped submission) — a data-validity issue, not cosmetic.

**Classification — *backwards* regression:** the settings-read existed upstream at the
branch point; the fork ported the variant *logic* but rewired its trigger to URL params.

**Status: CLOSED (2026-06-03)** — `time-use-diary-page.tsx` fetches `TimeUseDiarySettings` from
the new participant endpoint and seeds `TudSettings` + base language from it (pure
`resolveTudSettings`/`resolveBaseLang`), with URL params retained as an override. See **Resolution**.

---

## Per-surface results

### Backend — API contract (chronicle-api)
The **named** upstream `chronicle-api/chronicle.yaml` is a vestigial OpenLattice-era stub
(91 lines, 18 ops, *zero* schemas, header `# TODO: Update this!!! DO I EVEN WANT THIS????`,
points at `api.openlattice.com`). It does **not** describe upstream's real API — the real
surface is the Retrofit `*Api.kt` interfaces (StudyApi 22 ops, SurveyApi 13, …, 100+ ops).
The fork's `chronicle.yaml` is a real 2500-line / 85-op contract. Of the 18 stub ops: 8 are
PRESENT/renamed-equivalent in the fork; the other 10 are OpenLattice-era ops that **upstream
itself removed** from its modern `*Api.kt` (EDM/`getPropertyTypeIds`, `isRunning`,
`isKnownDatasource`, the org-scoped neighbor-graph deletes/exports, the GET
`getParticipationStatus` read). **No contract regressions.**

**Confidence here is transitive, not direct:** the named upstream spec is a dead stub, so the
contract verdict actually rests on the **controller audit** (which implements upstream's real
`*Api.kt` interfaces) + the **DTO/field audit** below. Those reconcile with the real upstream
surface (e.g. NotificationApi's 10 ops = 2 real + 8 `TODO` stubs), so the contract dimension
is substantively covered — just not via the (vacuous) named-spec diff.

### Backend — controllers & services (chronicle-server)
17 upstream controllers, 43 *real* endpoints (15 upstream endpoints are
`TODO("Not yet implemented")` stubs → no parity obligation). Every wired upstream
capability has a wired fork home with its delegate service confirmed — TUD
DayTime/NightTime/Summarized export buckets, app-usage survey, questionnaire submit +
download, legacy v2/v3 enroll + upload, study compliance, notifications, import (all 7),
permissions/authorization, the full Study superset. **Zero accidental regressions.** One
**intentional** removal: `CandidateController.getCandidate`/`getCandidates`
(`@Deprecated("Candidate data is no longer stored")`; only `registerCandidate` kept).

### Frontend — features & routes (chronicle-web)
8 upstream containers / 9 live routes. Every upstream feature that is *actually live*
upstream has a real, router-mounted fork page (`src/modern/app/router.tsx`): studies list,
dashboard, study details, participants (+ all participant modals: add / change-enrollment /
delete / info / download / TUD-history), study TUD dashboard, participant survey, participant
TUD wizard. **Fork-ahead:** participant questionnaire submission (upstream is a disabled
"feature not enabled" stub) and questionnaire authoring (upstream fully commented-out). The
regressions are **R1** (hourly survey variant) and **R2** (TUD ignores study-configured
`TimeUseDiarySettings`; OSU/Sherbrooke/clockFormat are URL-param-only). Two non-regression
divergences:
- `EnrollmentLink` `?enroll` browser-notice page (tells browser users to install the app) —
  no fork equivalent; browser hits land on the generic 404. Cosmetic / intentional.
- **Authz nuance (not a feature gap):** upstream gates `/dashboard` behind
  `Auth0AdminRoute` (`AppContainer.js:81`); the fork mounts `OverviewPage` at `/` and
  `/dashboard` with no admin-role check found. Potential over-exposure — flag to the
  security owner.

### Mobile — data collection (chronicle Android)
Upstream **actively collects exactly one data type: usage events** (its
`UsageStatsChronicleSensor` and `ActivityManagerChronicleSensor` are declared but never
instantiated). The fork actively collects + uploads usage events
(`UsageMonitoringWorker`/`UsageCollectionDelegate`, id `usage_events`) and runs every active
upstream worker/service/receiver: upload (`CombinedUploadWorker`/`UploadExecutor`),
enrollment-status refresh, notifications (AWARENESS survey **and** questionnaire),
user-identification FGS + `NotificationListener` + unlock/dismiss receivers. Modularization
migration flags all default **false** → production runs the upstream code paths byte-for-byte.
**Zero regressions.** One intentional divergence: the per-upload `studyApi.enroll()` self-heal
call was replaced by one-time enrollment + per-server `sourceDeviceId` (v3→v4 / multi-server).

### Shared models / DTOs / enums (chronicle-models + chronicle-api)
107 upstream model files vs 172 fork. Every in-scope participant-data / collection field,
property, and enum value present upstream is present in the fork with identical names and
JSON wire mappings (TUD `ol.*` names + `JsonAlias` byte-preserved; AppUsage, Questionnaire,
Study/StudySettings/Limits, NotificationType, Android usage-event payloads, all enums).
Where the fork differs it is **strictly additive** (e.g. `ChronicleUsageEvent.activityClass`,
battery/network `ChronicleUsageEventType` values, `StudyFeature.ANDROID_SENSOR`,
`Participant.participantNotes/Tags`). **Zero field/enum regressions.** Only upstream model
files with no fork counterpart: `Auth0UserBasic` / `Auth0UserSearchFields` — intentional
auth-stack divergence (fork uses Spring OAuth2 + SHA-256 API keys, not Auth0).

---

## Intentional divergences (confirmed, not regressions)

| Divergence | Where | Rationale |
|-----------|-------|-----------|
| Redshift → Percona Postgres 17 + `pg_tde` | chronicle-server storage | BCM deploy; export feature still wired via `DataDownloadService` |
| Candidate read endpoints dropped | chronicle-server | `@Deprecated("Candidate data is no longer stored")` |
| Auth0 → Spring OAuth2 + API keys | chronicle-server / models | auth-stack redesign; Auth0 DTOs intentionally absent |
| Per-upload `enroll()` → one-time enroll + per-server `sourceDeviceId` | Android | v3→v4 multi-server model |
| Android `:app` → `:app` + `:collection-*` modules | Android | modularization; migration flags default off |
| `?enroll` browser-notice page absent | chronicle-web | enrollment is via the Android deep link |

## Authorization items to review (not parity regressions)

- `/dashboard` admin gate present upstream, absent in the fork overview page — potential
  over-exposure of the global summary/all-studies view. Owner: backend/security.

---

*Cross-ref:* `PARTICIPANT-FORMS-AND-PARITY.md` (forms-level detail; its "all frontend gaps
closed" line is **superseded** by R1 above).
