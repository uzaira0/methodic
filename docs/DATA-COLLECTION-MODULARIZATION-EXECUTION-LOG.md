# Data Collection Modularization — Execution Log

Tracks execution of `DATA-COLLECTION-MODULARIZATION-REFACTOR-PLAN.md` against the
design contract `DATA-COLLECTION-MODULARIZATION-DESIGN.md`.

Branch (all 7 repos): `refactor/data-collection-modularization`

## Autonomy status

`active` — foundation complete, implementation phases pending.

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

## Pending

| Phase | Scope | Notes |
|-------|-------|-------|
| 2  | Shared module DTOs + serialization/compatibility tests in `chronicle-models` | implements design §1B; first code phase |
| 3  | Android collection core package (interfaces, sinks, resolver) | design §1C |
| 4  | Usage events module | wraps `UsageCollectionDelegate` |
| 5  | Device lifecycle module | wraps `DeviceLifecycleEventRecorder` |
| 6  | Hardware sensors module | extracts `SensorRuntimeController` |
| 7  | User identification module | |
| 8  | Upload telemetry / diagnostics module | |
| 9  | Backend generalized settings (additive) | design §1D |
| 10 | Gradle module split (`:collection-*` libraries) | |
| 11 | Data quality + dogfood tooling | |
| 12 | Static security/structural guardrails | implements design §4 catalog |
| 13 | Full verification matrix | |
| 14 | Commit & push sequence | submodule pushes need a `git push` request |

## Notes for the next session

- Phases 3–8 each wrap one module independently — suitable for parallel subagent
  fan-out once Phase 2 contracts are committed.
- `JAVA_HOME=/home/uzair/.local/jdks/temurin-21` required for Gradle.
- Submodule commits precede root pointer bumps; never use `git stash`.
- Re-confirm with the user before `git push` (Phase 14).
