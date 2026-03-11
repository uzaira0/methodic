---
name: chronicle-workspace
description: Repository-specific guidance for working in the Chronicle monorepo. Use when Codex needs to inspect, modify, validate, or deploy code under /opt/chronicle, especially across chronicle-server, chronicle-api, chronicle-web, chronicle Android app, rhizome, Docker, or GitHub Actions.
---

# Chronicle Workspace

Run `./scripts/chronicle-preflight.sh` before substantial work. Run `./scripts/chronicle-smoke.sh` before handoff when the environment can support it. Run `./scripts/silent-failure-hunter.sh` during fix reviews.

Read [references/topology.md](references/topology.md) when you need the component map, validation matrix, or deployment surface summary.

## Workflow

1. Identify the surface first.
   - Root Gradle build: `chronicle-api`, `chronicle-server`, `rhizome`, `rhizome-client`
   - Separate app: `chronicle-web`
   - Separate Android build: `chronicle/`
   - Operations/deployment: `docker/`, `.github/workflows/`

2. Expand the validation surface to match the change.
   - `chronicle-api` changes can affect server, Android, and sometimes the web client contract.
   - Web auth changes require coordinated updates across frontend bootstrap, auth utilities, Axios setup, Jest tests, and backend cookie endpoints.
   - Docker and Traefik changes require compose validation, not just file edits.

3. Prefer the smallest reliable validation set that still matches the affected surface.
   - JVM structure: `./gradlew projects`
   - API smoke: `./gradlew :chronicle-api:test`
   - Web policy typecheck: `cd chronicle-web && npm run typecheck`
   - Web lint/check: `cd chronicle-web && npm run check`
   - Web full legacy sweep: `cd chronicle-web && npm run check:full`
   - Web smoke: `cd chronicle-web && npm test -- --runInBand --watch=false`
   - Android smoke: `cd chronicle && ./gradlew assembleDebug`
   - Traefik syntax: `docker compose -f docker/docker-compose.traefik.yml config -q`

## Repo-Specific Rules

- Do not assume the Android app is part of the root Gradle build. It is excluded from `settings.gradle.kts`.
- Do not overstate TypeScript coverage in `chronicle-web`. The new `tsconfig.app.json` is a policy scaffold while the source tree is still Flow-based.
- Do not treat the current `chronicle-web` ESLint warning backlog as equivalent to failing the blocking quality gate. `npm run check` is intentionally narrower than `npm run check:full`.
- Do not treat `docker-compose.yml`, `docker-compose.prod.yml`, and `docker-compose.traefik.yml` as interchangeable. Confirm which deployment path the task targets.
- Do not edit `build/`, `chronicle-web/node_modules/`, or packaged artifacts unless the task explicitly requires it.
- Be cautious with remote Gradle scripts in `chronicle-api` and `chronicle-server`; changes there can have external build implications.

## Escalation Points

- If auth, cookies, CSRF, or Axios auth headers are involved, switch to `chronicle-web-auth-migration`.
- If ESLint rules, TS policy flags, Claude hooks, or CI quality gates are involved, switch to `chronicle-web-quality-gates`.
- If the user asks for fix review or silent-failure auditing, switch to `review-fixes`.
- If Gradle validation fails before project configuration, check environment readiness first; missing Java is a common local blocker.
