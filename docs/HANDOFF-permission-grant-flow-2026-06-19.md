# OS Permission Grant Flow for Consent-Gated Modules — Handoff

**Date:** 2026-06-19
**Status:** Built, unit-tested, on-device proven (Pixel 10a). **Committed, NOT pushed.**
**Branches:** `develop` (root / chronicle / chronicle-server / chronicle-web / chronicle-api), `main` (chronicle-models).
**Lane:** HIPAA-2028 sensing-expansion (extends `docs/HANDOFF-per-sensor-modules-2026-06-12.md` and the six-expansion-modules batch).

---

## git state for the device transition — ALL PUSHED (2026-06-19)

Everything is on `origin`. To resume on the other machine: clone/pull, then
`git submodule update --init --recursive`. For the three protected submodules, check out
the feature branch (their `develop` PRs aren't merged yet — see below).

| Repo | Branch on origin | Commit | Notes |
|------|------------------|--------|-------|
| root (`uzaira0/methodic`) | `develop` | `b2f515e` | pushed; in sync |
| `chronicle` (android) | `develop` | **`f5ef584`** | pushed; **this work** |
| `chronicle-models` | `main` | `536d6c9` | pushed; in sync |
| `chronicle-server` | `feat/sensing-expansion-6modules` | `300a3db0` | PR [#19](https://github.com/uzaira0/chronicle-server/pull/19) → develop (unmerged) |
| `chronicle-web` | `feat/sensing-expansion-6modules` | `ed6c769a` | PR [#114](https://github.com/uzaira0/chronicle-web/pull/114) → develop (unmerged) |
| `chronicle-api` | `feat/sensing-expansion-6modules` | `f19bac73` | PR [#12](https://github.com/uzaira0/chronicle-api/pull/12) → develop (unmerged) |

**This handoff's work is `chronicle@f5ef584` + root `@b2f515e`.** The other commits are the
already-documented six-sensing-expansion-modules batch (memory
`chronicle-six-expansion-modules-wired.md`).

**Why feature branches for server/web/api** (memory `chronicle-submodule-fold-topology`):
their `develop` is **protected** → PR + rebase-merge only (direct push = GH006). The commits
are on origin via `feat/sensing-expansion-6modules`; the root's submodule pointers reference
those exact SHAs, so `submodule update` resolves. Merge the 3 PRs (rebase-merge) to land them
on `develop`; then re-bump the root pointers if the rebase changes the SHAs.

---

## What shipped (this commit)

A consent-gated module needs **four** things to actually collect; the consent trio
(ACK_GATED_MODULES + consent copy + Data Sharing row) was only three. The fourth: **its OS
permission must be GRANTED, not just declared.** Two modules shipped inert because nothing
requested their permission:

- `health_connect` — declared `health.READ_*` but nothing launched the Health Connect grant
  flow, so `getGrantedPermissions()` was empty forever → no prompt, no data.
- `activity_recognition` / `sleep` / `sensor_step_counter` / `sensor_significant_motion` —
  need `ACTIVITY_RECOGNITION` (runtime, API 29+); manifest-declared but never requested, so
  the framework logged *"Tried enabling a sensor (Step Counter) without holding
  android.permission.ACTIVITY_RECOGNITION"* and they collected nothing.

### Fix

- **`ModulePermissions`** (`collection-core/.../collection/permissions/ModulePermissions.kt`)
  — single source of truth: `REQUIREMENTS: Map<CollectionModuleId, List<PermissionRequirement>>`,
  each carrying a `PermissionKind` (MANIFEST_NORMAL / RUNTIME / USAGE_ACCESS / HEALTH_CONNECT
  / NOTIFICATION_LISTENER / ACCESSIBILITY). Permission names are **string literals** (not
  `android.Manifest.permission.*`) so it's JVM-unit-testable and comparable to manifest XML.
  Helpers: `requirementsFor`, `runtimePermissionsFor`, `needsKind`, `needsHealthConnect`.
  `HEALTH_CONNECT_READ` = the 6 read perms the module actually reads (steps, distance,
  heart_rate, total/active calories, floors).
- **`HealthConnectPermissions`** (`collection-device/.../collection/device/HealthConnectPermissions.kt`)
  — `requestContract()` = `PermissionController.createRequestPermissionResultContract()`,
  `READ_PERMISSIONS`, `isAvailable()` (getSdkStatus, cheap), `allGranted()` (suspends → call
  OFF main thread). (`connect-client` is an `api` dep of collection-device, so app sees it.)
- **`DataSharingFragment`** (`app/.../ui/DataSharingFragment.kt`) drives requests FROM the map
  (no hand-maintained list): two launchers (`RequestMultiplePermissions` for runtime + the HC
  contract, chained via `pendingHealthConnectRequest` because the system shows one screen at a
  time); `addPermissionAffordances()` renders up to 3 rows — "Grant access" (runtime + HC),
  "Open settings" (notification-listener), "Open settings" (accessibility) — whenever an active
  module is missing its permission. `computePermissionStatus()` runs off the main thread.
- **`HealthConnectRationaleActivity`** (`app/.../HealthConnectRationaleActivity.kt`) + manifest:
  pre-Android-14 `SHOW_PERMISSIONS_RATIONALE` intent-filter + Android-14+
  `ViewPermissionUsageActivity` activity-alias (`VIEW_PERMISSION_USAGE` + `HEALTH_PERMISSIONS`
  category, `START_VIEW_PERMISSION_USAGE` permission). Needed so the app appears in HC's
  permission manager + passes Play review. Pixel 10a uses platform HC
  (`com.google.android.healthconnect.controller`), so the alias is what's exercised.
- **Trimmed `collection-device` manifest** from 11 health perms → the 6 read (dropped
  RESTING_HEART_RATE, OXYGEN_SATURATION, RESPIRATORY_RATE, SLEEP, EXERCISE — sleep is collected
  via the GMS Sleep API, not HC). Declaring health perms the app never reads is a Play-policy +
  over-broad-consent violation.

### New guard test

**`ModulePermissionCoverageTest`** (`app/src/test/.../collection/permissions/`) —
source/manifest-scanning (same style as `CollectionGateCallSiteInvariantTest`). Asserts:
every uses-permission-kind requirement is declared as `<uses-permission>`; service-bound
kinds (notification-listener / accessibility) as `<service android:permission>`; the HC set
EQUALS the manifest health perms exactly (not containment); RUNTIME + HEALTH_CONNECT kinds
have a request path in source; `DataSharingFragment` references both `ModulePermissions` +
`HealthConnectPermissions`; key requirements snapshot-locked. **This is the test that catches
"needs a permission but it's undeclared or never requested"** — the 5 pre-existing consent
invariants didn't cover permissions.

## Files in `chronicle@f5ef584`

```
A  app/.../HealthConnectRationaleActivity.kt
M  app/.../ui/DataSharingFragment.kt
M  app/src/main/AndroidManifest.xml
M  app/src/main/res/values/strings.xml            (health_connect_rationale)
A  app/src/test/.../collection/permissions/ModulePermissionCoverageTest.kt
A  collection-core/.../collection/permissions/ModulePermissions.kt
M  collection-device/src/main/AndroidManifest.xml (11 → 6 health perms)
A  collection-device/.../collection/device/HealthConnectPermissions.kt
```

## Full permission inventory (the "what else needs permissions" answer)

19 `<uses-permission>` + 2 service-bound; **no** mic / camera / location / body-sensors /
phone-state / contacts / SMS.

- `usage_events` / `app_network_usage` / `in_app_activity_class` → `PACKAGE_USAGE_STATS`
  (Usage Access special; already gated at startup in `PermissionActivity`).
- `activity_recognition` / `sleep` / `sensor_step_counter` / `sensor_significant_motion` →
  `ACTIVITY_RECOGNITION` (runtime, API 29+) — **fixed here**.
- `health_connect` → 6× `health.READ_*` via the HC grant flow — **fixed here**.
- `connectivity_state` → `ACCESS_NETWORK_STATE` (normal, auto-granted).
- `notification_activity` → notification-listener access (Settings switch; service-bound).
- `interaction_events` → accessibility service (Settings link; service-bound).
- `POST_NOTIFICATIONS` asked once in `MainActivity`. battery / device_settings / most sensors
  need none. **BODY_SENSORS is NOT used** (on-body heart-rate/SpO2 from a paired watch; we read
  Health Connect aggregates instead — narrower, read-only).

## Verification (local — GitHub Actions is infra-broken on these repos)

- `:collection-core:test` — green.
- `:app:testDebugUnitTest --tests "*ModulePermissionCoverageTest" --rerun-tasks` — **executed
  (203 tasks) + BUILD SUCCESSFUL** on 2026-06-19 before committing.
- Prior full `:app:testDebugUnitTest` + `:app:assembleRelease` green (this batch added no deps —
  `connect-client` was already an `api` dep — so verification-metadata regen was not needed).

## On-device proof (Pixel 10a, beta study 47e2579c, versionCode 47)

Tapping "Grant access" fired the real *"Allow chronicle to access your physical activity?"*
system prompt → granted → the HC *"Allow chronicle to access your fitness and wellness data?"*
screen chained automatically → Allow all → all 6 HC + `ACTIVITY_RECOGNITION` `granted=true` →
affordance cleared. APK installed; APK at
`chronicle/app/build/outputs/apk/release/app-release.apk`.

## Closed investigation — "sleep/activity_recognition/health_connect show enabled but didn't appear"

**Conclusion: not a bug; a measurement artifact. Do not re-investigate.**
- Config `studies.settings.DataCollection.modules` had all three `{"enabled": true}`.
- The device's latest sync resolver (logcat) resolved all six at **Tier-1 = enabled** (no
  safe-default fallthrough), identical to the modules that "worked."
- `sleep_events = 2` rows already in the backend = hard proof sleep is enabled + collecting.
- The "only 6 rows visible" was a `uiautomator dump` artifact (it omits below-the-fold nodes —
  the same dump also showed zero sensor rows despite 5 enabled sensors). No code path drops an
  enabled non-sensor module (`CollectionLoopCoordinator.sync` → `DashboardDataRepository.load`
  → `CollectionLoopStore.loadAll` only filters unknown wire-ids / device-absent sensors).

## Resume environment

- **JDK 21:** `export JAVA_HOME=/home/uzair/.local/jdks/temurin-21`
- **Android SDK:** `~/.local/android-sdk`; `adb` there.
- **Release build:** `cd chronicle && export JAVA_HOME=… && export MOBILE_SIGNING_SECRET="$(docker exec chronicle-backend printenv MOBILE_SIGNING_SECRET)" && ./gradlew :app:assembleRelease`
  (build with the LIVE backend secret — `docker/.env` is stale, len-43 vs backend len-44 — or enroll 401s).
- **R8 disabled for `release`** (minify broke runtime); keep that.
- **NEVER reboot the wifi-adb devices** — `adb tcpip` dies on reboot; needs USB to re-enable.

## Open follow-ups

1. **Merge the 3 protected-repo PRs** (rebase-merge into develop): server #19, web #114, api #12.
   Then re-bump root submodule pointers if the rebase changed the SHAs.
2. **Final visual confirmation** — scrolled Data Sharing screenshot showing sleep /
   activity_recognition / health_connect rows below "Device Settings". Blocked when last
   attempted: the Pixel's wifi-adb dropped (reconnect timed out; not rebooted per rule). Wake
   the tablet → re-enable Wireless debugging / re-run `adb tcpip` over USB → `adb connect <ip:port>`.
   This is cosmetic confirmation only; the investigation above already proves the rows resolve enabled.
3. SM-X210 + Fire tablets still run the older APK (per the per-sensor handoff) — reinstall when
   their wifi-adb endpoints are available.
