# Chronicle Repo Guide

## Scope

Use this file for work anywhere under `/opt/chronicle`.

## Local Skills

- Use `.codex/skills/chronicle-workspace` for general monorepo navigation, validation, and deployment work.
- Use `.codex/skills/chronicle-web-auth-migration` when touching the web auth flow, cookie handling, Axios auth headers, or the backend cookie endpoints.
- Use `.codex/skills/chronicle-web-bun-workflow` when touching `chronicle-web` package management, Bun scripts, `bun.lock`, Bun build/dev/preview flow, or the root automation that drives frontend Bun commands.
- Use `.codex/skills/review-fixes` when asked to review repo changes, run the silent failure hunter, or audit fixes for regressions and silent-failure patterns.
- Use `.codex/skills/chronicle-web-quality-gates` when touching the web app's ESLint/TypeScript policy, Claude hooks, CI checks, or warning-vs-error gate behavior.
- Use `.codex/skills/chronicle-institutional-sso` when working on Auth0 retirement, institutional SSO planning/cutover, `/chronicle/config.json` bootstrap isolation, or redirect/SSRF allowlist hardening.
- Use `.codex/skills/chronicle-server-auth-contract` when changing `AuthTokenController`, cookie/session/logout behavior, the testing-login bridge, server auth tests, or JVM smoke/CI coverage for the auth contract.
- Use `.codex/skills/chronicle-web-bootstrap-boundary` when changing `chronicle-web` bootstrap loading, `config.json` token fallback, cookie exchange/logout helpers, legacy bootstrap rendering, or the Bun coverage around the startup/auth boundary.
- Use `.codex/skills/chronicle-web-route-cutover` when changing `chronicle-web/src/index.js`, legacy-vs-modern bootstrap loading, webpack TS/CSS interop for modern routes, or the `/modern` route prefix.

## Repo Shape

- Root Gradle build covers `chronicle-api`, `chronicle-server`, `rhizome`, and `rhizome-client`.
- The Android app lives in `chronicle/` but is excluded from the root `settings.gradle.kts`; use `chronicle/gradlew` for Android-only work.
- The web app in `chronicle-web/` is a separate React 18 + Flow app with a Bun-managed package/build workflow, a Bun-native test lane, and a shrinking Jest compatibility lane.
- `chronicle-web/` is also a nested git repository; commit web-app history inside `chronicle-web/` and then update the root repo pointer separately.
- Deployment and security infrastructure live in `docker/` with multiple compose variants (`docker-compose.yml`, `docker-compose.prod.yml`, `docker-compose.traefik.yml`, security overlays, monitoring overlays).

## First Commands

- Run `./scripts/chronicle-preflight.sh` before substantial work.
- Run `./scripts/chronicle-smoke.sh` before handing off non-trivial changes when the environment supports it.
- Run `./scripts/silent-failure-hunter.sh` when doing fix reviews or quality sweeps; use `--strict` only when you intentionally want it to fail on suspicious patterns.
- Run `./scripts/check-sso-drift.sh` before and after institutional SSO/Auth0 migration work; use `--strict` to fail when Auth0-specific runtime defaults reappear.
- Run `./scripts/chronicle-web-bootstrap-smoke.sh` after changes that touch the temporary bootstrap-token path, cookie exchange/logout helpers, or legacy bootstrap startup/rendering.
- Run `./scripts/chronicle-web-route-cutover-smoke.sh` after changes that touch the legacy/modern web shell boundary.
- Check `git status --short` before assuming the workspace is clean; submodules may already be dirty.

## High-Signal Rules

- Treat `chronicle-api` changes as cross-project changes. DTO and Retrofit interface edits can affect `chronicle-server`, `chronicle-web`, and `chronicle`.
- Treat `chronicle-web` auth changes as a coordinated migration. Frontend utilities, Axios setup, bootstrap flow, Jest tests, and `chronicle-server` cookie endpoints move together.
- Treat `chronicle-web/tsconfig.app.json` as a policy scaffold, not proof that the Flow frontend has been migrated to TypeScript. TypeScript strictness is staged here for future TS adoption, but current source coverage is still Flow-based.
- Treat `chronicle-web/bun run check` as the blocking web quality gate. Current ESLint warnings document legacy debt; they are not the same as the new bug-catching error gate.
- Keep backlog execution itemized as `review -> fix -> commit` when working through the repo checklist. Do not bundle unrelated backlog items into a single commit unless the contract forces them to move together.
- Treat `chronicle-web/src/core/bootstrap/` and `chronicle-web/src/core/auth/bootstrap/` as bootstrap-boundary infrastructure. Validate both helper-level Bun coverage and route-level browser behavior when those files move.
- Treat `chronicle-web/src/index.js` and `chronicle-web/config/webpack/webpack.config.base.js` as route-cutover infrastructure. Validate both the legacy webpack shell and the modern Bun/Tailwind shell when those files move.
- Validate Docker and Traefik edits with `docker compose -f docker/docker-compose.traefik.yml config -q` and the relevant compose file for the target environment.
- Do not edit checked-in build outputs, `chronicle-web/node_modules`, `build/`, or packaged artifacts unless the task explicitly targets them.
- Be careful with remote Gradle script usage in `chronicle-api` and `chronicle-server`; some builds still `apply from` GitHub-hosted Gradle scripts.
- `.claude/settings.json` is a committed project policy file; `.claude/settings.local.json` remains machine-local.

## Validation Matrix

- Root JVM structure: `./gradlew projects`
- API module: `./gradlew :chronicle-api:test`
- Server auth/session contract: `./scripts/chronicle-server-auth-smoke.sh`
- Web policy typecheck: `cd chronicle-web && bun run typecheck`
- Web lint/check: `cd chronicle-web && bun run check`
- Web full legacy sweep: `cd chronicle-web && bun run check:full` (blocking Bun-native gate plus explicit Flow/Jest legacy sweep)
- Web app Bun suite: `cd chronicle-web && bun run test`
- Web app legacy suite: `cd chronicle-web && bun run test:legacy -- --runInBand --watch=false`
- Web browser smoke: `cd chronicle-web && bun run e2e`
- Web bootstrap/auth smoke: `./scripts/chronicle-web-bootstrap-smoke.sh`
- Web route-cutover smoke: `./scripts/chronicle-web-route-cutover-smoke.sh`
- React 19 blocker audit: `cd chronicle-web && bun run react:audit`
- Android app: `cd chronicle && ./gradlew assembleDebug`
- Traefik compose syntax: `docker compose -f docker/docker-compose.traefik.yml config -q`

## Current Review Themes

- The web app is mid-migration from localStorage JWT handling to backend-managed httpOnly cookies, with institutional SSO as the intended successor to the current bootstrap-token testing flow.
- The web app is actively migrating pure helper coverage off Jest and onto Bun; the legacy Jest lane is now down to the translation compatibility suite plus any future browser-heavy leftovers.
- The requested frontend error-catching tooling is now wired into `chronicle-web` through `tsconfig.app.json`, ESLint 8 rules, package scripts, Claude hooks, CI, and the smoke scripts.
- Root docs and Docker docs describe overlapping but not identical local/prod deployment paths.
- The Android app is operationally separate from the root Gradle build and CI path.
- Repo-quality enforcement now spans project hooks, CI, lint rules, and the silent failure hunter; use those before declaring a fix safe.
