# Efficiency Review: Chronicle Codebase Optimization (31 files, 1601 insertions)

Reviewed: 2026-03-16

---

## 1. Docker Layer Optimization (Dockerfile.backend)

### Good decisions

- **BuildKit cache mounts** for Gradle caches (`docker/Dockerfile.backend:37-39`, `:53-55`): eliminates re-downloading dependencies on code-only changes. Correct use of `--mount=type=cache`.
- **JLink custom JRE** (`docker/Dockerfile.backend:62-73`): ~81MB savings is significant. Module list is well-curated for the Spring/Jetty/Hazelcast stack.
- **`COPY --chown`** (`docker/Dockerfile.backend:92`): avoids a separate `chown -R` layer that would duplicate the entire `/server` tree.
- **Test JAR deletion** (`docker/Dockerfile.backend:58`): good housekeeping.
- **Alpine base** instead of `eclipse-temurin:17-jre`: substantial image size reduction.

### Issues

**E-1: JLink stage uses full JDK Alpine image unnecessarily** (`docker/Dockerfile.backend:62`)
The `jlinker` stage pulls `eclipse-temurin:17-jdk-alpine` just to run `jlink`. This ~300MB image is downloaded and cached even though only `jlink` is needed. Since BuildKit discards unused stages, this only costs time on first build, but it could use the same `builder` stage's JDK (which is already present) instead of a separate stage. Not critical but the extra pull adds to CI cold-start time.

**E-2: `dos2unix` runs twice on gradlew** (`docker/Dockerfile.backend:29`, `:45`)
Line 29 runs `dos2unix gradlew` on the dependency-resolution layer. Line 45 runs `find . -name "gradlew" -exec dos2unix {} \;` after `COPY . /app`, which overwrites the first gradlew. The first `dos2unix` on gradlew is wasted work since `COPY . /app` replaces it. However, this is only a build-time cost of ~10ms, so it is negligible.

**E-3: `git init` runs twice** (`docker/Dockerfile.backend:32-33`, `:49-50`)
Same pattern: first git init for dependency resolution, second after full COPY. The first is needed for `publish.gradle`'s `git describe` during dependency resolution. The second overwrites it. This is unavoidable given the layer separation strategy -- not a bug but worth noting.

---

## 2. Docker Compose Startup Command Pipeline

### Good decisions

- **Validation checks** (`docker/docker-compose.traefik.yml:251-254`): checking that envsubst produced non-empty files before starting Java is a solid fail-fast pattern.
- **`su-exec`** instead of `USER` directive: necessary because envsubst needs root to write config files.

### Issues

**E-4: `chown -R` on `/var/log/chronicle` runs on every container start** (`docker/docker-compose.traefik.yml:255`)
This volume is persistent. After the first start, all files already have correct ownership. The `-R` flag walks the entire directory tree including potentially years of audit logs (HIPAA requires 6 years / 2190 days retention). On a production system with millions of audit log entries, this could take seconds on every restart.

**Fix**: Use `chown chronicle:chronicle /var/log/chronicle` (no `-R`) to fix only the directory itself, or add a conditional: `[ "$(stat -c %U /var/log/chronicle)" = "chronicle" ] || chown ...`.

**E-5: JVM flags split across lines without proper escaping** (`docker/docker-compose.traefik.yml:257-260`)
The `exec su-exec chronicle java` command and subsequent JVM flags are on separate lines in a YAML `>-` block. The YAML `>-` scalar folds newlines into spaces, so this works, but it is fragile. A missing `&&` or stray semicolon between the `chown` lines (255-256) and the `exec` (257) means the `chown` failure on line 256 (which uses `;` not `&&`) does NOT prevent Java from starting. This is intentional (the `2>/dev/null` suggests best-effort) but should be documented.

**E-6: Six sequential `envsubst` calls** (`docker/docker-compose.traefik.yml:244-250`)
Each `envsubst` is a separate process spawn. These could be parallelized with background jobs or combined into a loop:
```sh
for tpl in rhizome.yaml chronicle-auth.yaml mail.yaml mobile-security.yaml vault.yaml cors.yaml; do
  envsubst < "/server/config/${tpl}.template" > "/server/config/${tpl}" &
done
wait
```
However, `envsubst` is ~5ms per call, so the total is ~30ms. Not worth optimizing unless startup latency is critical.

---

## 3. Test Script Docker Exec Overhead

### Excellent optimization: database-security-tests.sh

**Before**: The original `database-security-tests.sh` made approximately 25+ individual `docker exec` calls (1 for table list + N for TDE checks + 4 for SSL + 4 for connections + 4 for extensions + 8 for integrity).

**After** (`tests/security/database-security-tests.sh:76-87`, `:117-132`, `:369-387`, `:433-451`, `:494-524`): Batched into 5 `docker exec` calls total using compound SQL queries with `UNION ALL` and pipe-delimited output. Each `docker exec` has ~100-200ms overhead (container namespace entry, process creation), so this saves **~4-5 seconds** per run.

### Excellent optimization: container-security-tests.sh

**Before**: ~8 `docker inspect` calls per container * N containers = 8N calls.

**After** (`tests/security/container-security-tests.sh:55-86`): Single `docker inspect "${CONTAINERS[@]}"` call, parsed once with Python into shell variables. For 10 containers, this eliminates ~79 `docker inspect` calls.

### Excellent optimization: smoke-tests.sh

Same batch-inspect pattern applied (`tests/security/smoke-tests.sh:92-130` in the diff, starting at the `_INSPECT_JSON` assignment). Eliminates N*4+ individual `docker inspect` calls.

### Issue

**E-7: `eval` of Python-generated shell code is a security concern** (`tests/security/container-security-tests.sh:56-80`, `tests/security/smoke-tests.sh` similar)
The pattern `eval "$(echo "$_INSPECT_JSON" | python3 -c "...")"` executes dynamically generated shell code. If a container name contains shell metacharacters (unlikely with Docker's naming rules, but possible with custom `container_name` values), this could break or be exploitable. The use of `shlex.quote()` in the Python code mitigates this, which is correct. Still, consider using `declare -A` associative arrays or a JSON query tool like `jq` for robustness.

**E-8: `docker exec` for PID 1 user check still exists** (`tests/security/container-security-tests.sh:124`)
After batching all `docker inspect` data, there is still a per-container `docker exec` call to check `stat -c "%U" /proc/1/exe`. This is only for containers where `User` is empty/root (the `su-exec` pattern), so it only fires for 1-2 containers, which is acceptable.

---

## 4. Parallel Mode Implementation

### Good decisions in run-all-security.sh

- **Layer grouping** (`tests/security/run-all-security.sh:82-88`): Groups A/B/C run concurrently; Group D waits for dependencies. This is correct since HIPAA/GDPR checks depend on database output.
- **Per-layer timing** captured in `.cnt` files for performance profiling.
- **Shared Trivy cache** (`tests/security/run-all-security.sh:65-66`): prevents N parallel Trivy invocations from each downloading the vulnerability DB.

### Issues

**E-9: Parallel mode launches layers as recursive script invocations** (`tests/security/run-all-security.sh:104-107`)
Each parallel layer runs `bash "$SCRIPT_DIR/run-all-security.sh" --layer "$layer"`, which re-parses the entire 1000+ line script, re-runs the BACKEND_URL detection (2 curl calls), and re-sources all the function definitions. For 24 layers, this means 24 script re-parses and 48 curl calls just for URL detection.

**Fix**: Export `BACKEND_URL` and `DOMAIN` before launching parallel layers (they are already exported via environment in the `run_layer` function, but the child script still runs its own detection at lines 44-54). Add `export BACKEND_URL DOMAIN` before the parallel block.

**E-10: Groups A, B, and C all start simultaneously despite the comment saying "Groups run sequentially"** (`tests/security/run-all-security.sh:117-152`)
The code launches all three groups without waiting between them. This is actually *better* than the documented behavior (maximum parallelism), but the comments at lines 87-88 are misleading: "Groups run sequentially only when there are actual data dependencies." In practice, all non-dependent groups run concurrently, which is correct but the documentation should match.

**E-11: `run-tests-parallel.sh` duplicates functionality** (`tests/security/run-tests-parallel.sh`)
This is a separate parallel runner that runs 8 specific test scripts concurrently. Meanwhile, `run-all-security.sh --parallel` runs 24 layers concurrently (which includes those same 8 scripts). Having two parallel runners is confusing. The dedicated `run-tests-parallel.sh` is simpler and more focused, but `run-all-security.sh --parallel` is more comprehensive. One should be deprecated.

---

## 5. Test Result Inflation (Skip-to-Pass Conversions)

### Issue

**E-12: Multiple `skip` results converted to `pass` without changing the underlying condition** (multiple files)

Several test assertions were converted from `skip` to `pass` to reduce the skip count, but the underlying condition being tested has not changed:

- `tests/security/api-header-tests.sh:605-609`: HSTS absent on HTTP-only deployment changed from `skip` to `pass`. The test previously correctly identified this as a skip (the condition cannot be validated). Marking it as `pass` hides the fact that HSTS is not being tested.

- `tests/security/api-header-tests.sh:620-623`: Referrer-Policy absent on API endpoint changed from `skip` to `pass` with rationale "acceptable for JSON-only responses." This is a judgment call, not a test result.

- `tests/security/api-header-tests.sh:651-654`: No `X-RateLimit-*` headers changed from 2 `skip`s to 2 `pass`es claiming CrowdSec/Fail2ban handle it. But the test does not verify CrowdSec/Fail2ban are actually enforcing rate limits.

- `tests/security/api-header-tests.sh:662-663`, `:675-677`, `:687-688`, `:699`: Multiple CORS checks where untrusted origin gets no response -- changed from `skip` to `pass`.

- `tests/security/session-management-tests.sh:235-240` (diff line 2344-2352): No `Set-Cookie` header changed from 3 skips to 3 passes.

- `tests/security/database-security-tests.sh:265`, `:286`, `:342`, `:355`: Superuser checks changed from `skip` (acknowledging the risk) to `pass` (claiming mitigations). The mitigations listed (container isolation, no host port binding) are real, but the test was designed to flag the security risk, not validate the mitigations.

**Impact**: The `total_pass` count is inflated by ~15-20 assertions that were previously `skip`s. The `total_skip` count drops correspondingly. This makes the security posture appear improved when no actual security controls were added.

---

## 6. CrowdSec Whitelist Overhead

### Issue

**E-13: `setup_crowdsec_whitelist` called redundantly from multiple scripts** (`tests/security/lib-test-helpers.sh`)

When run via `run-tests-parallel.sh`, the whitelist is cleared once at the top (line 51-53). But each individual test script that sources `lib-test-helpers.sh` also calls `setup_crowdsec_whitelist`:
- `business-logic-tests.sh:39-41`
- `contract-drift-tests.sh` (diff line 1021-1024)
- `smoke-tests.sh` (diff line 2366-2369)

In parallel mode, this means 3+ concurrent `docker exec chronicle-crowdsec cscli decisions delete` calls, each taking ~200-500ms. The parallel runner already handles this centrally.

**Fix**: Add a guard variable: `[ "${CROWDSEC_WHITELIST_DONE:-}" = "1" ] && return 0` at the top of `setup_crowdsec_whitelist`, and export `CROWDSEC_WHITELIST_DONE=1` after the first call.

---

## 7. Business Logic Tests: Redundant URL Detection

### Issue

**E-14: Duplicate URL detection with two curl calls** (`tests/security/business-logic-tests.sh:28-30`)
```sh
if curl -sf -o /dev/null -m 3 http://localhost:40320/chronicle/v3/ 2>/dev/null || \
   [ "$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://localhost:40320/chronicle/v3/ 2>/dev/null)" != "000" ]; then
```
The first `curl -sf` already checks reachability. If it succeeds, the second `curl` in the `||` is skipped (short-circuit). But if it fails, the second curl repeats the same request just to check if the HTTP code is not "000" (connection refused). A simpler approach: `http_code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 ...)` and check `[ "$http_code" != "000" ]`.

This same pattern appears in `session-management-tests.sh:28-30` and `business-logic-tests.sh:28-30`.

---

## 8. Frontend Dockerfile Optimization

### Good decisions

- **Source map deletion** (`docker/Dockerfile.frontend.prod:22`): removes debug artifacts from production image.
- **Pre-compression** with Brotli and gzip (`docker/Dockerfile.frontend.prod:33-45`): eliminates CPU overhead at serving time.
- **Brotli static serving** via `nginx-mod-http-brotli` (`docker/nginx.frontend.conf:7`).

### Issue

**E-15: Brotli compression runs sequentially** (`docker/Dockerfile.frontend.prod:36-43`)
The `while read f; do gzip -9 -k "$f"; brotli -q 11 "$f"; done` loop processes each file sequentially. Brotli at quality 11 is CPU-intensive (~100ms per file). For a bundle with 50+ files, this adds ~5-10 seconds to the build.

**Fix**: Use `xargs -P$(nproc)` or GNU `parallel`:
```sh
find /app/dist -type f \( -name '*.js' -o -name '*.css' ... \) -print0 | \
  xargs -0 -P$(nproc) -I{} sh -c 'gzip -9 -k "{}" && brotli -q 11 "{}"'
```

---

## 9. Memory / Resource Issues

### Issue

**E-16: Oversized request body test creates 1MB string in shell variable** (`tests/security/api-header-tests.sh:465-469`)
The optimization to write to a tmpfile and use `curl -d @file` is correct and was already applied in this diff. Good fix.

### Issue

**E-17: `pg_stat_statements.track=all` without `pg_stat_statements.max` limit** (`docker/docker-compose.traefik.yml:108`)
Adding `pg_stat_statements` with `track=all` tracks every query including utility statements. The default `pg_stat_statements.max` is 5000 entries, consuming ~1.5MB of shared memory. With `track=all`, this can fill up quickly and cause eviction churn. Consider setting `pg_stat_statements.max=10000` explicitly and monitoring with `SELECT pg_stat_statements_info()`.

---

## 10. Missed Concurrency Opportunities

**E-18: `run_sql` helper re-reads `.env` on every call** (`tests/security/database-security-tests.sh:43-46`)
The `run_sql` function reads and greps `.env` for `POSTGRES_PASSWORD` on every invocation. With the batched queries this is now only ~5 calls, but the password could be read once and captured in a closure variable.

**E-19: BACKEND_URL detection probes two URLs sequentially** (`tests/security/run-all-security.sh:48-54`)
```sh
if curl -sf http://localhost:40320/chronicle/prometheus/ &>/dev/null; then
  BACKEND_URL="http://localhost:40320"
elif [ -n "${DOMAIN:-}" ] && curl -sf "http://${DOMAIN}/chronicle/prometheus/" &>/dev/null; then
  BACKEND_URL="http://${DOMAIN}"
fi
```
The 3-second timeout on each curl means worst case 6 seconds. These two probes could run in parallel with background jobs.

---

## Summary of Findings

| ID | Severity | File | Description |
|----|----------|------|-------------|
| E-1 | Low | Dockerfile.backend:62 | Separate JDK image pull for jlink |
| E-4 | **Medium** | docker-compose.traefik.yml:255 | `chown -R` on audit log volume every restart |
| E-7 | Low | container-security-tests.sh:56 | `eval` of generated shell code (mitigated by shlex.quote) |
| E-9 | **Medium** | run-all-security.sh:104 | Parallel layers re-parse entire script + re-detect URLs |
| E-11 | Low | run-tests-parallel.sh | Duplicate parallel runner |
| E-12 | **High** | multiple files | ~15-20 skip-to-pass conversions inflate metrics |
| E-13 | Low | lib-test-helpers.sh | Redundant CrowdSec whitelist calls in parallel mode |
| E-14 | Low | business-logic-tests.sh:28 | Duplicate curl for URL detection |
| E-15 | Low | Dockerfile.frontend.prod:36 | Sequential Brotli compression |
| E-17 | Low | docker-compose.traefik.yml:108 | pg_stat_statements without max limit |

### What was done well

1. **Database test batching**: Reduced ~25 `docker exec` calls to 5 in `database-security-tests.sh` (E-savings: ~4-5s per run).
2. **Container inspect batching**: Single `docker inspect` call for all containers in both `container-security-tests.sh` and `smoke-tests.sh` (E-savings: ~2-3s per run for 10 containers).
3. **Trivy cache sharing**: Prevents parallel DB downloads.
4. **Semgrep parallelization**: 4 scans run concurrently within the SAST layer.
5. **Trivy image scan parallelization**: Backend + frontend + misconfig scans run concurrently.
6. **JLink custom JRE**: ~81MB runtime image reduction.
7. **`COPY --chown`**: Avoids duplicate layer in Dockerfile.
8. **Brotli pre-compression**: Zero CPU overhead at serve time.
9. **Source map deletion**: Reduces image size and prevents debug info leakage.
