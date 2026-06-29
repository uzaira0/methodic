# Backend Security Hardening Report

Date: 2026-05-13

## Executive Summary

This pass used repo-grounded review, threat modeling, and hardening over the Chronicle backend. The highest-impact fixes were:

- RLS context is now applied when the actual query connection is borrowed, not only when a request filter happens to run.
- Client IP resolution is centralized and only trusts proxy headers from configured trusted proxies.
- Notification phone/settings endpoints now enforce self-or-admin ownership for caller-supplied `principalId` values.
- Twilio notification status webhooks now require `X-Twilio-Signature` validation before status mutation.
- CSV/XLSX exports now neutralize spreadsheet formula injection while JSON exports remain raw.
- Encryption health now fails closed when TDE evidence is missing, stale, or failed.
- Traefik no longer has duplicate HTTP routers that could trigger incorrect TLS redirects behind F5.
- The Chronicle compose stack now keeps the Postgres exporter password out of static compose environment, reads it from the Docker secret file, and runs the exporter as the secret-file owner UID.
- The Postgres exporter is upgraded to `v0.17.1` with PostgreSQL 17-compatible checkpointer metrics enabled and the removed `stat_bgwriter` collector disabled.
- The backend integration test harness no longer blocks on the Playwright server test, no longer inherits TLS-enabled Jetty settings, and restores real principal maps before every server-backed test so unit-test mocks cannot corrupt auth state.
- Previously skipped backend serialization coverage is now active.
- The frontend Biome backlog under `chronicle-web/src/modern` and `chronicle-web/src/core` is cleared; the full web check now passes.

## Guardrails Added

- Semgrep: direct `X-Forwarded-For` / `X-Real-IP` parsing is blocked outside `ClientIpResolver`.
- Semgrep: Twilio status mutation without signature verification is blocked.
- Semgrep: notification controller use of path `principalId` without self-or-admin checking is blocked.
- Semgrep: raw CSV/XLSX spreadsheet cell writes are blocked unless routed through formula neutralization.
- Existing RLS Semgrep and ast-grep rules remain blocking in `tests/security/run-all-security.sh`.
- The SAST runner now exits non-zero on actionable repo-specific findings instead of report-only success.

## Verification

- Passed: `JAVA_HOME=/home/uzair/.local/jdks/temurin-21 ./gradlew :chronicle-server:test --no-daemon`
- Passed: backend test result parse: `tests=1170 skipped=0 failures=0 errors=0`
- Passed: `tests/security/run-all-security.sh sast /tmp/chronicle-security-sast`
- Passed: `tests/security/run-all-security.sh sca /tmp/chronicle-security-sca`
- Passed: `tests/security/run-all-security.sh secrets /tmp/chronicle-security-secrets`
- Passed: `tests/security/run-all-security.sh iac /tmp/chronicle-security-iac`
- Passed: `tests/security/run-all-security.sh auth /tmp/chronicle-security-auth`
- Passed: `tests/security/run-all-security.sh injection /tmp/chronicle-security-injection`
- Passed: `tests/security/run-all-security.sh crypto /tmp/chronicle-security-crypto`
- Passed: `tests/security/run-all-security.sh compliance /tmp/chronicle-security-compliance`
- Passed: `find docker scripts tests/security -name '*.sh' -print0 | xargs -0 bash -n`
- Passed: no active legacy brand references in runtime/source/config files.
- Passed: `git diff --check && git -C chronicle-server diff --check && git -C chronicle-api diff --check`
- Passed: `cd chronicle-web && bun run typecheck`
- Passed: `cd chronicle-web && bun test src/modern/lib src/modern/state src/modern/stores src/modern/features src/bun-legacy`
- Passed: `cd chronicle-web && bun test e2e/dsl/`
- Passed: `cd chronicle-web && bun run check`
- Passed: `docker compose -f docker/docker-compose.traefik.yml config --quiet`
- Passed: `docker compose -f docker/docker-compose.traefik.yml up -d --build chronicle-backend chronicle-frontend chronicle-postgres-exporter postgres-replica traefik`
- Passed: `docker compose -f docker/docker-compose.traefik.yml ps` shows Chronicle backend, frontend, Postgres, Postgres replica, Postgres exporter, Prometheus, Grafana, and Traefik healthy.
- Passed: `curl -sSI -H 'Host: chronicle-screentime-app.research.bcm.edu' http://10.23.4.137/chronicle/v3/study` returns backend `401 Unauthorized`, not Traefik HTTPS redirect.
- Passed: `curl -H 'Host: chronicle-screentime-app.research.bcm.edu' http://10.23.4.137/prometheus/` returns `401`.
- Passed: Postgres exporter `/metrics` reports `pg_exporter_last_scrape_error 0` and exposes `pg_stat_checkpointer_*` metrics.

## Remaining Risks

- Some Gradle deprecation warnings and Kotlin deprecation warnings remain. They are not security failures and did not block the backend or SAST gates, but they should be cleaned up in a dependency/Gradle modernization tranche before Gradle 10.
- `shellcheck` is not installed on this host, so shell hardening verification used `bash -n` syntax checks plus the security gate scripts. Install `shellcheck` if you want POSIX/static shell diagnostics enforced in CI.
