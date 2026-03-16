# Code Reuse Review: Chronicle Codebase Optimization (31 files, 1601 insertions)

## Summary

The optimization diff introduces significant duplication across test scripts. The new `lib-test-helpers.sh` was a good start at centralizing shared logic, but it only addresses CrowdSec whitelisting. Multiple other patterns are copy-pasted across 5-8 files and should be extracted into that library or a new one.

---

## Finding 1: BASE_URL Auto-Detection Duplicated Across 3 Scripts

**Severity**: High (30+ lines copied verbatim)

The same BASE_URL auto-detection block (try localhost:40320, fall back to DOMAIN from `.env`) is copy-pasted in:

- `tests/security/business-logic-tests.sh:22-40`
- `tests/security/session-management-tests.sh:28-46`
- `tests/security/run-tests-parallel.sh:23-31` (slightly different variant)

All three do the same thing: curl localhost, grep DOMAIN from `.env`, construct `http://${_domain}`. This should be a function in `lib-test-helpers.sh`, e.g.:

```bash
detect_base_url() {
    if curl -sf -o /dev/null -m 3 http://localhost:40320/chronicle/v3/ 2>/dev/null || \
       [ "$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://localhost:40320/chronicle/v3/ 2>/dev/null)" != "000" ]; then
        echo "http://localhost:40320"
    else
        local _domain="${DOMAIN:-}"
        if [ -z "$_domain" ] && [ -f "$PROJECT_ROOT/docker/.env" ]; then
            _domain=$(grep '^DOMAIN=' "$PROJECT_ROOT/docker/.env" 2>/dev/null | cut -d= -f2 || true)
        fi
        echo "http://${_domain:-localhost:40320}"
    fi
}
```

---

## Finding 2: AUTH_TOKEN Auto-Detection from JWT_SECRET Duplicated Across 4 Scripts

**Severity**: High (same 5-8 line pattern in 4 files)

The pattern "read JWT_SECRET from .env, call generate-jwt.sh" appears in:

- `tests/security/business-logic-tests.sh:56-63`
- `tests/security/session-management-tests.sh:45-51`
- `tests/security/contract-drift-tests.sh:70-76`
- `tests/security/api-header-tests.sh:21-27`

All four do: `grep '^JWT_SECRET=' ... | cut -d= -f2-` then `JWT_SECRET="$_jwt_secret" "$PROJECT_ROOT/docker/generate-jwt.sh"`. Should be `detect_auth_token()` in `lib-test-helpers.sh`.

---

## Finding 3: POSTGRES_PASSWORD Read from .env Duplicated Across 4 Scripts

**Severity**: Medium (same 3-line pattern)

The pattern `grep '^POSTGRES_PASSWORD=' ... docker/.env | sed 's/^POSTGRES_PASSWORD=//'` appears in:

- `tests/security/smoke-tests.sh:64`
- `tests/security/business-logic-tests.sh:72`
- `tests/security/database-security-tests.sh:45`
- `tests/security/run-all-security.sh:547`

Should be `get_postgres_password()` in `lib-test-helpers.sh`.

---

## Finding 4: DOMAIN Read from .env Duplicated Across 5 Scripts

**Severity**: Medium (same 1-line pattern, 5 occurrences)

`grep '^DOMAIN=' "$PROJECT_ROOT/docker/.env" ... | cut -d= -f2` appears in:

- `tests/security/run-tests-parallel.sh:19`
- `tests/security/business-logic-tests.sh:32`
- `tests/security/session-management-tests.sh:34`
- `tests/security/test-waf.sh:15`
- `tests/security/run-all-security.sh:45`

Should be a shared `load_env_var()` or `get_domain()` helper in `lib-test-helpers.sh`.

---

## Finding 5: Docker Inspect Batch-Parse Pattern Duplicated in 2 Scripts

**Severity**: High (50+ lines of near-identical Python parsing code)

Both `smoke-tests.sh:102-150` and `container-security-tests.sh:55-89` contain a nearly identical pattern:

1. `_INSPECT_JSON=$(docker inspect "${CONTAINERS[@]}" ...)`
2. A 25-30 line Python script parsing JSON into shell `declare` variables
3. A helper function (`_get()` in smoke-tests, `_cget()` in container-security-tests) doing `${!var:-}`

The Python codegen is almost identical. The two functions differ only in name (`_get` vs `_cget`) and the set of fields extracted (smoke-tests extracts more fields like labels, env, ports, tmpfs, pidslimit). This should be a shared function in `lib-test-helpers.sh` that:
- Accepts a list of container names
- Runs `docker inspect` once
- Parses into shell variables
- Exports a `_cget()` accessor

---

## Finding 6: pass/fail/skip/log Output Helpers Duplicated Across 13 Scripts

**Severity**: High (functional duplication, inconsistent formatting)

Every test script redefines `pass()`, `fail()`, `skip()`, `log()`, and `info()` with slightly different formatting:

- Some use `echo -e` with `\033[...`, others use `printf` with `${GREEN}` variables
- Some increment `PASS`, others `PASS_COUNT`
- Some include `TOTAL`, others don't

Scripts affected: `smoke-tests.sh:22-24`, `container-security-tests.sh:25-30`, `database-security-tests.sh:33-37`, `business-logic-tests.sh:105-108`, `session-management-tests.sh:73-76`, `contract-drift-tests.sh:62-64`, `api-header-tests.sh:44-47`, `test-waf.sh:37-52`, `test-falco.sh:32-36`, `test-fail2ban.sh:30-34`, `test-vault.sh:27-31`, `backup-dr-test.sh:61-65`, `run-all-security.sh:72-75`.

These should be sourced from `lib-test-helpers.sh` with a standard interface (e.g., always use `PASS`, `FAIL`, `SKIP` variable names).

---

## Finding 7: Two Duplicate autoresearch.sh Scripts

**Severity**: Medium (entire file duplicated with divergent implementations)

Two autoresearch scripts exist that do the same thing (benchmark metrics collection) with different implementations:

- `auto/autoresearch.sh` (82 lines) -- uses `run-all-security.sh`, k6 for latency, `backup-chronicle.sh` for backup timing, `docker image inspect` for sizes
- `docker/auto/autoresearch.sh` (67 lines) -- runs test scripts individually in a loop, uses `curl` loop for latency, `pg_dump` for backup timing, `docker images` for sizes

Both produce `METRIC key=value` lines. One should be deleted or one should call the other.

---

## Finding 8: Parallel Execution Pattern Duplicated in 3 Places

**Severity**: Medium (same tmpdir + background PID + wait + aggregate pattern)

The "run tasks in parallel, collect output in tmpdir, aggregate PASS/FAIL/SKIP counts" pattern appears in three places with slight variations:

- `tests/security/run-all-security.sh:78-194` (`run_layer()` with `PARALLEL_TMPDIR`)
- `tests/security/run-tests-parallel.sh:46-181` (`TMPDIR_PAR` with similar logic)
- `tests/security/run-all-security.sh:227-293` (SAST parallelization with `_sast_tmpdir`)
- `tests/security/run-all-security.sh:370-406` (Trivy parallelization with `_trivy_tmpdir`)

The SAST and Trivy parallelization blocks reinvent the same pattern: `mktemp -d`, launch `( cmd && echo PASS > file || echo FAIL > file ) &`, collect PIDs, `wait`, check result files, `rm -rf`. A generic `run_parallel_tasks()` helper would eliminate ~80 lines.

Additionally, `run-tests-parallel.sh` largely duplicates the `--parallel` mode of `run-all-security.sh`. Consider whether both are needed or if `run-tests-parallel.sh` should simply delegate to `run-all-security.sh --parallel`.

---

## Finding 9: HTTP Status Code Acceptance Pattern (429 Tolerance) Duplicated

**Severity**: Low (pattern, not code, but easy to miss a spot)

The "accept 429 as a valid response" change is applied individually to ~20 assertions across:

- `tests/security/business-logic-tests.sh` (6 assertions: lines 165, 178, 179, 194, 206, 227)
- `tests/security/test-waf.sh` (7 assertions: lines 100, 111, 122, 133, 148, 178, 193)
- `tests/security/session-management-tests.sh:195`
- `tests/security/smoke-tests.sh:248, 1220, 1227`
- `tests/security/contract-drift-tests.sh:633`

A helper like `is_acceptable_status()` in `lib-test-helpers.sh` that encapsulates "200, 301, 302, 401, 403, 404, 429 are all acceptable when checking endpoint existence" would centralize this logic and prevent future inconsistencies if more status codes need to be accepted.

---

## Finding 10: SQL Batch Query + Parse Pattern in database-security-tests.sh

**Severity**: Low (good optimization, but the parse pattern could be reusable)

The `while IFS='|' read -r key val; do case "$key" in ... esac done <<< "$BATCH"` pattern is used 5 times in `database-security-tests.sh` (lines 238, 280, 374, 430, 493) and 2 times in `smoke-tests.sh` (lines 503, 596). While each batch queries different data, the parsing boilerplate could be a helper function:

```bash
# parse_kv_batch "$batch_output" "key1" "key2" "key3"
# Sets variables: key1="val1" key2="val2" key3="val3"
```

---

## Finding 11: Existing `container_running()` Function Unused After Batch Inspect

**Severity**: Low (dead code)

`smoke-tests.sh:46-48` defines `container_running()` which does a `docker inspect` per call. The batch-inspect refactoring replaced most usages with `_get running "$container"`, but `container_running()` is still defined and called by `require_container()` (line 52). The function should be updated to use the prefetched data, or `require_container()` should use `_get running` directly.

---

## Finding 12: chronicle-server MapStore Changes Are Clean

**Severity**: None

The EAGER-to-LAZY mapstore changes in `FilteredAppsMapstore.kt`, `ParticipantStatsMapstore.kt`, and `StudyLimitsMapstore.kt` follow the existing `AbstractBasePostgresMapstore` pattern correctly. The `StudyLimitsMapstore` properly imports `MapStoreConfig`. No duplication concerns.

---

## Finding 13: Dependency Removal in build.gradle Files Is Clean

**Severity**: None

The dependency removals in `chronicle-server/build.gradle` (firebase-admin, AWS SNS, commons-math3 exclusion) and `rhizome/build.gradle` (AWS SDK v2, spring-security-ldap, snappy, lz4) are straightforward comment-outs with clear rationale. No code duplication introduced.

---

## Finding 14: Dockerfile Changes Are Clean but Could Share Alpine Package Lists

**Severity**: Low

Both `Dockerfile.backend` and `Dockerfile.frontend.prod` now use Alpine base images with similar patterns (`apk upgrade --no-cache && apk add --no-cache ...`), but they install different packages, so sharing is not practical.

The `su-exec` pattern in `Dockerfile.backend` is correctly used in both the Dockerfile CMD and the `docker-compose.traefik.yml` command override.

---

## Recommended Actions (Priority Order)

1. **Extract to `lib-test-helpers.sh`**: `detect_base_url()`, `detect_auth_token()`, `get_postgres_password()`, `load_env_var()` -- eliminates ~100 duplicated lines across 5+ scripts
2. **Extract batch Docker inspect** to `lib-test-helpers.sh`: `prefetch_container_inspect()` + `_cget()` -- eliminates ~80 duplicated lines in 2 scripts
3. **Source `pass/fail/skip` from shared library** instead of redefining in every script -- reduces 13 redundant definitions to 1
4. **Delete `docker/auto/autoresearch.sh`** or make it a symlink to `auto/autoresearch.sh`
5. **Extract `run_parallel_tasks()`** helper for the tmpdir+PID+wait+aggregate pattern -- eliminates ~60 lines of boilerplate in `run-all-security.sh`
6. **Evaluate if `run-tests-parallel.sh` is needed** given `run-all-security.sh --parallel` does the same thing
