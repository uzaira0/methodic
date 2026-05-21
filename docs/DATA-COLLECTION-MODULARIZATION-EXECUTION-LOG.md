# Data Collection Modularization — Execution Log

Tracks execution of `DATA-COLLECTION-MODULARIZATION-REFACTOR-PLAN.md` against the
design contract `DATA-COLLECTION-MODULARIZATION-DESIGN.md`.

Branch (all 7 repos): `refactor/data-collection-modularization`

## Autonomy status

`active` — Phases 0–13 complete, committed, and verified; Phase 14 (push)
pending an explicit user request.

## Completed

### Phase 0 — Preflight & Checkpoint ✅

- **Baseline** (`build/baseline/`): Android unit tests + `assembleDebug` green;
  `chronicle-api:test` green; `chronicle-server:test` **full suite green** after a
  baseline repair; security layers sast/mobile/auth/injection/crypto/license/
  secrets/iac green; `compliance` (conftest OPA) **red — pre-existing**, not
  introduced by this work.
- **Baseline repair**: `addbf576` rewrote `AuthTokenController` (+347/-40) but
  updated its test by one line, leaving `chronicle-server:compileTestKotlin`
  broken on `develop`. Fixed in `chronicle-server@87289e3c` (6-arg constructor,
  dropped stale `request` arg from `setAuthCookie`/`testingLogin`/`logout`).
- **Checkpoint commits** (themed, per user choice):
  - `chronicle-server`: `87289e3c` repair, `2310fe43` AWS/Redshift removal
  - `rhizome` `6ea3fb66`, `rhizome-client` `e168eed` — AWS removal
  - `chronicle` `9f0f6ab` — Android collection prep
  - `chronicle-api` `921f8cc`, `chronicle-web` `bf05599` — test updates
  - `chronicle-models` `6f9d9b4` — model updates
  - root: `0d14488` aws pointers, `bcceb65` android pointers, `b765b2e` infra,
    `8eb0bba` security tooling, `26ba962` docs+plan
- Intentionally untracked: `.kotlin/` build cache,
  `docker/traefik/dynamic/local-apps.yml.bak-pre-accelogtracker-fix`.

### Phase 1 — Architecture Boundary Specification ✅

- `docs/DATA-COLLECTION-MODULARIZATION-DESIGN.md` (root `722d560`): module
  taxonomy (6 active IDs + privacy classes + reserved IDs), shared-contract
  serialization plan, mobile interfaces grounded in a real call-graph map,
  backend compatibility matrix, 12-rule static guardrail catalog.

### Pre-Phase-2 — chronicle-models tracking ✅

- `chronicle-models` was an independent git repo gitignored at root. Registered
  as the 7th tracked submodule: dirty work checkpointed (`6f9d9b4`), removed from
  `.gitignore`, `.gitmodules` entry added, git dir absorbed (root `041c183`).
  Shared collection DTOs (design §1B) will land here, committable + CI-verified.

### Phase 2 — Shared module DTOs ✅

- `chronicle-models@f85ecf4` (root `be51f76`): collection DTOs implementing
  design §1B — `CollectionModuleId`, `CollectionModuleSetting`,
  `CollectionPrivacyClass`, `CollectionModuleDiagnostics`, `NetworkPolicy`,
  plus serialization + compatibility tests.

### Phase 3 — Android collection core package ✅

- `chronicle@32ac6b0` (root `2e5ac2e`): collection core package — interfaces,
  sinks, resolver (design §1C).

### Phases 4–8 — Per-module extraction ✅

Each phase wraps one module behind a migration switch defaulting `false`, so
runtime behavior is unchanged until parity is proven.

- Phase 4 — usage events: `chronicle@f89f38c` (root `00b82a7`)
- Phase 5 — device lifecycle: `chronicle@1e9e370` (root `cbc067a`)
- Phase 6 — hardware sensors: `chronicle@7b5c261` (root `0808c78`); the
  power-save degraded-mode guardrail was repointed to the new locations
  (`SensorGateway.isPowerSaveMode` / `SensorRuntimeController` `DEGRADED`) in
  root `6594542`.
- Phase 7 — user identification: `chronicle@eebd614d` (root `d2dcdb9`)
- Phase 8 — upload telemetry / diagnostics: `chronicle@5d67b4a` (root `31fe391`)

### Phase 9 — Backend generalized settings (additive) ✅

- `chronicle-api@68293967`, `chronicle-web@4059f780`, `chronicle-server@b8c624d7`
  (root `3d921a9`): generalized `AndroidDataCollectionSetting` read path,
  OpenAPI schema, regenerated TS types. Read-only and additive (design §1D).

### Phase 10 — Gradle module split ✅

- `chronicle` `abb62a3`…`a302cb1` (root `81ee1ed`): dependency inversion first,
  then the split. New `:collection-base` library holds the persistence layer
  and R/BuildConfig-free primitives; `:collection-core`, `:collection-upload`,
  `:collection-sensors`, `:collection-usage`, `:collection-lifecycle` split out
  of `:app`. The `preferences → collection.identification` back-edge and the
  `collection → HardwareSensorService` cycle were inverted behind interfaces.
  Dependency graph acyclic; merged manifest byte-identical to pre-refactor;
  `:app:assembleDebug`, `testDebugUnitTest`, and 28/28 instrumented tests pass.

### Phase 11 — Data quality + dogfood tooling ✅

- root `cc80f06`: dogfood report / battery harness / long-run / sensor-settings
  scripts and their guardrails.

### Phase 12 — Static security/structural guardrails ✅

- root `ff6c4f8`: collection security layer + 12-rule guardrail catalog
  (design §4); all rules fire on fixtures, zero false positives.

### Post-Phase-12 — Review & V21 fix ✅

- A four-agent review of the committed changes (`/review-fixes`) found that the
  Phase 9 `V21__repair_android_sensor_device_id_columns.sql` migration
  backfilled `device_id` with a raw `source_device_id::uuid` cast, while the
  upload path derives `device_id` as a v3 (MD5 name-based) UUID — so repaired
  rows would never join. V21 also referenced the legacy `source_device_id`
  column unconditionally (crashing on current schemas). Rewritten to derive the
  v3 UUID in SQL, guard every legacy-column reference, fix the PK/NOT-NULL
  ordering, and batch the backfill. Verified against PostgreSQL on legacy and
  current schemas plus an idempotent re-run. `chronicle-server@d5ac40e9`
  (root `627f748`).

### Phase 13 — Full verification matrix ✅

Three tracks, all green:

- **Android** — verified during Phase 10: `:app:assembleDebug`,
  `testDebugUnitTest`, and 28/28 instrumented tests on device.
- **Backend (JVM)** — `chronicle-models` 70, `chronicle-api` 211,
  `chronicle-server` 1202: **1483 tests, 0 failures, 0 errors**. (A Hazelcast
  `TargetDisconnectedException` in the server log is a benign test-teardown
  race, not a failure — build reported `BUILD SUCCESSFUL`.)
- **Security/supply-chain** — collection guardrail layer green. Verification
  surfaced three guardrails with stale `app/` paths after Phase 10's module
  split; all three retargeted to the new `:collection-*` module locations and
  re-confirmed passing (root `d6f8154`).

## Pending

| Phase | Scope | Notes |
|-------|-------|-------|
| 14 | Commit & push sequence | submodule pushes need an explicit `git push` request |

## Notes for the next session

- `JAVA_HOME=/home/uzair/.local/jdks/temurin-21` required for Gradle.
- Submodule commits precede root pointer bumps; never use `git stash`.
- Phase 4–8 migration switches still default to `false`/legacy — flipping them
  to prove parity is follow-up work beyond this refactor's scope.
- Pre-existing latent bug surfaced during review (not introduced here, not
  fixed): `MoveToIosEventStorageTask.kt` `mapSensorDataToStorage` has a
  non-local `return` inside `mapValues {}` that drops all but the first sensor
  type in multi-sensor iOS uploads.
- Re-confirm with the user before `git push` (Phase 14).
