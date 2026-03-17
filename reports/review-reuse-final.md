# Code Reuse Review — Chronicle Diff (5 commits, 313 lines)

Reviewed: `docker-compose.traefik.yml`, `traefik.yml`, `dependency-scan.yml`,
`api-header-tests.sh`, `gradles/methodic.gradle`, plus submodule pointer updates.

---

## 1. CRITICAL — `dependency-scan.yml` duplicates existing Trivy scanning

**New file:** `.github/workflows/dependency-scan.yml` (Trivy filesystem scan)

**Already exists in two places:**

| Workflow | Scan type | Trigger overlap |
|----------|-----------|-----------------|
| `security-scan.yml` (lines 170-253) | `aquasecurity/trivy-action@master` — image scan of backend + frontend | push to develop/main, PR, weekly schedule |
| `security-suite.yml` (sca matrix layer, line 67-71) | `trivy fs --scanners vuln` on `chronicle-server/` | push to develop, PR |

The new `dependency-scan.yml` runs `trivy-action` with `scan-type: 'fs'` and `severity: HIGH,CRITICAL` — this is functionally identical to `security-suite.yml`'s `sca` layer, which already runs `trivy fs --scanners vuln --severity HIGH,CRITICAL` against the same codebase.

Additionally, all three workflows upload SARIF to GitHub Security via `github/codeql-action/upload-sarif@v3` and upload artifacts with 30-day retention.

**Recommendation:** Remove `dependency-scan.yml` and add the filesystem scan trigger paths (`**/build.gradle`, `**/package.json`, etc.) to `security-suite.yml` instead. This avoids three separate workflows running overlapping Trivy scans with different schedules (Sunday 2am, Monday 6am, and on-push).

---

## 2. MODERATE — `api-header-tests.sh` does not use shared test helpers

`tests/security/lib-test-helpers.sh` provides standardized `pass()`, `fail()`, `skip()`, `http_status()`, color constants, `detect_base_url()`, and `print_summary()`.

Five other test scripts already source it: `contract-drift-tests.sh`, `test-waf.sh`, `business-logic-tests.sh`, `smoke-tests.sh`, `run-tests-parallel.sh`.

`api-header-tests.sh` redefines all of these locally (lines 45-47 for pass/fail/skip, line 68 for fetch_headers, line 74 for http_status) with slightly different formatting (uses `printf` vs `echo -e`, different counter variable names `PASS`/`FAIL`/`SKIP` vs `PASS_COUNT`/`FAIL_COUNT`/`SKIP_COUNT`).

The diff adds more logic to `check_security_headers()` (the 403 acceptance change) but does not address this duplication.

**Recommendation:** Refactor `api-header-tests.sh` to source `lib-test-helpers.sh` and remove the locally redefined functions.

---

## 3. MODERATE — 401/403 acceptance pattern repeated 3 times in diff

The diff repeats this pattern in `api-header-tests.sh` three times (lines 271-279, 286-294, 302-310):

```bash
if [ "$status" = "401" ] || [ "$status" = "403" ]; then
    pass "... → $status ..."
...
    fail "... → expected 401/403, got $status ..."
```

Other test scripts (`test-waf.sh`, `contract-drift-tests.sh`, `business-logic-tests.sh`) solve this with helper functions or shared patterns.

**Recommendation:** Extract an `expect_auth_rejection()` helper (e.g., in `lib-test-helpers.sh`) that accepts a label, status code, and list of acceptable codes. This would reduce the three copy-pasted blocks to single calls.

---

## 4. LOW — Docker socket proxy is correctly isolated (no duplication)

The `docker-socket-proxy` service in `docker-compose.traefik.yml` is new and does NOT exist in `docker-compose.security.yml`. The security overlay has Falco mounting `/var/run/docker.sock` directly (privileged container, different purpose — runtime introspection, not API proxying). These are distinct use cases with no duplication.

The proxy is correctly wired: both `docker-compose.traefik.yml` (env var `DOCKER_HOST`) and `traefik.yml` (provider `endpoint`) point to `tcp://docker-socket-proxy:2375`, and the direct socket mount is removed from Traefik. No issues here.

---

## 5. LOW — `read_only: true` + `tmpfs` pattern is consistent

The diff adds `read_only: true` (and `tmpfs` where needed) to prometheus, alertmanager, loki, promtail, and grafana. The existing CrowdSec container in `docker-compose.traefik.yml` already had `read_only: true` (line 489). The pattern is applied consistently across all monitoring/SIEM containers. No duplication concern.

---

## 6. INFO — Version bumps (methodic.gradle)

- Jackson: `2.19.0` -> `2.21.1`
- Jetty: `12.0.22` -> `12.0.32`

No reuse concern. These are straightforward version-property updates in the central version catalog.

---

## 7. INFO — `aquasecurity/trivy-action@master` pinning

All three workflows (`dependency-scan.yml`, `security-scan.yml`) use `aquasecurity/trivy-action@master` — an unpinned floating tag. This is a supply-chain risk (not a reuse issue per se) but worth noting: if one workflow pins to a SHA, the others should match.

---

## Summary

| # | Severity | Finding | Action |
|---|----------|---------|--------|
| 1 | CRITICAL | `dependency-scan.yml` duplicates `security-suite.yml` sca layer and overlaps `security-scan.yml` | Remove new workflow; add trigger paths to existing |
| 2 | MODERATE | `api-header-tests.sh` redeclares helpers from `lib-test-helpers.sh` | Source shared lib instead |
| 3 | MODERATE | 401/403 acceptance pattern copy-pasted 3x | Extract `expect_auth_rejection()` helper |
| 4 | LOW | Docker socket proxy — no duplication | No action needed |
| 5 | LOW | `read_only` pattern — consistently applied | No action needed |
| 6 | INFO | Version bumps — clean | No action needed |
| 7 | INFO | Trivy action unpinned to `@master` | Consider SHA pinning |
