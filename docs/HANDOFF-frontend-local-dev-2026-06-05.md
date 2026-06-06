# Handoff — Frontend Local Dev + Real-Data Dashboard (2026-06-05)

**2026-06-06 supersession note:** the frontend changes described below have
since been committed and pushed to the `device-enrollment-dashboard-ui` branch;
the PR is `uzaira0/chronicle-web#104`. Treat older "uncommitted" wording in this
handoff as historical session state.

Sibling handoff: [`HANDOFF-collection-loop-qa-2026-06-05.md`](./HANDOFF-collection-loop-qa-2026-06-05.md)
(device-side collection-loop QA, F-1/V27/F-2, stranded tablet). This doc covers the
**chronicle-web frontend** thread: bringing the dashboard up locally against **real prod
data**, the UI cleanups, and the device/sensor-identity findings that came out of it.

All changes below are **uncommitted** on `chronicle-web` branch `develop`. Nothing has been
committed or pushed. The prod backend was never touched/restarted.

---

## 1. What was built — local dev server on real prod data

Goal: run the React dashboard **locally, not exposed to the public**, showing the **real**
studies (Mini + prod), not fixtures — without a backend, without the mobile signing wall, and
without SSO.

### New files (all under `chronicle-web/`, untracked)
| File | Role |
|------|------|
| `scripts/dev-local.ts` | Bun HMR dev server. Binds `127.0.0.1` by default (`HOST=0.0.0.0` to reach it on the BCM LAN via `cnrc-deni-p001.cnrc.bcm.edu:5173`). Live source + hot-reload via HTML import + `development.hmr`. Routes `/chronicle/*` → real data, else proxy (if `CHRONICLE_BACKEND_URL` set), else synthetic auth/benign default. |
| `scripts/dev-realdata.ts` | **The real-data layer.** Answers 14 study GET endpoints by reading the prod DB **read-only** via `docker exec chronicle-postgres psql`. Metadata only (study fields, participant codes, device ids, ping/collection dates, counts, ack trail) — never raw sensor values. SQL passed via `DEV_SQL` env var; the only injected value is a study id re-validated as a UUID → no injection surface. |
| `scripts/dev-fixtures.ts` | Synthetic auth only: `/auth/session` + `/auth/testing-login` return an authenticated local-admin session (prod is SSO-only and the HS256 mint path is rejected by the decoder). Benign default (`200 []` / `204`) for anything not backed by real data. |

### Modified
- `package.json` — added `"dev:local": "bun ./scripts/dev-local.ts"`.

### How to run / resume
```bash
cd /home/opt/chronicle/chronicle-web
HOST=0.0.0.0 PORT=5173 bun ./scripts/dev-local.ts     # LAN-reachable
# or just: bun run dev:local                          # localhost-only (127.0.0.1)
```
Currently **running**: pid `2572000`, bound `0.0.0.0:5173`. Over SSH:
`ssh -L 5173:127.0.0.1:5173 <host>` then open `http://localhost:5173`.

Why not `bun run dev`: Bun's bare HTML dev server binds `0.0.0.0` with no host flag, and this
host also runs the **public prod stack** — so the bare server would expose dev on the research
LAN. `dev:local` binds loopback by default. See memory `chronicle-web-local-dev.md`.

The prod backend is reachable in-docker only (`expose`, not `ports`) at container IP `:40320`;
pointing dev at it hits the mobile **signing wall** (F-2) on study routes and touches HIPAA
data — hence the read-only DB layer instead.

---

## 2. UI cleanups (uncommitted, `src/modern/`)

| File | Change |
|------|--------|
| `app/app-shell.tsx` | Full-width content (`max-w-[1440px] mx-auto` → `w-full`); sticky viewport-height sidebar (`min-h-screen` → `h-screen self-start overflow-y-auto`, theme toggle pinned to screen bottom); removed Participants + Questionnaires from the left nav (now Dashboard + Studies only). |
| `routes/study-layout.tsx` | Questionnaires + Time Use Diary made **always-visible tabs** (`module: null`, un-gated from study modules). |
| `routes/study-details-page.tsx` | Removed the redundant quick-action button row (Manage Participants / Questionnaires / TUD Exports / Compliance — duplicated the tabs) and the `<StudyDashboard>`. |
| `components/study-dashboard.tsx` | **DELETED** (held Upload Frequency / Active Devices / Sensor Coverage charts). |
| `routes/study-participants-page.tsx` | Participant-detail device display rework (see §3). |

Gate status: `bun run typecheck` clean, `biome check` clean on touched files. Full
`bun run check` not re-run end-to-end since the last edit — run it before any commit.

---

## 3. Participant-detail device & sensor display (study-participants-page.tsx)

Two rounds of fixes, driven by "why are there raw device UUIDs / why 4 devices / why are
sensors out of order and repeated".

- **Device IDs were raw-dumped** → now collapsed. `collapseDevicesByType()` groups device
  records by `deviceType` and shows `Android ×N` with an enrollment count instead of
  `Android 1/2/3/4`.
- **Sensor availability was 4 repeated, shuffled blocks** → `dedupeSensorProfiles()` collapses
  identical capability profiles, **sorts** each list, and renders two **labeled** groups:
  *Available on device (N)* (green) and *Not present on this hardware (N)* (neutral grey), with a
  caption that this is hardware capability, not collection/consent state. "Reported across N
  enrollments" when collapsed.

### Findings that drove this (verified against code + prod DB)
1. **Device IDs are random per-enrollment UUIDs, not hardware IDs.** `Enrollment.kt:182` /
   `ServerEnrollmentActivity.kt:141` mint `UUID.randomUUID()` at enroll time. The `AndroidDevice`
   payload (`chronicle-models/.../sources/AndroidDevice.kt`) carries only `Build.MODEL/BRAND/
   PRODUCT/DISPLAY/SDK` (non-unique model metadata) + the random UUID. **No** IMEI / Android ID /
   MAC / serial is collected anywhere (grepped the whole Android tree). HIPAA-pseudonymous by
   design.
2. **Sensor availability is a pure hardware-capability report**, independent of study toggles.
   `SensorAvailabilityReporter.kt:37-49` walks the **entire** `AndroidSensorType` catalog and
   records `SensorManager.getDefaultSensor(type) != null` → available, else unavailable. Comment:
   *"making device capability gaps visible to operators."* For Mini the 6 "available" happen to
   equal the 6 in the `AndroidSensor` study setting because the researcher toggled exactly the
   sensors the SM-T510 has; the 8 "unavailable" are catalog sensors the tablet physically lacks.
3. **There is no per-sensor opt-out.** Consent/opt-out is **module-level** (the `hardware_sensors`
   acknowledgment gate), never per individual sensor. So "unavailable vs opted-out" is not a real
   data distinction — the only real per-sensor state is has-hardware vs not.

### ⚠️ Open question the user raised (UNRESOLVED) — "same device vs N devices?"
Because every enrollment mints a fresh random UUID and **no** stable hardware identifier is sent,
the system **cannot deterministically tell** "one tablet re-enrolled 4×" from "four identical
SM-T510 tablets." Verified: the 4 device records for `tablet-upload-20260519-144146` are
**byte-identical** in every field (`SM-T510 / gta3xlwifixx / RP1A.200720.012.T510XXU5CWA1 / sdk
30 / codename REL`, empty FCM token) — only the random `device_id` differs.

Soft signals only: same participant id, identical capability profile, non-overlapping upload
timestamps. The current `Android ×4` / "Enrolled Devices (1)" label is therefore an **inference**,
not a provable fact, and would wrongly merge two genuinely-distinct identical-model devices.

**Decision pending — pick one:**
- (a) Relabel to **"4 enrollments"**, claim no device count (most truthful). *Recommended.*
- (b) Treat "1 participant = 1 device" as study protocol; count = enrollments.
- (c) Add an app-private persistent install ID (survives re-enroll, not reinstall/wipe) — a real,
  privacy-reviewable app change.

---

## 4. Production DB write performed this session (irreversible)

Deleted test participant **`emulator-smoke-20260519`** from Mini in one scoped transaction:
its enrollment, stats, 2 device records, 1 sensor-availability row, and **776** `usage_events`
rows. Verified 0 rows remain. The dashboard reads prod directly, so this was a **real, permanent
prod-DB delete**, not a dev-only change. Mini now has exactly **2 participants**: `p1` and
`tablet-upload-20260519-144146`.

No other prod writes. Backend never restarted; all containers healthy.

---

## 5. State of the world / next steps

- Dev server running on `0.0.0.0:5173` (pid 2572000), serving real prod-DB data + synthetic auth.
- All `chronicle-web` changes **uncommitted** on `develop`:
  - `M package.json`, `M src/modern/app/app-shell.tsx`, `D src/modern/components/study-dashboard.tsx`,
    `M src/modern/routes/study-details-page.tsx`, `M src/modern/routes/study-layout.tsx`,
    `M src/modern/routes/study-participants-page.tsx`
  - `?? scripts/dev-local.ts`, `?? scripts/dev-fixtures.ts`, `?? scripts/dev-realdata.ts`
- **Before any commit:** run full `bun run check`; decide whether the `scripts/dev-*.ts` +
  `dev:local` belong in the repo or stay local-only (they read prod via `docker exec` — fine for
  this host, not portable). Never stage secrets/keystores/APKs/.env.
- **Open decisions:** §3 device-count labeling (a/b/c); whether to wire create/edit study
  persistence (needs the real local backend, not the read-only DB layer); the optional per-sensor
  *collection* status view (cross-reference available set vs what `hardware_sensors` collects).

## Guardrails respected
No commits/pushes (awaiting explicit ask). No backend restart. Read-only DB except the one
explicitly-requested `emulator-smoke` delete. No secrets staged.
