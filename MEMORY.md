# Chronicle Memory

Updated: 2026-03-11

## Current State

- The monorepo has five active surfaces: `chronicle-server`, `chronicle-api`, `chronicle-web`, `chronicle` (Android), and shared `rhizome` libraries.
- Root Gradle validation could not run in this workspace because `java` and `JAVA_HOME` were not configured.
- `chronicle-web` now passes `npm run check`, `npm test -- --runInBand --watch=false`, and the web portion of `./scripts/chronicle-smoke.sh`.
- The current web auth contract is: bootstrap JWT from `config.json` for testing, exchange it for backend-managed cookies, keep JWT state in memory only, and treat interactive SSO as future work.
- The requested TypeScript error-catching spec has been mapped onto `chronicle-web/`, but the frontend is still Flow-based. `chronicle-web/tsconfig.app.json` is a forward-looking policy scaffold rather than full source coverage.
- `chronicle-web` ESLint warnings still document legacy debt, but blocking errors are now under control in the requested gate.

## Verified Signals

- `npm test -- --runInBand --watch=false` in `chronicle-web/` is green.
- `npm run check` in `chronicle-web/` is green.
- `./scripts/chronicle-smoke.sh` is green except for JVM steps skipped because Java is missing locally.
- `./scripts/silent-failure-hunter.sh` finds only existing `console.error` sites, not swallowed catches or `queueMicrotask` patterns.
- Backend support for the new auth flow exists in `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/AuthTokenController.kt` and related security config.
- Repo automation added:
  - `scripts/chronicle-preflight.sh`
  - `scripts/chronicle-smoke.sh`
  - `scripts/silent-failure-hunter.sh`
  - `.claude/settings.json` hooks for secret protection and post-edit web linting
  - `.github/workflows/ci.yml` for web checks, JVM smoke, compose validation, and silent-failure scanning

## Next Work Queue

1. Institutional SSO contract
   - [ ] Review `chronicle-server` auth entry points, cookies, redirects, and logout behavior.
   - [ ] Fix the server/web contract so institutional SSO replaces Auth0-specific assumptions cleanly.
   - [ ] Commit the backend + web contract change together.
2. Replace bootstrap-token auth
   - [ ] Review every remaining dependency on `config.json` token bootstrap.
   - [ ] Fix the testing bootstrap into a documented temporary path or remove it once SSO exists.
   - [ ] Commit only the bootstrap-removal or bootstrap-hardening slice.
3. Server-side cookie and CSRF tests
   - [ ] Review the current server test coverage for `/chronicle/v3/auth` cookie endpoints.
   - [ ] Fix missing contract tests for cookie issuance, CSRF cookie creation, and logout clearing.
   - [ ] Commit the server tests with any required endpoint changes.
4. Flow vs TypeScript migration decision
   - [ ] Review whether the team wants real TS migration or only policy scaffolding.
   - [ ] Fix docs, CI, and package scripts to match that decision rather than implying both paths at once.
   - [ ] Commit the language-strategy update separately from feature work.
5. Web lint warning backlog
   - [ ] Review the current `npm run check` warning set and group it by risk.
   - [ ] Fix the highest-signal warnings first, especially hook dependency drift and unstable nested components.
   - [ ] Commit warning-reduction work in small, topic-based slices.
6. CSS-in-JS lint strategy
   - [ ] Review whether `stylelint` should remain optional, be repaired, or be removed.
   - [ ] Fix the parser/config story for styled-components instead of leaving a half-working optional script.
   - [ ] Commit the CSS-lint policy change on its own.
7. JVM readiness
   - [ ] Review local/CI Java expectations for root Gradle work.
   - [ ] Fix `java` and `JAVA_HOME` availability, then re-run `./gradlew projects` and `:chronicle-api:test`.
   - [ ] Commit only if repo docs or scripts change as part of the fix.
8. Server smoke coverage
   - [ ] Review whether `:chronicle-server:test` is stable enough for smoke or CI.
   - [ ] Fix flaky or missing prerequisites if the server test suite should become default.
   - [ ] Commit the smoke-path expansion separately from unrelated server work.
9. Deployment documentation convergence
   - [ ] Review the root README, `docker/README.md`, and compose variants for conflicting instructions.
   - [ ] Fix the docs so one deployment story is clearly canonical.
   - [ ] Commit doc and compose narrative updates together.
10. Android build boundary
   - [ ] Review whether `chronicle/` should remain outside the root Gradle build.
   - [ ] Fix the docs/CI narrative to match that architectural choice.
   - [ ] Commit Android-boundary documentation or build changes separately.
11. Secret-adjacent asset audit
   - [ ] Review tracked certs, signing assets, and local bootstrap/security files.
   - [ ] Fix version-control scope so only intended sensitive materials remain tracked.
   - [ ] Commit the audit outcome with any ignore or docs changes.
12. Remote Gradle dependency hardening
   - [ ] Review every remote `apply from` dependency in JVM modules.
   - [ ] Fix or pin the brittle ones so builds do not depend on mutable GitHub-hosted scripts.
   - [ ] Commit each hardening step independently if multiple remote scripts are involved.

## Automation Added

- `scripts/chronicle-preflight.sh` checks toolchain and repo readiness.
- `scripts/chronicle-smoke.sh` runs a lightweight validation sweep and skips surfaces whose prerequisites are missing.
- `scripts/silent-failure-hunter.sh` scans for common silent-failure and swallowed-error patterns.
