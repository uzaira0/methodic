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

## Current 20-Item Execution Checklist

1. `common/components/buttons/index.js` export hygiene
   - [x] Review the current named-only export surface and whether the lint warning is avoidable without breaking imports.
   - [x] Fix the warning with the smallest export-shape change.
   - [x] Commit the cleanup separately.
2. `common/components/errors/BasicErrorComponent.js` prop validation
   - [x] Review the component props and current render assumptions.
   - [x] Fix missing propTypes for `children` and `error`.
   - [x] Commit the cleanup separately.
3. `common/constants/testing/index.js` export hygiene
   - [x] Review whether the testing constants should be default-exported.
   - [x] Fix the warning without breaking existing imports.
   - [x] Commit the cleanup separately.
4. `common/utils/testing/index.js` export hygiene
   - [x] Review the testing utility barrel export shape.
   - [x] Fix the warning without breaking existing imports.
   - [x] Commit the cleanup separately.
5. `containers/dashboard/components/constants.js` export hygiene
   - [x] Review the constants module export surface.
   - [x] Fix the warning with the least disruptive export change.
   - [x] Commit the cleanup separately.
6. `containers/enrollment/EnrollmentLink.js` useless fragment
   - [x] Review the current enrollment-link render tree.
   - [x] Fix the fragment warning while preserving behavior.
   - [x] Commit the cleanup separately.
7. `containers/study/ParticipantsTable.js` unstable nested component
   - [x] Review the nested render helper that currently trips the React warning.
   - [x] Fix it by extracting or stabilizing the component usage.
   - [x] Commit the cleanup separately.
8. `containers/study/components/ChangeEnrollmentModal.js` effect dependencies
   - [x] Review the effect logic and dependency expectations.
   - [x] Fix the missing dependency warning without changing user-facing behavior.
   - [x] Commit the cleanup separately.
9. `containers/study/components/CreateStudyForm.js` memo and fragment warnings
   - [x] Review the `useMemo` dependency contract and JSX fragment usage.
   - [x] Fix both warnings while keeping form behavior stable.
   - [x] Commit the cleanup separately.
10. `containers/study/components/ParticipantInfoModal.js` effect dependencies
   - [x] Review the state sync effect and current dependency omissions.
   - [x] Fix the warning without introducing loops.
   - [x] Commit the cleanup separately.
11. `containers/study/components/ParticipantRow.js` memo dependencies
   - [x] Review the memoized row-data path.
   - [x] Fix the dependency warning without changing row behavior.
   - [x] Commit the cleanup separately.
12. `containers/study/components/StudyDetails.js` propTypes surface
   - [x] Review the actual prop usage across `study` and `limits`.
   - [x] Fix the propTypes warning cluster.
   - [x] Commit the cleanup separately.
13. `containers/survey/DailyAppUsageSurvey.js` propTypes surface
   - [x] Review the required props.
   - [x] Fix missing propTypes.
   - [x] Commit the cleanup separately.
14. `containers/survey/HourlyAppUsageSurvey.js` propTypes surface
   - [x] Review the required props.
   - [x] Fix missing propTypes.
   - [x] Commit the cleanup separately.
15. `containers/survey/components/HourlySurvey.js` propTypes surface
   - [x] Review the Immutable-backed props used by the component.
   - [x] Fix the missing propTypes with shapes broad enough for the current data model.
   - [x] Commit the cleanup separately.
16. `containers/survey/components/HourlySurveyInstructions.js` propTypes surface
   - [x] Review the button and step props.
   - [x] Fix missing propTypes.
   - [x] Commit the cleanup separately.
17. `containers/survey/components/HourlyUsageSurveyAppBar.js` propTypes surface
   - [x] Review the progress-step prop usage.
   - [x] Fix missing propTypes.
   - [x] Commit the cleanup separately.
18. `containers/survey/components/InstructionsModal.js` propTypes surface
   - [x] Review the modal prop usage.
   - [x] Fix missing propTypes.
   - [x] Commit the cleanup separately.
19. `containers/survey/components/SelectAppUsageTimeSlots.js` propTypes surface
   - [x] Review the list/map prop usage and callback requirements.
   - [x] Fix missing propTypes.
   - [x] Commit the cleanup separately.
20. `containers/survey/components/SelectAppsByUser.js` propTypes surface
   - [x] Review the apps data and selection props.
   - [x] Fix missing propTypes.
   - [x] Commit the cleanup separately.

## Current 20-Item Execution Checklist: Round 2

1. `common/utils/authenticatedDownload.js` console-path cleanup
   - [x] Review whether the current console output should become logger-based or be removed.
   - [x] Fix the warning without hiding actionable download failures.
   - [x] Commit the cleanup separately.
2. `containers/survey/components/SubmissionFailureModal.js` propTypes surface
   - [x] Review the modal prop usage.
   - [x] Fix missing propTypes.
   - [x] Commit the cleanup separately.
3. `containers/survey/components/SurveyButtons.js` propTypes surface
   - [x] Review the survey button props.
   - [x] Fix missing propTypes.
   - [x] Commit the cleanup separately.
4. `containers/survey/components/SurveyForm.js` propTypes surface
   - [x] Review the form props and request-state usage.
   - [x] Fix missing propTypes.
   - [x] Commit the cleanup separately.
5. `containers/tud/TimeUseDiaryContainer.js` effect dependencies
   - [x] Review the language-change effect and its dependency contract.
   - [x] Fix the missing dependency warning without changing flow behavior.
   - [x] Commit the cleanup separately.
6. `containers/tud/TimeUseDiaryDashboard.js` useless fragment
   - [x] Review the current dashboard render branch.
   - [x] Fix the fragment warning while preserving layout.
   - [x] Commit the cleanup separately.
7. `containers/tud/TimeUseDiarySelectors.js` export hygiene
   - [x] Review the selector export surface.
   - [x] Fix the warning with the least disruptive export change.
   - [x] Commit the cleanup separately.
8. `containers/tud/components/QuestionnaireForm.js` propTypes surface
   - [x] Review the full questionnaire-form prop contract.
   - [x] Fix the missing propTypes cluster.
   - [x] Commit the cleanup separately.
9. `containers/tud/components/TimeUseSummary.js` propTypes surface
   - [x] Review the summary component props.
   - [x] Fix missing propTypes.
   - [x] Commit the cleanup separately.
10. `containers/tud/constants/GeneralConstants.js` export hygiene
   - [x] Review the constants module export surface.
   - [x] Fix the warning with the least disruptive export change.
   - [x] Commit the cleanup separately.
11. `core/api/authorizations/index.js` export hygiene
   - [x] Review the API barrel export surface.
   - [x] Fix the warning with the least disruptive export change.
   - [x] Commit the cleanup separately.
12. `core/api/organization/index.js` export hygiene
   - [x] Review the API barrel export surface.
   - [x] Fix the warning with the least disruptive export change.
   - [x] Commit the cleanup separately.
13. `core/api/principal/index.js` export hygiene
   - [x] Review the API barrel export surface.
   - [x] Fix the warning with the least disruptive export change.
   - [x] Commit the cleanup separately.
14. `core/redux/reducers/index.js` export hygiene
   - [x] Review the reducer barrel export surface.
   - [x] Fix the warning with the least disruptive export change.
   - [x] Commit the cleanup separately.
15. `core/router/DefaultUnauthorized.js` unstable nested component
   - [x] Review the nested component/render helper warning.
   - [x] Fix or locally document the stable render path.
   - [x] Commit the cleanup separately.
16. `core/tracking/google/GoogleAnalytics.js` export hygiene
   - [x] Review the analytics export surface.
   - [x] Fix the warning with the least disruptive export change.
   - [x] Commit the cleanup separately.
17. `index.js` enrollment/bootstrap console path
   - [x] Review current `console.error` usage in bootstrap failure handling.
   - [x] Fix the warning without losing startup diagnostics.
   - [x] Commit the cleanup separately.
18. Residual survey component propTypes sweep
   - [x] Review any remaining survey-component propType gaps after items 2-4 land.
   - [x] Fix the remaining gaps if new warnings appear.
   - [x] Commit the cleanup separately.
19. Residual TUD component propTypes sweep
   - [x] Review any remaining TUD propType gaps after items 8-9 land.
   - [x] Fix the remaining gaps if new warnings appear.
   - [x] Commit the cleanup separately.
20. Post-round reassessment
   - [x] Review the repo after the second 20-item pass.
   - [x] Fix the work queue by generating the next execution checklist from the remaining warning and modernization surface.
   - [x] Commit the updated work queue separately.

## Current 20-Item Execution Checklist: Round 3

1. Institutional SSO backend contract
   - [x] Review `chronicle-server` authentication entry points, redirects, cookies, and logout assumptions tied to Auth0.
   - [x] Fix the contract design for institutional SSO replacement.
   - [x] Commit the contract/doc changes separately.
2. Auth0 dependency inventory in `chronicle-server`
   - [x] Review remaining `Auth0Pod`, `Auth0Configuration`, and Auth0-specific user services.
   - [x] Fix the inventory into an actionable migration map.
   - [x] Commit the audit/update separately.
3. Redirect and SSRF allowlist modernization
   - [x] Review Auth0-specific domains in redirect and SSRF configs.
   - [x] Fix the config strategy for future institutional SSO domains.
   - [x] Commit the config/documentation changes separately.
4. React 19 blocker removal: `react-redux`
   - [x] Review the current React-Redux usage surface and compatibility blocker.
   - [x] Fix or isolate the blocker toward a React 19-safe path.
   - [x] Commit the migration slice separately.
5. React 19 blocker removal: Material UI 4
   - [ ] Review `@material-ui/core`, `@material-ui/lab`, and `@material-ui/pickers` usage.
   - [ ] Fix the next replacement tranche toward shadcn/Radix/Tailwind components.
   - [ ] Commit the migration slice separately.
6. Modern route cutover plan for `src/index.js`
   - [ ] Review how the legacy and modern shells should coexist at runtime.
   - [ ] Fix the next user-facing route cutover step.
   - [ ] Commit the cutover slice separately.
7. Questionnaire route modernization
   - [ ] Review the questionnaire surfaces still tied to `lattice-ui-kit` and styled-components.
   - [ ] Fix the next questionnaire route migration tranche.
   - [ ] Commit the route migration separately.
8. Time Use Diary UI modernization
   - [ ] Review TUD surfaces still tied to `lattice-ui-kit` and styled-components.
   - [ ] Fix the next TUD UI migration tranche.
   - [ ] Commit the route migration separately.
9. Remaining Jest compatibility lane reduction
   - [x] Review the seven remaining legacy Jest suites for Bun migration candidates.
   - [x] Fix the next Bun migration tranche.
   - [x] Commit the migration slice separately.
10. Flow-to-Bun runtime compatibility in shared legacy modules
   - [ ] Review which remaining legacy utility modules still block direct Bun imports because of Flow syntax.
   - [ ] Fix the next runtime-compatible helper cluster.
   - [ ] Commit the compatibility slice separately.
11. Redux Saga reduction in study/org flows
   - [ ] Review the highest-traffic saga-based flows still untouched.
   - [ ] Fix the next RTK/RTK Query migration tranche.
   - [ ] Commit the state migration separately.
12. `lattice-ui-kit` dependency surface audit
   - [x] Review remaining import volume and highest-risk dependency hotspots.
   - [x] Fix the audit into a prioritized replacement map.
   - [x] Commit the audit/update separately.
13. `styled-components` dependency surface audit
   - [x] Review remaining styled-components usage and route concentration.
   - [x] Fix the audit into a prioritized replacement map.
   - [x] Commit the audit/update separately.
14. Legacy auth bootstrap removal path
   - [x] Review every remaining dependency on `/chronicle/config.json`.
   - [x] Fix the next removal or isolation tranche toward institutional SSO.
   - [x] Commit the auth migration slice separately.
15. LocalStorage user-info dependency review
   - [x] Review remaining `AUTH0_USER_INFO` / browser storage reads in legacy code.
   - [x] Fix the next reduction tranche.
   - [x] Commit the cleanup separately.
16. Browser smoke expansion
   - [ ] Review the current Playwright coverage for the modern shell.
   - [ ] Fix the next representative route/theme/auth smoke scenarios.
   - [ ] Commit the E2E slice separately.
17. Root JVM validation readiness
   - [x] Review what is still blocked locally because of missing Java and whether the scripts should enforce clearer behavior.
   - [x] Fix the preflight/smoke messaging or validation flow.
   - [x] Commit the automation update separately.
18. Docker and deployment doc reconciliation
   - [x] Review the overlapping local/prod/Traefik deployment docs.
   - [x] Fix the next documentation reconciliation tranche.
   - [x] Commit the doc update separately.
19. Skill and automation refresh after lint burn-down
   - [x] Review whether the existing local skills and smoke scripts reflect the new warning-free web gate.
   - [x] Fix any stale guidance or missing automations.
   - [x] Commit the skill/automation update separately.
20. Post-round reassessment
   - [x] Review the repo after the third 20-item pass.
   - [x] Fix the work queue by generating the next execution checklist from the remaining modernization surface.
   - [x] Commit the updated work queue separately.

## Remaining Round 3 Execution Order

1. React 19 blocker removal: `react-redux`
2. React 19 blocker removal: Material UI 4
3. Modern route cutover plan for `src/index.js`
4. Remaining Jest compatibility lane reduction
5. Flow-to-Bun runtime compatibility in shared legacy modules
6. Redux Saga reduction in study/org flows
7. Browser smoke expansion
8. Questionnaire route modernization
9. Time Use Diary UI modernization

## Automation Added

- `scripts/chronicle-preflight.sh` checks toolchain and repo readiness.
- `scripts/chronicle-smoke.sh` runs a lightweight validation sweep and skips surfaces whose prerequisites are missing.
- `scripts/chronicle-web-bun-smoke.sh` runs the Bun-managed `chronicle-web` install/check/test/build loop in one place.
- `scripts/check-sso-drift.sh` audits remaining Auth0 wiring, bootstrap-token paths, and legacy user-storage touchpoints.
- `scripts/silent-failure-hunter.sh` scans for common silent-failure and swallowed-error patterns.
- `.codex/skills/chronicle-web-bun-workflow` captures the Bun-specific frontend workflow, touchpoints, and validation path.
- `.codex/skills/chronicle-institutional-sso` captures the Auth0-to-SSO migration workflow and drift-audit command.
