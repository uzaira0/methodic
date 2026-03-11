# Chronicle Memory

Updated: 2026-03-11

## Current State

- The monorepo has five active surfaces: `chronicle-server`, `chronicle-api`, `chronicle-web`, `chronicle` (Android), and shared `rhizome` libraries.
- Root Gradle validation could not run in this workspace because `java` and `JAVA_HOME` were not configured.
- `chronicle-web` now passes `bun run check`, `bun run test`, `bun run test:legacy -- --runInBand --watch=false`, and the web portion of `./scripts/chronicle-smoke.sh`.
- `chronicle-web` Bun tests now cover both the modern TypeScript shell and two migrated legacy helper tranches under `src/bun-legacy/`; Jest is now a narrower compatibility lane instead of the only test runtime.
- The current web auth contract is: bootstrap JWT from `config.json` for testing, exchange it for backend-managed cookies, keep JWT state in memory only, and treat interactive SSO as future work.
- The requested TypeScript error-catching spec has been mapped onto `chronicle-web/`, but the frontend is still Flow-based. `chronicle-web/tsconfig.app.json` is a forward-looking policy scaffold rather than full source coverage.
- `chronicle-web` is now Bun-managed for install, lockfile, script execution, and the modern HTML build/dev/preview loop. Node is still present as a compatibility runtime for the legacy Jest/webpack stack while those tools remain in place.
- `chronicle-web` ESLint warnings still document legacy debt, but blocking errors are now under control in the requested gate.

## Verified Signals

- `bun run test` in `chronicle-web/` is green.
- `bun run test:legacy -- --runInBand --watch=false` in `chronicle-web/` is green.
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
2. Bun test-lane split
   - [x] Review the Flow-era Jest surface and the new TypeScript/modern-shell surface separately.
   - [x] Fix the runner strategy by making Bun-native tests the default modern lane and isolating legacy Jest as a Node compatibility lane.
   - [x] Commit the runner split separately.
3. React 19 blocker audit
   - [x] Review `chronicle-web` dependencies for React 19 compatibility, especially `lattice-ui-kit`, Material UI 4, and the React bindings around the legacy shell.
   - [x] Fix the audit path so it emits checked-in markdown and JSON reports plus a non-zero `--check` mode while blockers remain.
   - [x] Commit the compatibility audit separately from the actual React bump.
4. Legacy shell cutover plan
   - [ ] Review how the Bun/modern shell should coexist with `src/index.js` and the Webpack app.
   - [ ] Fix the route-cutover strategy so modern routes can become user-facing incrementally.
   - [ ] Commit the cutover plan/doc or bootstrap change separately.
5. Institutional SSO contract
   - [ ] Review `chronicle-server` auth entry points, cookies, redirects, and logout behavior.
   - [ ] Fix the server/web contract so institutional SSO replaces bootstrap-token assumptions cleanly.
   - [ ] Commit the backend + web contract change together.
6. Replace bootstrap-token auth
   - [x] Review every remaining dependency on `config.json` token bootstrap.
   - [x] Fix the testing bootstrap into a documented temporary path or remove it once SSO exists.
   - [x] Commit only the bootstrap-hardening or bootstrap-removal slice.
7. API/data-layer modernization
   - [x] Review which current Redux Saga / Immutable flows should migrate first to RTK Query and plain TS objects.
   - [x] Fix the first shared API/data adapter by moving the modern studies planning surface behind an RTK Query slice and store middleware.
   - [x] Commit the adapter and state slice separately.
8. Flow legacy-lane strategy
   - [x] Review whether the repo will perform real TS migration or preserve Flow in legacy surfaces for a longer period.
   - [x] Fix docs, scripts, and validation to match the current decision: TypeScript for the modern shell, Flow retained explicitly as a legacy compatibility lane.
   - [x] Commit the language-strategy update separately.
9. Component migration backlog
   - [x] Review the highest-traffic `lattice-ui-kit` / styled-components surfaces still blocking route migration.
   - [x] Fix the next reusable primitive by extracting a shared modern-shell state panel and replacing duplicated loading/error/empty layouts.
   - [x] Commit the component-migration slice independently.
10. E2E and visual coverage
   - [x] Review whether the modern shell needs Playwright or another browser-level regression harness before route cutover.
   - [x] Fix the missing coverage path for theme, auth bootstrap, and responsive navigation with a Bun-run Playwright lane.
   - [x] Commit the browser-test automation separately.
11. Legacy Jest retirement tranche
   - [x] Review which remaining legacy helper suites can move to Bun without dragging in the full React/jsdom/Jest stack.
   - [x] Fix the first migration batch by converting config/bootstrap/axios helper coverage to Bun and shrinking the Jest compatibility lane.
   - [x] Commit the Bun migration tranche separately.
12. Legacy auth-utils Bun tranche
   - [x] Review which remaining auth/token utility tests are still pure enough to move off Jest next.
   - [x] Fix the second migration batch by converting auth token, expiration, CSRF, and user-role helpers to Bun.
   - [ ] Commit the auth-utils Bun tranche separately.

## Automation Added

- `scripts/chronicle-preflight.sh` checks toolchain and repo readiness.
- `scripts/chronicle-smoke.sh` runs a lightweight validation sweep and skips surfaces whose prerequisites are missing.
- `scripts/chronicle-web-bun-smoke.sh` runs the Bun-managed `chronicle-web` install/check/test/build loop in one place.
- `scripts/silent-failure-hunter.sh` scans for common silent-failure and swallowed-error patterns.
- `.codex/skills/chronicle-web-bun-workflow` captures the Bun-specific frontend workflow, touchpoints, and validation path.
