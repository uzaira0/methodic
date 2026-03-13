# Chronicle Memory

Updated: 2026-03-13

## Current State

- The monorepo has five active surfaces: `chronicle-server`, `chronicle-api`, `chronicle-web`, `chronicle` (Android), and shared `rhizome` libraries.
- Root Gradle validation could not run in this workspace because `java` and `JAVA_HOME` were not configured.
- `chronicle-web` now passes `bun run check`, `bun run test`, `bun run test:legacy -- --runInBand --watch=false`, and the web portion of `./scripts/chronicle-smoke.sh`.
- `chronicle-web` Bun tests now cover both the modern TypeScript shell and two migrated legacy helper tranches under `src/bun-legacy/`; Jest is now a narrower compatibility lane instead of the only test runtime.
- `chronicle-web` bootstrap/auth helper coverage now runs under Bun for `fetchBootstrapToken`, `exchangeBootstrapToken`, `resolveLegacyBootstrapToken`, `storeAuthInfo`, `clearAuthInfo`, `logoutCookieSession`, and the shell-routing helpers.
- `chronicle-web` route guards and Axios refresh now replay the temporary bootstrap auth flow instead of treating `AUTH_ATTEMPT` as a dead-end. The auth reducer also clears `isAuthenticating` on failure again, and legacy `auth0_user_info` storage is now migrated forward into the Chronicle storage key at runtime.
- `chronicle-web` auth storage helpers now use provider-neutral symbol names while still cleaning up legacy browser storage values, and the Bun test lane covers that migration behavior.
- `chronicle-api` and `chronicle-server` now expose provider-neutral user-search DTO naming through `UserSearchFields`, reducing Auth0-specific naming in the public API and controller/service layer.
- `chronicle-api` principal user endpoints now expose a Chronicle-owned `ChronicleUserProfile` DTO instead of leaking Auth0 `User` objects across the shared module boundary. `chronicle-server` maps directory users into that DTO for controller responses and test Retrofit clients.
- The participant dashboard deep link now cuts over to the modern shell at `/participant` and `/chronicle/participant`, with browser coverage proving the new route loads and handles missing query params explicitly.
- The direct `/studies`, `/chronicle/studies`, `/dashboard`, and `/chronicle/dashboard` entrypoints now cut over to the modern shell, which makes the modern studies board and dashboard routes user-facing instead of `/modern`-only.
- The study questionnaire admin surface no longer depends on `lattice-ui-kit`, `styled-components`, or FontAwesome for its active list/builder/modal UI. That route now uses the modern card/button/dialog primitives and passes `bun run check`.
- Study-admin deep links for `/studies/:studyId/questionnaires` and `/studies/:studyId/time-use-diary` now load directly in the modern shell. Those routes are backed by a new RTK Query slice, direct route-cutover matching, Bun tests, and Playwright coverage instead of the legacy shell.
- The legacy study shell tabs no longer depend on `styled-components` or `lattice-ui-kit` layout primitives, reducing another active legacy UI anchor in the study route family.
- The legacy survey and Time Use Diary entry routes no longer depend on `GET_STUDY_SETTINGS` or `VERIFY_PARTICIPANT` saga/request-state bootstrapping. They now fetch study settings and participant validity locally through `useLegacyStudyBootstrap`, which removes another active saga/Immutable dependency from user-facing route startup.
- The legacy participant dashboard and study details panel no longer depend on `lattice-ui-kit` layout primitives or `styled-components`, reducing two more active study/participant UI surfaces still rendered through the legacy shell.
- The active survey and TUD helper components for dialogs, success states, buttons, the TUD header, and the TUD progress bar no longer depend on `lattice-ui-kit` or `styled-components`. Those flows now use a local `SimpleDialog` plus plain HTML/CSS helpers instead of the old UI kit for those surfaces.
- The study participant info modal no longer depends on `lattice-ui-kit` or the `updateParticipantAnnotations` saga/request-sequence path. It now saves annotations directly through the study API and uses the shared `SimpleDialog` helper.
- The study dashboard shell no longer depends on `styled-components` or `lattice-ui-kit` grid wrappers for its top-level layout, reducing another active legacy wrapper in the study route family.
- `chronicle-server` now has direct controller-level coverage for `/chronicle/v3/auth/session`, `/chronicle/v3/auth/testing-login`, `/chronicle/v3/auth/set-cookie`, and `/chronicle/v3/auth/logout` behavior via `AuthTokenControllerTest`. Server-side auth/runtime migration and contract checks now execute in this workspace when `JAVA_HOME` points at a valid JDK.
- Docker auth config artifacts now use `chronicle-auth.yaml` naming, and deployment templates/scripts are aligned with that migration.
- Root docs and Docker docs now describe the active `/chronicle/v3/auth/session` and `/chronicle/v3/auth/testing-login` flow instead of promoting `/chronicle/config.json` as the current web contract. A new shared-contract review doc also records the remaining `chronicle-api` Auth0 DTO coupling and the current Android impact.
- Repo automation now includes a dedicated server auth smoke script and a repo-local `chronicle-server-auth-contract` skill for controller, cookie, and JVM CI work.
- The current web auth contract is: check `/chronicle/v3/auth/session`, use `/chronicle/v3/auth/testing-login` only in test-friendly environments, exchange manual JWTs only through `/chronicle/v3/auth/set-cookie`, and keep the long-lived session in backend-managed cookies while institutional SSO remains future work.
- The requested TypeScript error-catching spec has been mapped onto `chronicle-web/`, but the frontend is still Flow-based. `chronicle-web/tsconfig.app.json` is a forward-looking policy scaffold rather than full source coverage.
- `chronicle-web` is now Bun-managed for install, lockfile, script execution, and the modern HTML build/dev/preview loop. Node is still present as a compatibility runtime for the legacy Jest/webpack stack while those tools remain in place.
- `chronicle-web` ESLint warnings still document legacy debt, but blocking errors are now under control in the requested gate.

## Verified Signals

- `bun run test` in `chronicle-web/` is green.
- `bun run test:legacy -- --runInBand --watch=false` in `chronicle-web/` is green.
- `bun run check` in `chronicle-web/` is green.
- `bun run modern:build`, `bun run modern:dev`, and `bun run modern:preview` all work in `chronicle-web/`.
- `./scripts/chronicle-smoke.sh` is green except for JVM steps previously skipped when Java was unavailable locally.
- `./scripts/chronicle-server-auth-smoke.sh` exists as the dedicated JVM smoke entry for the server auth/session contract.
- `./scripts/chronicle-server-auth-smoke.sh` runs successfully in this workspace with `JAVA_HOME=/home/uzair/.local/jdks/temurin-21` and compiles+tests `chronicle-server` auth/session paths including `AuthTokenControllerTest`.
- `./scripts/chronicle-web-bootstrap-smoke.sh` is green and now catches order-dependent Bun test failures in the startup/auth boundary.
- `./scripts/check-sso-drift.sh` now reports Auth0-specific symbol names separately from expected legacy storage-cleanup literals, and the symbol-name audit is green.
- `bun run e2e` in `chronicle-web/` now covers the participant dashboard deep link in addition to the `/modern` and `/chronicle/modern` route set.
- `./scripts/chronicle-web-route-cutover-smoke.sh` now validates the broader direct-route cutover behavior through `/dashboard`, `/studies`, and `/participant`.
- `./scripts/chronicle-web-route-cutover-smoke.sh` remained green after the survey/TUD bootstrap bypass and the additional study-surface cleanup.
- `scripts/chronicle-server-auth-smoke.sh` now supports `CHRONICLE_GRADLE_PROJECT_CACHE_DIR`, which allows local execution on machines where the checked-out repo contains an unwritable project `.gradle` directory.
- A user-space Temurin JDK 21 is now available at `/home/uzair/.local/jdks/temurin-21`, and the server auth smoke now gets past the previous `java`/cache-path blocker into real Gradle project configuration and compilation.
- `./scripts/silent-failure-hunter.sh` finds only existing `console.error` sites, not swallowed catches or `queueMicrotask` patterns.
- Backend support for the new auth flow exists in `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/AuthTokenController.kt` and related security config.
- Repo automation added:
  - `scripts/chronicle-preflight.sh`
  - `scripts/chronicle-smoke.sh`
  - `scripts/chronicle-web-bootstrap-smoke.sh`
  - `scripts/silent-failure-hunter.sh`
  - `.claude/settings.json` hooks for secret protection and post-edit web linting
  - `.github/workflows/ci.yml` for web checks, JVM smoke, compose validation, and silent-failure scanning

## Active Modernization Checklist

## Current 12-Step Execution Checklist

1. Replace `lattice-ui-kit`, Material UI 4 surfaces, and `styled-components` across `chronicle-web`
   - [x] Review the highest-traffic questionnaire admin surface still using the legacy UI stack.
   - [x] Fix the questionnaire admin list/builder/modal surface to use the modern UI primitives instead of `lattice-ui-kit`, `styled-components`, and FontAwesome.
   - [x] Commit the questionnaire admin modernization in `chronicle-web`.
2. Cut real product routes over to the modern shell until the legacy shell is no longer the default path
   - [x] Review the next study-admin and participant-facing routes still pinned to the legacy shell.
   - [x] Fix the next route tranche by cutting study questionnaire and study TUD admin routes into the modern shell and validating deep links.
   - [x] Commit the route-cutover tranche separately.
3. Retire Flow from `chronicle-web` and make touched frontend modules JS/TS-compatible
   - [x] Review the route and component files touched in the next tranche for Flow-only syntax.
   - [x] Fix the touched questionnaire and TUD bridge files so they run in the Bun/modern lane without Flow syntax dependency.
   - [x] Commit the touched-file Flow retirement separately.
4. Reduce and remove legacy Redux Saga, Immutable, and `redux-reqseq` usage
   - [x] Review the questionnaire, TUD, and study-admin data paths for the highest-value state migration slice.
   - [x] Fix the next slice by moving the study questionnaire and study TUD admin routes onto RTK Query instead of saga/Immutable-backed fetch flows.
   - [x] Commit the state migration separately.
5. Restore real JVM validation for `chronicle-server`
   - [x] Review local and CI prerequisites for Gradle/JVM validation now that server auth work has landed.
   - [x] Fix the repo automation/docs so server validation is runnable and explicit when Java is available.
   - [x] Commit the JVM validation readiness update separately.
6. Add direct server-side auth/session tests
   - [x] Review existing `chronicle-server` test patterns and the current auth/session controller contract.
   - [x] Fix the missing coverage by adding direct tests for session, testing-login, cookies, logout, and CSRF behavior.
   - [x] Commit the auth/session server tests separately.
7. Consolidate deployment and auth configuration
   - [x] Review the remaining Docker, Traefik, and doc references to `Auth0` and `/chronicle/config.json`.
   - [x] Fix the deployment/auth docs and runtime guidance outside the user-edited Traefik compose file to match the current server-session bridge.
   - [x] Commit the deployment/auth consolidation separately.
8. Expand repo automations and local skills
   - [x] Review which of the new migration checks still require manual repetition.
   - [x] Fix the gap by adding or updating automations/skills for the current route, auth, and validation boundary.
   - [ ] Commit the automation/skill tranche separately.
9. Fully modernize questionnaire and TUD flows into the new UI/state stack
   - [x] Review the remaining TUD and questionnaire routes for the next end-to-end modernization slice.
   - [x] Fix the next admin flow by modernizing the study questionnaire and study TUD routes with the new UI/state stack.
   - [x] Commit the flow modernization separately.
10. Expand browser and integration coverage beyond smoke tests
   - [x] Review the migrated questionnaire/TUD/study routes for missing browser-level assertions.
   - [x] Fix the coverage gap with direct Playwright deep-link assertions and Bun route tests for the new study-admin routes.
   - [x] Commit the coverage expansion separately.
11. Reconcile and document API/server/web contracts
   - [x] Review the active auth/session/bootstrap and route-cutover contracts across server, API, and web.
   - [x] Fix the contract docs and mismatched guidance uncovered by the review.
   - [x] Commit the contract reconciliation separately.
12. Review Android and `chronicle-api` impacts and align shared contracts
   - [x] Review Android and `chronicle-api` touchpoints affected by the auth and DTO migration work.
   - [x] Fix the repo guidance by documenting the current Android/API findings and remaining provider-specific DTO debt.
   - [x] Commit the Android/API alignment tranche separately.

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
   - [x] Review `@material-ui/core`, `@material-ui/lab`, and `@material-ui/pickers` usage.
   - [x] Fix the next replacement tranche toward shadcn/Radix/Tailwind components.
   - [x] Commit the migration slice separately.
6. Modern route cutover plan for `src/index.js`
   - [x] Review how the legacy and modern shells should coexist at runtime.
   - [x] Fix the next user-facing route cutover step.
   - [x] Commit the cutover slice separately.
7. Questionnaire route modernization
   - [x] Review the questionnaire surfaces still tied to `lattice-ui-kit` and styled-components.
   - [x] Fix the next questionnaire route migration tranche.
   - [x] Commit the route migration separately.
8. Time Use Diary UI modernization
   - [x] Review TUD surfaces still tied to `lattice-ui-kit` and styled-components.
   - [x] Fix the next TUD UI migration tranche.
   - [x] Commit the route migration separately.
9. Remaining Jest compatibility lane reduction
   - [x] Review the seven remaining legacy Jest suites for Bun migration candidates.
   - [x] Fix the next Bun migration tranche.
   - [x] Commit the migration slice separately.
10. Flow-to-Bun runtime compatibility in shared legacy modules
   - [x] Review which remaining legacy utility modules still block direct Bun imports because of Flow syntax.
   - [x] Fix the next runtime-compatible helper cluster.
   - [x] Commit the compatibility slice separately.
11. Redux Saga reduction in study/org flows
   - [x] Review the highest-traffic saga-based flows still untouched.
   - [x] Fix the next RTK/RTK Query migration tranche.
   - [x] Commit the state migration separately.
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
   - [x] Review the current Playwright coverage for the modern shell.
   - [x] Fix the next representative route/theme/auth smoke scenarios.
   - [x] Commit the E2E slice separately.
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

Round 3 complete.

## Current 20-Item Execution Checklist: Round 5

1. Legacy bootstrap style duplication audit
   - [x] Review the duplicated normalize/global-style setup across the legacy and enrollment shells.
   - [x] Fix the duplication by extracting a shared scaffold component.
   - [x] Commit the cleanup separately.
2. Shared legacy shell scaffold
   - [x] Review whether the legacy shell wrappers can share a single render frame without changing behavior.
   - [x] Fix the shell wrappers to use the shared scaffold.
   - [x] Commit the scaffold integration separately.
3. Shared bootstrap error renderer
   - [x] Review the repeated inline startup failure UI in the legacy entrypoint and shell bootstrap code.
   - [x] Fix the repetition with a shared bootstrap error renderer.
   - [x] Commit the renderer extraction separately.
4. Shell route helper extraction
   - [x] Review the inline enrollment and modern-route detection logic in `chronicle-web/src/index.js`.
   - [x] Fix the boundary by extracting shared shell-routing helpers.
   - [x] Commit the route-helper extraction separately.
5. Bun coverage for shell route helpers
   - [x] Review the new route helper behavior across enrollment and modern route prefixes.
   - [x] Fix the regression risk with Bun coverage for the helper module.
   - [x] Commit the test addition separately.
6. Legacy bootstrap token resolution extraction
   - [x] Review the existing-token versus `config.json` fallback logic inside `renderLegacyShell`.
   - [x] Fix the bootstrap path by extracting a dedicated resolution helper.
   - [x] Commit the helper extraction separately.
7. Bun coverage for legacy bootstrap resolution
   - [x] Review the token-resolution branches for valid existing tokens, config fallback, and no-token startup.
   - [x] Fix the regression risk with Bun coverage for the resolver.
   - [x] Commit the test addition separately.
8. Legacy shell logging cleanup
   - [x] Review the remaining startup diagnostics in `renderLegacyShell`.
   - [x] Fix the console-path drift by using the repo logger and shared bootstrap error rendering.
   - [x] Commit the logging cleanup separately.
9. Existing-token exchange failure handling
   - [x] Review whether the valid-existing-token path could still fail before app initialization.
   - [x] Fix the boundary so existing-token exchange now flows through the same failure-handling path.
   - [x] Commit the error-handling cleanup separately.
10. Shared auth endpoint constants
   - [x] Review the duplicated auth/bootstrap endpoint strings across legacy and modern code.
   - [x] Fix the duplication with a shared auth-endpoints module.
   - [x] Commit the constants extraction separately.
11. TypeScript typing for shared auth endpoints
   - [x] Review the modern TypeScript shell import path for the shared JS endpoint module.
   - [x] Fix the TS gate by adding declarations for the shared auth endpoints.
   - [x] Commit the typing addition separately.
12. Logout helper extraction
   - [x] Review the inline backend logout request in `clearAuthInfo`.
   - [x] Fix it by extracting a dedicated logout helper.
   - [x] Commit the helper extraction separately.
13. Bun coverage for logout helper
   - [x] Review the logout request contract for method and credential behavior.
   - [x] Fix the regression risk with Bun coverage for the helper.
   - [x] Commit the test addition separately.
14. `storeAuthInfo` Bun migration
   - [x] Review whether the remaining `storeAuthInfo` suite is pure enough to leave the Jest lane.
   - [x] Fix the lane split by rewriting `storeAuthInfo` coverage for Bun.
   - [x] Commit the Bun migration separately.
15. Retire Jest `storeAuthInfo` coverage
   - [x] Review whether the old Jest `storeAuthInfo` suite still provides unique coverage after the Bun rewrite.
   - [x] Fix the duplication by deleting the redundant Jest suite.
   - [x] Commit the Jest retirement separately.
16. `clearAuthInfo` Bun migration
   - [x] Review whether `clearAuthInfo` still needs Jest or can run as a pure Bun helper test.
   - [x] Fix the lane split by rewriting `clearAuthInfo` coverage for Bun.
   - [x] Commit the Bun migration separately.
17. Retire Jest `clearAuthInfo` coverage
   - [x] Review whether the old Jest `clearAuthInfo` suite still provides unique coverage after the Bun rewrite.
   - [x] Fix the duplication by deleting the redundant Jest suite.
   - [x] Commit the Jest retirement separately.
18. Route-cutover deep-link browser coverage
   - [x] Review whether direct `/modern/...` and `/chronicle/modern/...` deep links are covered in Playwright.
   - [x] Fix the gap with explicit browser tests for both basename entry paths.
   - [x] Commit the browser coverage expansion separately.
19. Focused bootstrap/auth smoke automation
   - [x] Review whether the startup/auth boundary has a repeatable focused validation path separate from the full route-cutover sweep.
   - [x] Fix the gap with `scripts/chronicle-web-bootstrap-smoke.sh`.
   - [x] Commit the smoke automation separately.
20. Bootstrap-boundary skill refresh
   - [x] Review whether the local skills reflect the new startup/auth helper boundary and focused smoke path.
   - [x] Fix the guidance by adding `.codex/skills/chronicle-web-bootstrap-boundary` and wiring it into repo docs.
   - [x] Commit the skill and guidance update separately.

## Current 20-Item Execution Checklist: Round 7

1. Shared legacy auth bootstrap replay helper
   - [x] Review the duplicated bootstrap-refresh logic across route guards and Axios refresh.
   - [x] Fix it with `core/auth/bootstrap/bootstrapLegacyAuthSession.js`.
   - [x] Commit the helper extraction separately.
2. Route guard bootstrap replay
   - [x] Review `core/router/AuthRoute.js` for expired-token dead ends.
   - [x] Fix the route guard to replay the bootstrap/session path before giving up.
   - [x] Commit the route-guard change separately.
3. Axios refresh/bootstrap alignment
   - [x] Review `core/api/axios/getApiAxiosInstance.js` for drift from the route bootstrap path.
   - [x] Fix Axios refresh so it reuses the same bootstrap replay helper.
   - [x] Commit the Axios runtime update separately.
4. Auth attempt saga dead-end removal
   - [x] Review `core/auth/sagas/authAttemptWatcher.js` for the current no-op failure path.
   - [x] Fix `AUTH_ATTEMPT` so it actually replays the temporary bootstrap flow.
   - [x] Commit the saga change separately.
5. Auth reducer failure-state fix
   - [x] Review `core/auth/reducers/index.js` for failure-state handling.
   - [x] Fix `AUTH_FAILURE` so it clears `isAuthenticating` and records expiration consistently.
   - [x] Commit the reducer update separately.
6. Legacy user-info storage migration
   - [x] Review `core/auth/utils/getUserInfo.js` for direct legacy-key reads.
   - [x] Fix it to migrate legacy Auth0-shaped browser storage into the Chronicle key on read.
   - [x] Commit the storage migration separately.
7. Auth storage key isolation
   - [x] Review auth utilities that still depend on the large Flow-only constants surface for storage/cookie keys.
   - [x] Fix that drift with `core/auth/storage/authStorageKeys.js`.
   - [x] Commit the storage-key extraction separately.
8. `storeAuthInfo` storage-key decoupling
   - [x] Review `core/auth/utils/storeAuthInfo.js` for direct dependency on global constants.
   - [x] Fix it to use the focused auth storage key module.
   - [x] Commit the cleanup separately.
9. `clearAuthInfo` storage-key decoupling
   - [x] Review `core/auth/utils/clearAuthInfo.js` for direct dependency on global constants.
   - [x] Fix it to use the focused auth storage key module.
   - [x] Commit the cleanup separately.
10. Bun coverage for bootstrap session replay
   - [x] Review whether the new bootstrap replay helper has direct coverage.
   - [x] Fix the gap with `bun-legacy/bootstrapLegacyAuthSession.test.js`.
   - [x] Commit the test addition separately.
11. Bun core-helper mock normalization
   - [x] Review `bun-legacy/core-helpers.test.js` for brittle mock state around auth refresh.
   - [x] Fix the test harness so it no longer pollutes the bootstrap helper lane.
   - [x] Commit the test cleanup separately.
12. Bun auth-utils mock normalization
   - [x] Review `bun-legacy/auth-utils.test.js` for direct-import drift after the runtime changes.
   - [x] Fix the mocks to match the runtime import graph.
   - [x] Commit the test cleanup separately.
13. Bun auth-storage mock normalization
   - [x] Review the Bun auth utility suites for partial mocks of the new storage-key module.
   - [x] Fix them to export the full auth storage key set consistently.
   - [x] Commit the test cleanup separately.
14. Dead `Auth0.js` runtime removal
   - [x] Review `core/auth/Auth0.js` for actual usage.
   - [x] Fix the stale runtime surface by deleting the unused file.
   - [x] Commit the removal separately.
15. Dead `Auth0AdminRoute.js` removal
   - [x] Review `core/router/Auth0AdminRoute.js` for actual usage.
   - [x] Fix the stale runtime surface by deleting the unused file.
   - [x] Commit the removal separately.
16. Dead `LOGIN` action/watcher removal
   - [x] Review the unused browser-login action/watcher path in the auth layer.
   - [x] Fix the stale path by removing `LOGIN` action plumbing and `loginWatcher.js`.
   - [x] Commit the removal separately.
17. Auth0 nonce naming cleanup
   - [x] Review `AUTH0_NONCE_STATE` and `Auth0NonceState` for actual usage.
   - [x] Fix the stale naming by removing the constant and renaming the unused type to `AuthSessionNonceState`.
   - [x] Commit the naming cleanup separately.
18. Dev token-copy labeling cleanup
   - [x] Review the development token-copy affordance in `containers/app/AppContainer.js`.
   - [x] Fix the stale Auth0 labeling and align it with the current bootstrap auth contract.
   - [x] Commit the UI cleanup separately.
19. SSO drift audit expansion
   - [x] Review `scripts/check-sso-drift.sh` for missing detection around stale web Auth0 symbols.
   - [x] Fix the audit so it catches dead Auth0 runtime artifacts if they reappear.
   - [x] Commit the automation update separately.
20. Smoke/doc enforcement for the auth cleanup
   - [x] Review whether root smoke and the Auth0/SSO docs still reflected the old web runtime.
   - [x] Fix `scripts/chronicle-smoke.sh`, `docs/AUTH0-DEPENDENCY-INVENTORY.md`, and `docs/INSTITUTIONAL-SSO-CONTRACT.md` to match the current runtime.
   - [x] Commit the automation/doc update separately.

## Current 20-Item Execution Checklist: Round 8

1. Institutional SSO server implementation
   - [ ] Review the concrete login, callback, logout, and session-refresh flow needed for institutional SSO in `chronicle-server`.
   - [ ] Fix the next backend implementation tranche so cookie-backed SSO can replace the temporary bootstrap-token path.
   - [ ] Commit the backend and contract changes separately.
2. Remaining Auth0 runtime removal
   - [x] Review the remaining `chronicle-server` runtime classes and configs that still depend on Auth0 types or naming.
   - [x] Fix the next removal tranche without breaking current testing auth.
   - [x] Commit the Auth0 retirement slice separately.
3. React 19 runtime upgrade path
   - [ ] Review which remaining legacy dependencies still block upgrading `react` and `react-dom`.
   - [ ] Fix the next compatibility tranche toward a real React 19 upgrade.
   - [ ] Commit the runtime-compatibility slice separately.
4. Remaining Jest-to-Bun migration
   - [ ] Review the remaining jsdom-heavy Jest suites for realistic Bun or Playwright conversion candidates.
   - [ ] Fix the next migration tranche to shrink the Jest compatibility lane further.
   - [ ] Commit the test migration separately.
5. Flow compatibility lane reduction
   - [ ] Review the highest-churn Flow files still sitting on the legacy bootstrap and route boundary.
   - [ ] Fix the next Flow-to-plain-JS or Flow-to-TS compatibility tranche.
   - [ ] Commit the language-lane reduction separately.
6. Survey route modernization
   - [ ] Review the hourly and daily survey routes still tied to `lattice-ui-kit` and styled-components.
   - [ ] Fix the next survey route migration tranche with the modern component stack.
   - [ ] Commit the route migration separately.
7. Participant dashboard modernization
   - [x] Review the participant dashboard shell and quick-action surfaces for the next modernization slice.
   - [x] Fix the next participant-facing route tranche with the modern UI primitives.
   - [x] Commit the route migration separately.
8. Study list modernization
   - [x] Review the legacy study list and org-study table surfaces for the next cutover target.
   - [x] Fix the next study-list migration tranche in the modern shell.
   - [x] Commit the route migration separately.
9. Study detail and settings modernization
   - [ ] Review the study detail, study settings, and participant-management surfaces for the next cutover target.
   - [ ] Fix the next study-management route tranche in the modern shell.
   - [ ] Commit the route migration separately.
10. Legacy/modern browser regression expansion
   - [ ] Review what is still untested across the webpack-served `/modern` route prefix and the Bun preview route set.
   - [ ] Fix the next browser-smoke tranche so both entry paths are covered.
   - [ ] Commit the browser test expansion separately.
11. Webpack-served `/modern` smoke coverage
   - [ ] Review whether the mixed webpack shell serves the modern routes with the same basename behavior as Bun preview.
   - [ ] Fix the gap with an automated webpack-served route smoke.
   - [ ] Commit the mixed-runtime smoke expansion separately.
12. Material UI 4 removal from legacy shell
   - [ ] Review the remaining Material UI 4 providers and components still coupled to the legacy shell.
   - [ ] Fix the next removal tranche toward a React 19-safe stack.
   - [ ] Commit the dependency removal separately.
13. `lattice-ui-kit` hotspot replacement tranche
   - [ ] Review the highest-traffic `lattice-ui-kit` surfaces still blocking route migration.
   - [ ] Fix the next replacement tranche with the modern component stack.
   - [ ] Commit the dependency reduction separately.
14. `styled-components` hotspot replacement tranche
   - [ ] Review the highest-traffic `styled-components` surfaces still blocking route migration.
   - [ ] Fix the next replacement tranche with Tailwind/CVA primitives.
   - [ ] Commit the dependency reduction separately.
15. Redux Saga reduction in dashboard flows
   - [ ] Review the remaining saga-driven dashboard study-count and summary-stat flows.
   - [ ] Fix the next shared request-helper or RTK migration tranche.
   - [ ] Commit the state reduction separately.
16. Immutable reduction in shared view models
   - [ ] Review the highest-churn shared selectors and helper modules still forcing Immutable data through the route boundary.
   - [ ] Fix the next plain-object compatibility tranche.
   - [ ] Commit the data-shape reduction separately.
17. Modern router cutover breadth
   - [ ] Review which additional user-facing routes can move under the modern router without breaking current URLs.
   - [ ] Fix the next runtime cutover tranche in `chronicle-web/src/index.js`.
   - [ ] Commit the cutover slice separately.
18. Root JVM validation readiness
   - [ ] Review the current blockers around Java, `JAVA_HOME`, and root validation coverage.
   - [ ] Fix the next readiness or automation tranche so more of the repo can be validated in one pass.
   - [ ] Commit the validation update separately.
19. Deployment path consolidation
   - [ ] Review the remaining divergence between local Bun/webpack commands and Docker/Traefik entrypoints.
   - [ ] Fix the next deployment-doc or automation tranche to narrow that gap.
   - [ ] Commit the deployment update separately.
20. Post-round reassessment
   - [ ] Review the repo after the sixth execution round.
   - [ ] Fix the work queue by generating the next checklist from the remaining modernization surface.
   - [ ] Commit the updated work queue separately.

## Current 20-Item Execution Checklist: Round 9 (Active)

1. Legacy runtime audit + migration slice
   - [ ] Review `containers/study`, `containers/survey`, `containers/tud`, and `containers/participant` for the next highest-traffic legacy import tranche.
   - [ ] Fix one targeted family route using modern primitives/state while preserving URL contracts.
   - [ ] Commit the tranche independently.
2. Route boundary safety
   - [ ] Review `chronicle-web/src/index.js` and the modern router fallback behavior after each direct-route migration.
   - [ ] Fix any dead routes or regressions introduced by mixed legacy/modern routing.
   - [ ] Commit the route boundary patch separately.
3. Auth bootstrap hardening
   - [ ] Review all startup bootstrap fallback paths for accidental active reliance on legacy `/chronicle/config.json`.
   - [ ] Fix fallback handling so non-test paths stay cookie/session-driven.
   - [ ] Commit the auth-boundary slice separately.
4. Server-side auth contract continuity
   - [ ] Review `chronicle-server` auth/session endpoints and redirect/logout invariants for SSO-compatibility.
   - [ ] Fix any contract drift introduced by legacy shim updates.
   - [ ] Commit the contract hardening separately.
5. Java/JVM validation readiness
   - [ ] Review local and CI prerequisites for the full JVM validation pass.
   - [ ] Fix docs/scripts that still assume missing Java/JDK behavior.
   - [ ] Commit the validation update separately.
6. React 19 blocker conversion
   - [ ] Review the current highest-frequency `lattice-ui-kit`, Material UI 4, and styled-components dependencies.
   - [ ] Fix one concrete dependency surface in a user-facing route tranche.
   - [ ] Commit the blocker-removal slice separately.
7. Redux-Saga/Immutable/deprecated request-state reduction
   - [ ] Review one additional state-heavy family (study/survey/TUD/participant) for migration opportunity.
   - [ ] Replace request flow with RTK or store-native equivalents or remove from live routes.
   - [ ] Commit migration slice separately.
8. Browser coverage expansion
   - [ ] Review Playwright paths for new modernized route tranches and legacy fallback paths.
   - [ ] Fix missing coverage and ensure direct route assertions pass on both `/chronicle` and root basenames.
   - [ ] Commit coverage updates separately.
9. Deployment/doc reconciliation
   - [ ] Review compose, script, and docs surface for any remaining `auth0` naming or config-token confusion.
   - [ ] Fix inconsistent wording and config behavior.
   - [ ] Commit documentation and automation changes separately.
10. Skill/automation hygiene
   - [ ] Review `.codex/skills` for migration coverage of the active Round 9 stack.
   - [ ] Create or update a skill for the most painful repeated checks.
   - [ ] Commit skill updates separately.
11. Legacy test-lane simplification
   - [ ] Review the next small Jest-only helpers that can move fully to Bun or be retired.
   - [ ] Fix that tranche and retire obsolete compatibility coverage.
   - [ ] Commit the testing-lane slice separately.
12. Post-round handoff
   - [ ] Review remaining open blockers and the new queue state.
   - [ ] Produce a fresh shortlist before the next cycle and commit this handoff note.

## Automation Added

- `scripts/chronicle-preflight.sh` checks toolchain and repo readiness.
- `scripts/chronicle-smoke.sh` runs a lightweight validation sweep and skips surfaces whose prerequisites are missing.
- `scripts/chronicle-web-bun-smoke.sh` runs the Bun-managed `chronicle-web` install/check/test/build loop in one place.
- `scripts/chronicle-web-bootstrap-smoke.sh` validates the temporary bootstrap-token path, cookie exchange/logout helpers, and modern deep-link coverage in one place.
- `scripts/chronicle-web-route-cutover-smoke.sh` validates the mixed legacy-webpack and modern-Bun route-cutover path and restores generated build outputs afterward.
- `scripts/check-sso-drift.sh` audits remaining Auth0 wiring, bootstrap-token paths, and legacy user-storage touchpoints.
- `scripts/silent-failure-hunter.sh` scans for common silent-failure and swallowed-error patterns.
- `.codex/skills/chronicle-web-bun-workflow` captures the Bun-specific frontend workflow, touchpoints, and validation path.
- `.codex/skills/chronicle-institutional-sso` captures the Auth0-to-SSO migration workflow and drift-audit command.
- `.codex/skills/chronicle-web-bootstrap-boundary` captures the Chronicle web startup/auth boundary workflow and the focused bootstrap smoke path.
- `.codex/skills/chronicle-web-route-cutover` captures the workflow for the legacy/modern web shell boundary and the mixed validation path.
