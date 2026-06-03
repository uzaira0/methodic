# Participant Forms & methodic-labs Parity

Status of the participant-facing web forms (`/survey`, `/questionnaire`, `/time-use-diary`)
and the feature-parity gaps against the upstream `methodic-labs/*` repos. Written
2026-06-03.

## What is built & verified

| Item | State | Verification |
|------|-------|-------------|
| **Questionnaire participant form** | Done | `participant-questionnaire-form.tsx` + route; wired `getParticipantQuestionnaire` + `submitQuestionnaireResponses`; typecheck + biome + component test green |
| **App-usage Survey participant form** | Done | `participant-survey-form.tsx` + route; retyped `getAppUsageSurveyData`/`submitAppUsageSurvey` to `AppUsageEntry[]`; component test green |
| **TUD settings parity fields** | Done | `TimeUseDiarySettings.clockFormat: Int = 12`, `clockFormatLocked: Boolean = false`; `TimeUseDiarySettingsTest` (incl. legacy-JSON backward-compat) green |
| **Survey-model invariants** | Done | `SurveyModelsTest` (Questionnaire/Question/QuestionnaireResponse/AppUsage init checks) green |
| **TUD wire contract** | Done | `TimeUseDiaryResponseTest` pins `ol.*` property names + alias deserialization |
| **biome gate breakage** | Fixed | generated `*.generated.ts` excluded via `biome.json` `overrides`; full `bun run check` chain green |

The frontend gate (`typecheck → biome:check → lint:ast → check:api-types → build → test → test:components`)
is green end-to-end. The Questionnaire and Survey forms render off live RTK Query
data and submit against the real backend contracts (`SurveyController`).

## Contracts (backend, authoritative)

- **Survey** — `GET/POST /chronicle/v3/survey/{studyId}/participant/{participantId}/app-usage`,
  body `List<AppUsage>`. `AppUsage{appPackageName, appLabel?, timestamp, eventType,
  users: List<String>, timezone, uploadedAt}`. The participant fills `users`.
- **Questionnaire** — `GET /survey/{studyId}/questionnaire/{questionnaireId}` (not ACL-gated,
  participant-readable) → `Questionnaire`; submit `POST
  /survey/{studyId}/participant/{participantId}/questionnaire/{questionnaireId}`, body
  `List<QuestionnaireResponse>` keyed by **questionTitle** (`value: Set<String>`).
  `Question.choices` empty ⇒ open-ended.
- **TUD** — `POST /time-use-diary/{studyId}/participant/{participantId}`, body
  `List<TimeUseDiaryResponse>`. `TimeUseDiaryResponse{code (ol.code), question (ol.title),
  response: Set<String> (ol.values), startDateTime?, endDateTime?}`.

## TUD form — BUILT & verified (2026-06-03)

The TUD participant form is now implemented in the modern app as a contained, fully
unit-tested feature under `src/modern/components/tud/`, wired to the route
`src/modern/routes/time-use-diary-page.tsx` and the `submitTimeUseDiary` mutation. It
is a faithful port of the upstream `src/containers/tud/` clinical instrument, with the
correctness concentrated in three pure, exhaustively-tested cores (per the
state-machine-not-shell discipline):

| Module | Role | Tests |
|--------|------|-------|
| `i18n/` (translator + language-codes + 6 JSON tables) | i18next-subset resolver (`$t()`, `{{var}}`, `_context`, returnObjects) + gendered Hebrew + RTL + array-order permutations | `translator.test.ts` (15) |
| `tud-flow.ts` | page state machine: today/yesterday/OSU branches + activity-loop termination (`isDayComplete`) | `tud-flow.test.ts` (9) |
| `tud-schema.ts` | data-driven field model: every conditional chain (typicalDay→reason, reading→book, media→age/device/language, secondary activities, OSU/Sherbrooke variants) | `tud-schema.test.ts` (14) |
| `tud-submit.ts` | pure `TimeUseDiaryResponse[]` builder (friendly aliases; datetimes on activity rows) | `tud-submit.test.ts` (8) |
| `tud-engine.ts` | pure answer-evolution: `seedForPage` (carriers between primary↔contextual), `advancePage`, cross-field `timeErrors` (end>start, end≤dayEnd — parity with `applyCustomValidation`) | `tud-engine.test.ts` (12, incl. 3 full intro→summary **walk** tests per mode) |
| `tud-widgets.tsx` + `tud-form.tsx` | generic controls + the wizard shell (intro clock-format step, Next/Back, stale-answer pruning, summary+edit, submit, lossless language switch) | `tud-widgets.test.tsx` (13) + `tud-form.test.tsx` (5, IntroStep/SummaryStep render) |

Two deliberate design choices make it correct-by-construction: option answers are
stored as their **english canonical value** (localized label is display-only), so submit
needs no fragile back-translation; and times are stored as canonical 24h `HH:MM`,
projected onto the diary date at submit. Time fields **commit their default on mount** so
accepting a shown default (e.g. 07:00) doesn't silently block Next. The full chronicle-web
gate is green (`bun run check` + `test` 3167 + `test:components` 159 + `build`); the TUD
feature carries **70 tests across 7 files**.

The original build-ready spec (mined from `upstream/develop` of
`methodic-labs/chronicle-web` `src/containers/tud/`) is retained below for reference:

- **Pages**: `INTRO`(0, clock-format select) → `PRE_SURVEY`(1, day-of-week + typical-day)
  → `DAY_SPAN`(2, wake/bed times) → N **activity pages** (loop until `activityEndTime ==
  dayEndTime`) → **NightTime** page → **Summary**. Branch on `activityDay`
  (`today`/`yesterday`) and study setting `enableChangesForOhioStateUniversity`.
- **DayTime / NightTime / Summarized** is the *export* dimension (3 download buckets),
  not a per-question tag.
- **Question codes** (`ol.code`): `primaryActivity, secondaryActivity, careGiver,
  bgTvDay, bgAudioDay, adultMedia, primaryMediaActivity, primaryMediaAge, primaryBookType,
  sleepArrangement, typicalSleepPattern, wakeUpCount, dayOfWeek, typicalDay,
  nonTypicalDayReason, dayStartTime, dayEndTime, clockFormat …` plus synthetic
  `activityDate`/`activityDay`/`waveId`/`familyId`. Omitted from submit:
  `activityStartTime/EndTime, activitySelectPage, clockFormat, followUpCompleted,
  otherActivity`.
- **Representative options** (English): primary-activity radio
  (`childcare, napping, eating, media_use, reading, indoor, outdoor, grooming, other,
  outdoors`); caregiver checkboxes (`A parent…, A grandparent, Another adult, A sibling,
  Another child`, none="No one"); bg-media radio (`No; Yes, some/half/most/the entire
  time; Don't know`); sleep-arrangement, wake-up-count, etc. (see upstream
  `src/core/i18n/en/translation.json`).
- **clockFormat**: URL `?clockFormat=12|24` / `?lockClockFormat` override study settings
  `TimeUseDiary.clockFormat` (default 12) / `clockFormatLocked` (default false) — now
  present on the backend `TimeUseDiarySettings`. Drives `ampm` on every time widget; the
  intro widget is hidden when locked.
- **Submit body builder**: emit `{code, question: QUESTION_TITLE_LOOKUP[code]||code,
  response: <english strings>, startDateTime?, endDateTime?}` per answered field;
  translate non-English answers back to English first.

## methodic-labs parity — remaining gaps

Sub-agent diff of our fork vs `methodic-labs/{chronicle-server,chronicle-api,chronicle-web,
chronicle}` (`chronicle-models`/`rhizome`/`rhizome-client` have **no** upstream repo).

| Gap | Status |
|-----|--------|
| TUD `clockFormat` / `clockFormatLocked` (models + api) | **Closed** (backend, prior pass) |
| TUD `clockFormat` 12/24h **web UI** | **Closed** — intro clock-format selector (`ClockFormatSelect`); `?clockFormat=`/`?lockClockFormat=` override; drives summary time formatting |
| Hebrew (`he-male`/`he-female`) + gendered-language web i18n + RTL | **Closed** — `language-codes.ts` (`resolveLanguageCode`, `GenderedLanguages`, `ARRAY_ORDER_PERMUTATIONS`), `he-male`/`he-female` JSON ported verbatim, `?lang=&gender=` route params, `dir="rtl"` for Hebrew. Stored-english-canonical answers make in-form language switching **lossless** (a superset improvement over upstream's destructive switch) |
| Redshift→Aurora storage migration (chronicle-server) | **Intentional divergence** — our deploy is Percona PG 17 + `pg_tde`; not a deficiency |

Everywhere else our fork is at parity or ahead (Android `:collection-*` modularization,
`StudyLimits` jakarta validation, correct `updateStudySettings` path).

## Backend tests (this pass)

- **#6 thin Survey/TUD controllers** — DONE, green. `SurveyControllerTest` 3→9
  (app-usage/device-usage threshold filters, submit app-usage, submit questionnaire
  responses delegation, ACL-gated download), `TimeUseDiaryControllerTest` 3→8 (submit
  within audited transaction, ACL-gated exports).
- **#7 legacy v2** — DONE, green. New `ChronicleControllerV2Test` (8): enroll/upload
  device-id derivation, participation-status, questionnaires delegation.
- **#3 RLS study-isolation e2e** — DONE. New `RLSStudyIsolationTest` runs the *actual*
  `V1__enable_row_level_security.sql` verbatim on a Postgres testcontainer, then asserts
  cross-study invisibility under a non-superuser role (study A ≠ study B), empty-context
  denial, admin bypass, and `WITH CHECK` write blocking. (Docker/testcontainers confirmed
  available here; the earlier "infra-gated" framing was a JDK-path artifact — real JDK 21
  is `~/.local/jdks/temurin-21`, not `~/.local/jdk` which is 17.)
- **#5 full-stack MockMvc** — *not added.* The suite is plain JUnit4+Mockito by design
  (zero `@SpringBootTest`/`MockMvc`); a full HTTP test needs a new Spring context
  (security/rate-limit/RLS datasource) — a framework addition, deliberately out of scope.
- **#8 PIT widening** — deferred to last, now that the controller suites hold the gate.

## Optional next niceties

- Study-settings-driven OSU/Sherbrooke (currently URL params on the TUD route).
- Richer summary rows for non-activity sections.
