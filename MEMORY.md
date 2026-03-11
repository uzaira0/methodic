# Chronicle Memory

Updated: 2026-03-11

## Current State

- The monorepo has five active surfaces: `chronicle-server`, `chronicle-api`, `chronicle-web`, `chronicle` (Android), and shared `rhizome` libraries.
- Root Gradle validation could not run in this workspace because `java` and `JAVA_HOME` were not configured.
- `chronicle-web` now passes `bun run check`, `bun run test -- --runInBand --watch=false`, and the web portion of `./scripts/chronicle-smoke.sh`.
- The current web auth contract is: bootstrap JWT from `config.json` for testing, exchange it for backend-managed cookies, keep JWT state in memory only, and treat interactive SSO as future work.
- The requested TypeScript error-catching spec has been mapped onto `chronicle-web/`, but the frontend is still Flow-based. `chronicle-web/tsconfig.app.json` is a forward-looking policy scaffold rather than full source coverage.
- `chronicle-web` is now Bun-managed for install, lockfile, script execution, and the modern HTML build/dev/preview loop. Node is still present as a compatibility runtime for the legacy Jest/webpack stack while those tools remain in place.
- `chronicle-web` ESLint warnings still document legacy debt, but blocking errors are now under control in the requested gate.

## Verified Signals

- `bun run test -- --runInBand --watch=false` in `chronicle-web/` is green.
- `bun run check` in `chronicle-web/` is green.
- `bun run modern:build`, `bun run modern:dev`, and `bun run modern:preview` all work in `chronicle-web/`.
- `./scripts/chronicle-smoke.sh` is green except for JVM steps skipped because Java is missing locally.
- `./scripts/silent-failure-hunter.sh` finds only existing `console.error` sites, not swallowed catches or `queueMicrotask` patterns.
- Backend support for the new auth flow exists in `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/AuthTokenController.kt` and related security config.
- Repo automation added:
  - `scripts/chronicle-preflight.sh`
  - `scripts/chronicle-smoke.sh`
  - `scripts/silent-failure-hunter.sh`
  - `.claude/settings.json` hooks for secret protection and post-edit web linting
  - `.github/workflows/ci.yml` for web checks, JVM smoke, compose validation, and silent-failure scanning

## Active Modernization Checklist

1. Bun-native modern shell
   - [x] Review whether Bun can replace the modern HTML dev/build loop directly.
   - [x] Fix `chronicle-web` to use Bun for modern dev/build/preview instead of Vite.
   - [x] Commit the Bun cutover separately.
2. Bun-managed frontend lockfile
   - [x] Review whether `package-lock.json` still has a role once Bun owns installation.
   - [x] Fix `chronicle-web` to use `bun.lock` and Bun-oriented README commands.
   - [x] Commit the lockfile/doc update separately.
3. Bun repo automation
   - [x] Review root scripts, CI, security scan, AGENTS guidance, and Claude hooks for npm-era assumptions.
   - [x] Fix repo automation and docs so `chronicle-web` workflows use Bun by default.
   - [x] Commit the repo-automation update separately.
4. Generated-output hygiene
   - [x] Review generated frontend output paths and current ignore rules.
   - [x] Fix `chronicle-web` so modern build artifacts do not dirty the worktree.
   - [x] Commit the repo-hygiene change separately.
5. Shared section-header primitive
   - [x] Review duplication across modern route headings and intro blocks.
   - [x] Fix the shell by extracting a reusable section-header component.
   - [x] Commit the refactor separately.
6. Shared stat-card primitive
   - [x] Review repeated metric-card markup in the modern overview and studies surfaces.
   - [x] Fix the duplication with a themed stat-card component.
   - [x] Commit the refactor separately.
7. Workbench route upgrade
   - [x] Review the placeholder workbench route for missing interaction and state.
   - [x] Fix it into a real modernization control surface with local state.
   - [x] Commit the route upgrade separately.
8. Shell preference persistence
   - [x] Review which shell controls reset unnecessarily across reloads.
   - [x] Fix sidebar and workbench preferences with persisted Zustand state.
   - [x] Commit persistence changes separately.
9. Router fallback and empty states
   - [x] Review the modern router for generic fallbacks and route dead ends.
   - [x] Fix it with an explicit not-found view and better empty-state messaging.
   - [x] Commit the router UX update separately.
10. Mobile and keyboard navigation
   - [x] Review the new shell for keyboard access and skip-navigation gaps.
   - [x] Fix skip links, focus targets, and mobile-nav affordances.
   - [x] Commit the accessibility slice separately.
11. Theme stability and form primitives
   - [x] Review the theme path and missing base controls needed for route migration.
   - [x] Fix theme rendering plus textarea/select/help-text primitives for the modern shell.
   - [x] Commit the stability and primitive additions separately.
12. Studies planning board depth
   - [x] Review the studies page for missing workflow detail and decision support.
   - [x] Fix it with richer cards, filters, persisted notes, and ownership/status signals.
   - [x] Commit the studies-board enhancement separately.
13. Post-wave reassessment and skill/automation creation
   - [x] Review the broader repo after the Bun-first and modern-shell wave.
   - [x] Fix the work queue by creating a Bun smoke automation and a Bun workflow local skill with `skill-creator`.
   - [x] Commit the refreshed checklist and skill/automation additions separately.

## Next Bun/React Checklist

1. Bun workflow drift guard
   - [x] Review the current GitHub Action and security workflow files for Bun-specific assumptions.
   - [x] Fix local and CI validation so workflow drift is caught before remote failures.
   - [x] Commit the workflow-audit slice separately.
2. Jest-on-Bun strategy
   - [ ] Review whether the legacy Jest suite should keep Node compatibility or migrate to `bun test`.
   - [ ] Fix the test runner strategy explicitly instead of leaving mixed expectations.
   - [ ] Commit the runner decision separately.
3. React 19 readiness audit
   - [ ] Review `chronicle-web` dependencies for React 19 compatibility, especially `lattice-ui-kit`, Material UI 4, and Jest adapters.
   - [ ] Fix the dependency graph or blockers needed for a safe React runtime upgrade.
   - [ ] Commit the compatibility audit separately from the actual React bump.
4. Legacy shell cutover plan
   - [ ] Review how the Bun/modern shell should coexist with `src/index.js` and the Webpack app.
   - [ ] Fix the route-cutover strategy so modern routes can become user-facing incrementally.
   - [ ] Commit the cutover plan/doc or bootstrap change separately.
5. Institutional SSO contract
   - [ ] Review `chronicle-server` auth entry points, cookies, redirects, and logout behavior.
   - [ ] Fix the server/web contract so institutional SSO replaces bootstrap-token assumptions cleanly.
   - [ ] Commit the backend + web contract change together.
6. Replace bootstrap-token auth
   - [ ] Review every remaining dependency on `config.json` token bootstrap.
   - [ ] Fix the testing bootstrap into a documented temporary path or remove it once SSO exists.
   - [ ] Commit only the bootstrap-hardening or bootstrap-removal slice.
7. API/data-layer modernization
   - [ ] Review which current Redux Saga / Immutable flows should migrate first to RTK Query and plain TS objects.
   - [ ] Fix the first shared API/data adapter needed for live route migration.
   - [ ] Commit the adapter and state slice separately.
8. Flow retirement strategy
   - [ ] Review whether the repo will perform real TS migration or preserve Flow in legacy surfaces for a longer period.
   - [ ] Fix docs, scripts, and validation to match that decision instead of implying both paths equally.
   - [ ] Commit the language-strategy update separately.
9. Component migration backlog
   - [ ] Review the highest-traffic `lattice-ui-kit` / styled-components surfaces still blocking route migration.
   - [ ] Fix the next reusable primitive or feature slice needed to replace them.
   - [ ] Commit each component-migration slice independently.
10. E2E and visual coverage
   - [ ] Review whether the modern shell needs Playwright or another browser-level regression harness before route cutover.
   - [ ] Fix the missing coverage path for theme, auth bootstrap, and responsive navigation.
   - [ ] Commit the browser-test automation separately.

## Automation Added

- `scripts/chronicle-preflight.sh` checks toolchain and repo readiness.
- `scripts/chronicle-smoke.sh` runs a lightweight validation sweep and skips surfaces whose prerequisites are missing.
- `scripts/chronicle-web-bun-smoke.sh` runs the Bun-managed `chronicle-web` install/check/test/build loop in one place.
- `scripts/silent-failure-hunter.sh` scans for common silent-failure and swallowed-error patterns.
- `.codex/skills/chronicle-web-bun-workflow` captures the Bun-specific frontend workflow, touchpoints, and validation path.
