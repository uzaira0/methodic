# Code Quality Review: Chronicle Codebase Optimization (31 files, 1601 insertions)

Review date: 2026-03-16
Reviewer: Claude Opus 4.6
Focus: Docker, compose, test scripts

---

## HIGH Severity

### H1. Duplicated `docker inspect` batch-parse pattern (copy-paste with variation)

**Files:**
- `tests/security/smoke-tests.sh:105-147` (17 fields extracted, helper named `_get`)
- `tests/security/container-security-tests.sh:56-86` (9 fields extracted, helper named `_cget`)

Both scripts contain a nearly identical Python-in-bash pattern that:
1. Calls `docker inspect` on all containers
2. Pipes JSON into Python to emit `declare` statements
3. Defines a bash helper to look up values via indirect variable expansion

The smoke-tests version extracts 17 fields; the container-security version extracts 9 fields. The Python code structure is duplicated line-for-line, differing only in which fields are extracted and variable prefixes. This should be a shared function in `lib-test-helpers.sh`.

### H2. Duplicated BASE_URL auto-detection logic (copy-paste across 3 files)

**Files:**
- `tests/security/business-logic-tests.sh:22-41`
- `tests/security/session-management-tests.sh:27-42`
- `tests/security/run-tests-parallel.sh:23-30`

All three scripts independently implement the same logic: try localhost:40320, fall back to DOMAIN from `.env`, construct `http://${_domain}`. The business-logic and session-management versions are nearly character-for-character identical. This should be a function in `lib-test-helpers.sh`.

### H3. Duplicated AUTH_TOKEN auto-detection logic (copy-paste across 2 files)

**Files:**
- `tests/security/business-logic-tests.sh:55-63`
- `tests/security/session-management-tests.sh:44-52`

Both scripts independently read `JWT_SECRET` from `.env` and call `generate-jwt.sh` to produce an `AUTH_TOKEN`. Should be extracted into `lib-test-helpers.sh` since that file already exists as the shared helper library.

### H4. `eval` of Python-generated shell code is a code injection risk

**Files:**
- `tests/security/smoke-tests.sh:105` (`eval "$(echo "$_INSPECT_JSON" | python3 -c "...")"`)
- `tests/security/container-security-tests.sh:56` (same pattern)

Container names from `docker inspect` are used to construct shell variable names. While `shlex.quote()` is used for values, the variable **names** are constructed from `name.replace('-','_')` without sanitizing for shell metacharacters beyond hyphens. A container named `foo;rm -rf /` would produce a variable name with `;rm`. The `safe = name.replace('-','_')` only handles hyphens.

**Mitigation**: The risk is low because container names typically come from compose files, but these are security test scripts. Use a stricter sanitization: `safe = re.sub(r'[^a-zA-Z0-9_]', '_', name)`.

### H5. Two separate autoresearch.sh scripts doing the same thing differently

**Files:**
- `auto/autoresearch.sh` (82 lines, uses `curl` for healthchecks, hardcodes domain, uses `k6` for latency)
- `docker/auto/autoresearch.sh` (67 lines, uses `wget` for healthchecks, reads domain from `.env`, uses `curl` loop for latency)

These are two independent implementations of the same benchmark runner with incompatible approaches:
- Image size: `docker image inspect --format '{{.Size}}'` (bytes) vs `docker images --format '{{.Size}}'` (human-readable, piped through `bc`)
- Memory: `curl` + `runtime_totalMemory` vs `wget` + `jvm_memory`
- Latency: `k6` load test vs manual `curl` loop (taking max, not p95)
- Bundle dir order: `dist` first vs `build` first

The `docker/auto/` version's "p95" calculation is actually max (takes the highest value), not a percentile. Only one script should exist.

---

## MEDIUM Severity

### M1. Semicolons instead of `&&` break error chain in compose command

**File:** `docker/docker-compose.traefik.yml:255-256`

```yaml
chown -R chronicle:chronicle /var/log/chronicle 2>/dev/null;
chown chronicle:chronicle /server/config /server/config/*.yaml 2>/dev/null;
exec su-exec chronicle java ...
```

The `;` on lines 255-256 means these `chown` commands do not participate in the `&&` chain. If the preceding `[ -d /var/log/chronicle ]` check fails and `exit 1` fires, that is fine. But the transition from `&&` to `;` means a failure in the `for` loop validation (line 253) would NOT stop `chown` from running, and more importantly, if `chown` fails (silently due to `2>/dev/null`), the `exec` still runs. This is intentional per the `2>/dev/null`, but the mixed `&&`/`;` style is fragile and the intent is unclear.

### M2. Converting SKIPs to PASSes weakens the test suite's signal

**Files:**
- `tests/security/api-header-tests.sh:165` (HSTS absent = PASS)
- `tests/security/api-header-tests.sh:180` (Referrer-Policy absent = PASS)
- `tests/security/api-header-tests.sh:520-521` (No rate-limit headers = PASS)
- `tests/security/api-header-tests.sh:563` (No CORS credentials = PASS)
- `tests/security/api-header-tests.sh:577-578` (No CORS methods = PASS)
- `tests/security/api-header-tests.sh:610` (No CORS same-site = PASS)
- `tests/security/api-header-tests.sh:699` (No Cache-Control = PASS)
- `tests/security/session-management-tests.sh:237-239` (No cookies = PASS)
- `tests/security/database-security-tests.sh:274,282,338,352` (superuser = PASS instead of SKIP)
- `tests/security/database-security-tests.sh:547-548,559,571` (No indexes on append tables = PASS instead of SKIP)

Across multiple test scripts, checks that previously reported SKIP (acknowledging a gap) now report PASS with long justification comments. While the justifications are individually reasonable, the aggregate effect is inflating the pass count from ~120 to ~357 without changing actual security posture. This makes the metric unreliable for tracking real improvements.

### M3. `run-tests-parallel.sh` is mostly redundant with `run-all-security.sh --parallel`

**Files:**
- `tests/security/run-tests-parallel.sh` (181 lines, runs 8 test scripts)
- `tests/security/run-all-security.sh:78-194` (parallel mode, runs 24 layers)

Both implement parallel test execution with temp dirs, PID tracking, wait loops, and result aggregation. `run-tests-parallel.sh` runs 8 scripts; `run-all-security.sh --parallel` runs 24 layers (which include those 8 scripts). The parallel runner should either be removed or `run-all-security.sh --parallel` should delegate to it.

### M4. Hardcoded UID values in tmpfs mounts may drift from Alpine nginx

**File:** `docker/docker-compose.traefik.yml:440-442`

```yaml
tmpfs:
  - /var/lib/nginx/tmp:noexec,nosuid,uid=100,gid=101
  - /var/lib/nginx/logs:noexec,nosuid,uid=100,gid=101
  - /run/nginx:noexec,nosuid,uid=100,gid=101
```

The nginx user on Alpine 3.21 is UID 100, but this could change with Alpine version bumps. The Dockerfile uses `USER nginx` (symbolic), but the compose file hardcodes `uid=100`. If Alpine changes the nginx UID, the container will fail at runtime with permission errors. The previous version used `uid=101` with the Docker Hub nginx image.

### M5. CrowdSec whitelist `setup_crowdsec_whitelist` has no idempotency guard

**File:** `tests/security/lib-test-helpers.sh:16-44`

When running in parallel mode, multiple test scripts may call `setup_crowdsec_whitelist` simultaneously. Each call runs `docker exec chronicle-crowdsec cscli decisions delete --ip "$my_ip"`. While `cscli decisions delete` is idempotent (deleting nothing is fine), the IP detection methods (Traefik log, network inspect, fallback) could race and produce different IPs across concurrent invocations, leaving some IPs un-whitelisted.

### M6. `docker/auto/autoresearch.sh` reads `.env` credentials insecurely

**File:** `docker/auto/autoresearch.sh:62`

```bash
docker exec chronicle-postgres pg_dump -U $(grep POSTGRES_USER docker/.env 2>/dev/null | cut -d= -f2) ...
```

Unquoted command substitution. If `POSTGRES_USER` contains spaces or shell metacharacters, this breaks. Also `grep POSTGRES_USER` without `^` anchor could match `#POSTGRES_USER` or `OTHER_POSTGRES_USER`.

### M7. Nginx `brotli_static on` without loading the Brotli module in config

**File:** `docker/nginx.frontend.conf:8`

The Dockerfile installs `nginx-mod-http-brotli`, but Alpine's nginx requires a `load_module` directive in `nginx.conf` (the main config). The `http.d/default.conf` uses `brotli_static on`, but if the module isn't loaded in the top-level `nginx.conf`, nginx will fail to start with "unknown directive brotli_static". This relies on Alpine's nginx package auto-including `load_module` lines, which it does for `nginx-mod-http-brotli`, but this implicit dependency is fragile.

---

## LOW Severity

### L1. Committed Trivy scan reports that failed with "no space left on device"

**Files:**
- `tests/security/reports/sbom-chronicle-backend.log` (contains FATAL: no space left on device)
- `tests/security/reports/vulns-chronicle-backend.log` (same error)

These are committed (tracked by git despite `.gitignore` listing `tests/security/reports/`). The gitignore path is `tests/security/reports/` but the actual committed files are at `tests/security/reports/`. The gitignore says `tests/security/reports/` but these files were force-added or the gitignore pattern is relative to the wrong directory. These failure logs should not be committed.

### L2. Inconsistent naming: `_cget` vs `_get` for the same pattern

**Files:**
- `tests/security/container-security-tests.sh:83` defines `_cget()`
- `tests/security/smoke-tests.sh:151` defines `_get()`

Same function, different names. When this is extracted to the shared library (per H1), pick one name.

### L3. `docker/Dockerfile.frontend.prod:57` removes a file that may not exist

```dockerfile
RUN rm -f /etc/nginx/http.d/default.conf.apk-new
```

This runs unconditionally. If Alpine's package manager changes its behavior, this is harmless (`-f`), but the comment says "Remove the Alpine default 404 vhost" which is misleading -- `.apk-new` files are created during upgrades, not fresh installs.

### L4. JVM args span multiple lines in YAML `>-` block

**File:** `docker/docker-compose.traefik.yml:257-261`

The `>-` YAML block scalar folds newlines into spaces, so:
```
exec su-exec chronicle java $$CHRONICLE_SERVER_XMS $$CHRONICLE_SERVER_XMX
-Xss512k -XX:MetaspaceSize=128m -XX:MaxMetaspaceSize=256m
```
becomes `exec su-exec chronicle java $$CHRONICLE_SERVER_XMS $$CHRONICLE_SERVER_XMX -Xss512k ...` which is correct. However, this is non-obvious and could easily break if someone changes `>-` to `|` or adds blank lines.

### L5. `auto/autoresearch.sh:42` uses `curl` but backend Alpine image only has `wget`

**File:** `auto/autoresearch.sh:42`

```bash
HEAP_MB=$(docker exec chronicle-backend curl -sf http://localhost:40320/chronicle/prometheus/ ...)
```

The Dockerfile.backend no longer installs `curl` (line 86 says "use wget (busybox) for healthchecks"). This `docker exec` will fail silently and fall back to `docker stats`, which returns a different unit (MiB string vs raw bytes). The `docker/auto/autoresearch.sh` correctly uses `wget`.

### L6. Falco healthcheck tests `falco --version` which does not verify the service is running

**File:** `docker/docker-compose.security.yml:146`

```yaml
test: ["CMD-SHELL", "falco --version >/dev/null 2>&1"]
```

This only checks that the binary exists, not that the Falco daemon is actually running and processing events. A healthcheck should verify the process or an HTTP endpoint.

### L7. `tests/security/run-all-security.sh` parallel mode has redundant group sequencing

**File:** `tests/security/run-all-security.sh:105-142`

The comments say groups A, B, C have no dependencies, and group D depends on group C. But in practice, groups A, B, and C are all launched immediately (lines 107-132), and then group D waits for all. The grouping comments suggest sequential execution between groups, but the code starts them all at once. The comments are misleading.

### L8. `verify-image-provenance.sh` is a new script with no callers

**File:** `tests/security/verify-image-provenance.sh`

This 363-line script is not referenced by `run-all-security.sh`, `run-tests-parallel.sh`, or the autoresearch scripts. It appears to be dead code in the test suite -- it exists but is never invoked by any automation.

### L9. Frontend Dockerfile compresses `*.json` files including `version.json`

**File:** `docker/Dockerfile.frontend.prod:31-35`

The pre-compression step compresses all `.json` files, including `version.json`. But `nginx.frontend.conf:82-88` sets `Cache-Control: no-cache` on `/version.json`. The `gzip_static` and `brotli_static` directives will serve the pre-compressed version, which is fine, but the no-cache headers mean the browser re-fetches it every time. The compression effort for this tiny file is wasted (negligible impact).

---

## Summary

| Severity | Count |
|----------|-------|
| HIGH     | 5     |
| MEDIUM   | 7     |
| LOW      | 9     |

**Top 3 recommendations:**
1. Extract the duplicated `docker inspect` batch-parse pattern, BASE_URL detection, and AUTH_TOKEN detection into `lib-test-helpers.sh` (H1, H2, H3).
2. Remove one of the two `autoresearch.sh` files and fix the "p95" calculation (H5).
3. Audit the SKIP-to-PASS conversions and consider using a distinct status like `[INFO]` or `[N/A]` to preserve test signal integrity (M2).
