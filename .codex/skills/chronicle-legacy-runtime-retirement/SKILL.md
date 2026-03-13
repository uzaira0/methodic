---
name: chronicle-legacy-runtime-retirement
description: Remove legacy runtime dependencies in active study, survey, TUD, and participant flows by replacing redux-reqseq/Immutable/legacy UI dependencies with modern primitives and RTK Query/state patterns.
---

# Chronicle Legacy Runtime Retirement

Use this skill for work focused on replacing legacy runtime dependencies in live participant and study surfaces.

## Scope

- `chronicle-web/src/containers/study/**`
- `chronicle-web/src/containers/survey/**`
- `chronicle-web/src/containers/tud/**`
- `chronicle-web/src/containers/participant/**`

## Workflow

1. Run the targeted legacy-stack audit:
   - `./scripts/check-legacy-runtime-stack.sh`
2. Prioritize flows by route criticality:
   - route entrypoints first (`StudyRouter`, `SurveyContainer`, `TimeUseDiaryContainer`, `ParticipantDashboard`)
   - then dependent modals/dialogs and reducers.
3. For each file in scope, choose one of:
   - convert to modern primitives and state slices, or
   - remove from live routes and leave a documented migration placeholder.
4. Keep route cuts incremental: do not migrate one flow deeply without validating the route still renders through `chronicle-web/src/index.js`.
5. Validate after each tranche:
   - `cd chronicle-web && bun run check`
   - `cd chronicle-web && bun run test:legacy -- --runInBand --watch=false`
   - `./scripts/chronicle-web-route-cutover-smoke.sh` when route cutover files change.

## Review gates

- Fail fast if the audit script detects active imports from:
  - `lattice-ui-kit`
  - `@material-ui/*`
  - `styled-components`
  - `redux-reqseq`
  - `immutable`
- Validate no silent auth defaults are reintroduced while removing legacy state scaffolding.

## Commit boundaries

- One flow family per commit where possible (`study`, `survey`, `tud`, `participant`).
- Keep each commit coupled to a reviewed route outcome, not just file-by-file edits.
