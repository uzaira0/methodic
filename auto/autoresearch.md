# Autoresearch: Maximize Chronicle Security Test Pass Count

## Objective
Maximize the number of individual passing test assertions across all security test scripts. Eliminate skips by providing required env vars, running with --live flags, and writing new tests for uncovered areas. Each experiment adds new test assertions, fixes skips, or converts not-ready items to ready.

## Metrics
- **Primary (optimization target)**: `total_pass` (checks, higher is better)
- **Secondary**: `total_skip` (lower is better), `total_fail` (must stay 0)

## How to Run
`./auto/autoresearch.sh` — runs all security tests, counts individual [PASS]/[FAIL]/[SKIP] lines.

## Files in Scope
- `tests/security/*.sh` — all security test scripts
- `tests/load/*.js` — k6 load test scripts
- `tests/security/rules/*.yaml` — semgrep rules
- `tests/security/policies/*.rego` — OPA policies
- `docker/docker-compose.traefik.yml` — for container security checks
- `docker/Dockerfile.*` — for IaC checks

## Off Limits
- `chronicle-server/src/` — no application code changes in this loop
- `chronicle-api/src/` — no API changes
- `rhizome/src/` — no framework changes
- `docker/.env` — no secret changes

## Constraints
- total_fail MUST stay at 0 (no new failures)
- Tests must be deterministic (same result every run)
- Tests must complete within 6 minutes total
- New tests must test REAL security properties, not fake assertions

## Strategic Direction
From the Testing Encyclopedia, applicable categories for Chronicle:
1. **Smoke Tests** — health checks for every service (postgres, backend, frontend, prometheus, loki, grafana, crowdsec, fail2ban, falco, vault, alertmanager, promtail, traefik)
2. **Integration Tests** — API endpoint tests (auth, study CRUD, participant, export)
3. **Container Structure Tests** — verify binary existence, user, ports, env vars
4. **IaC Tests** — more OPA policies, more Hadolint rules
5. **Database Tests** — RLS verification, permission checks, TDE per-table
6. **Network Security** — port scan, internal network isolation
7. **Session/Auth** — cookie attrs, JWT claims, expiry, revocation
8. **Business Logic** — study isolation, privilege boundaries
9. **Input Validation** — SQL injection patterns, XSS, path traversal
10. **Runtime Security** — Falco rules, container capabilities, seccomp

## Baseline
- **Commit**: (current HEAD)
- **total_pass**: ~120 (estimated from last run)
- **total_skip**: ~15
- **total_fail**: 0

## What's Been Tried
(none yet — first iteration)

## Current Best
- **total_pass**: TBD (run baseline first)
