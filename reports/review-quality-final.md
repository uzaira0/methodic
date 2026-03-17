# Code Quality Review — Final Diff (5 commits, 313 lines)

**Scope**: docker-compose.traefik.yml (docker-socket-proxy, read_only hardening), traefik.yml, dependency-scan.yml, api-header-tests.sh, gradles/methodic.gradle

---

## Findings

### 1. DOCKER_HOST redundancy — endpoint configured in two places (LOW)

**Files**: `docker/docker-compose.traefik.yml` (line ~57), `docker/traefik/traefik.yml` (line 9)

The Docker socket proxy endpoint is declared twice:
- `DOCKER_HOST: tcp://docker-socket-proxy:2375` as an environment variable on the `traefik` service
- `endpoint: tcp://docker-socket-proxy:2375` in `traefik.yml` under `providers.docker`

Traefik's `providers.docker.endpoint` takes precedence over `DOCKER_HOST`. The env var is therefore dead state — it does nothing when the static config already specifies the endpoint. If someone later changes only one location, the silent redundancy becomes a silent mismatch.

**Recommendation**: Remove the `DOCKER_HOST` env var from docker-compose, or remove the `endpoint` from traefik.yml and rely solely on the env var. One source of truth.

---

### 2. docker-socket-proxy depends_on lacks health check condition (MEDIUM)

**File**: `docker/docker-compose.traefik.yml` (line ~73)

```yaml
depends_on:
  - docker-socket-proxy
```

This is `depends_on` without `condition: service_healthy`. Since `docker-socket-proxy` has no `healthcheck` defined, Docker Compose only waits for the container to *start*, not for the proxy to be *ready*. On slow starts or resource-constrained hosts, Traefik may attempt to connect to `tcp://docker-socket-proxy:2375` before the proxy is listening, causing a startup failure that requires manual restart.

**Recommendation**: Add a healthcheck to `docker-socket-proxy` (e.g., `test: ["CMD-SHELL", "wget --quiet --tries=1 -O /dev/null http://localhost:2375/_ping || exit 1"]`) and change to `depends_on: docker-socket-proxy: condition: service_healthy`.

---

### 3. api-header-tests.sh — `http_code >= 400` skip hides real security failures (HIGH)

**File**: `tests/security/api-header-tests.sh` (lines 106–112)

```bash
if [ -n "$http_code" ] && [ "$http_code" -ge 400 ] 2>/dev/null && [ "$http_code" != "401" ]; then
    pass "$label — endpoint returns $http_code (auth enforced, headers set by Traefik on successful responses)"
    return
fi
```

This early-return converts *any* non-401 error (403, 404, 500, 502, 503) into a **PASS** for header checks. Problems:

1. **A 500 Internal Server Error is reported as PASS** with the message "auth enforced, headers set by Traefik on successful responses" — which is misleading; a 500 is neither auth enforcement nor a successful response.
2. **A 502/503 (proxy or backend down) is reported as PASS** — masking infrastructure problems as passing security tests.
3. **The message claims "headers set by Traefik on successful responses"** for error responses — this is a contract mismatch between the comment and reality.
4. The 401 exception is arbitrary — 403 (Forbidden) is equally an auth response but gets the blanket pass treatment.

**Recommendation**: Narrow the skip to codes that genuinely indicate "auth blocked, header test not applicable" (401, 403). Treat 5xx as `fail` or `skip` with an honest message. At minimum, do not count these as `pass`.

---

### 4. api-header-tests.sh — 401/403 conflation weakens auth contract tests (MEDIUM)

**File**: `tests/security/api-header-tests.sh` (lines 212, 244, 264)

All three auth rejection tests (no auth, bad signature, expired token) now accept both 401 and 403:

```bash
if [ "$status" = "401" ] || [ "$status" = "403" ]; then
```

401 and 403 have different semantics: 401 = "not authenticated" (missing/invalid credentials), 403 = "not authorized" (valid identity, insufficient permissions). For these test cases (no token, bad signature, expired token), the correct response is strictly 401. Accepting 403 masks a regression where the backend might be authenticating but failing authorization for a different reason, or where a middleware is incorrectly translating the error.

**Recommendation**: Keep the primary assertion as `401`. If 403 must be tolerated, log it as a `pass` with a warning, or use a separate assertion level (e.g., `warn`) so the test output distinguishes "exactly right" from "acceptable but unexpected."

---

### 5. Prometheus `read_only: true` without tmpfs may break WAL writes (MEDIUM)

**File**: `docker/docker-compose.traefik.yml` (line ~580)

Prometheus is set to `read_only: true`. It has `prometheus_data:/prometheus` for TSDB storage, but Prometheus also writes temporary files and WAL lock files. The `prom/prometheus` image may write to paths outside `/prometheus` (e.g., `/tmp`). Unlike alertmanager, loki, promtail, and grafana — all of which received `tmpfs` mounts for `/tmp` — Prometheus did **not** get a tmpfs.

**Recommendation**: Add `tmpfs: ["/tmp:noexec,nosuid,size=16M"]` to the prometheus service to match the pattern used for the other read_only containers.

---

### 6. Alertmanager `read_only: true` with no persistent storage volume (LOW)

**File**: `docker/docker-compose.traefik.yml` (lines 602–627)

Alertmanager is set to `read_only: true` with a tmpfs at `/tmp`, but it has no named volume for its data directory (`/alertmanager`). Alertmanager stores silence and notification state in `/alertmanager/data/` by default. With `read_only: true` and no writable volume at that path, alertmanager will fail to persist silences across restarts. Currently this may be acceptable if no silences are configured, but it is a latent breakage waiting to happen.

**Recommendation**: Either add a named volume (`alertmanager_data:/alertmanager`) or add a tmpfs at `/alertmanager` if state loss on restart is acceptable.

---

### 7. Trivy action pinned to `@master` — supply chain risk (LOW)

**File**: `.github/workflows/dependency-scan.yml` (line 44)

```yaml
uses: aquasecurity/trivy-action@master
```

Pinning to `@master` means every run fetches whatever is currently on the master branch. A compromised or broken commit on that branch would affect CI. The other actions in the same file are version-pinned (`@v4`, `@v3`).

**Recommendation**: Pin to a release tag (e.g., `@0.29.0`) or a commit SHA.

---

### 8. Traefik sed entrypoint — fragile template expansion (LOW, pre-existing)

**File**: `docker/docker-compose.traefik.yml` (line ~71)

```yaml
sed "s|\$${CROWDSEC_BOUNCER_API_KEY}|$$CROWDSEC_BOUNCER_API_KEY|g" ...
```

This entrypoint override replaces the Traefik default entrypoint with `sh -c`. If the `CROWDSEC_BOUNCER_API_KEY` contains sed metacharacters (`|`, `&`, `\`), the substitution breaks silently, producing a malformed dynamic config file. The diff did not introduce this, but the new docker-socket-proxy changes mean Traefik now depends on *two* external things being correct at startup (proxy ready + sed succeeding), making the failure surface wider.

**Recommendation**: Use `envsubst` instead of `sed` for template expansion, consistent with the pattern already used for `rhizome-docker.yaml.template`.

---

## Summary

| # | Severity | Issue |
|---|----------|-------|
| 1 | LOW | DOCKER_HOST env var redundant with traefik.yml endpoint |
| 2 | MEDIUM | docker-socket-proxy depends_on has no healthcheck gate |
| 3 | HIGH | `>= 400` skip in header tests counts 5xx as PASS |
| 4 | MEDIUM | 401/403 conflation weakens auth contract precision |
| 5 | MEDIUM | Prometheus read_only without tmpfs (inconsistent with peers) |
| 6 | LOW | Alertmanager read_only with no data volume |
| 7 | LOW | Trivy action pinned to @master |
| 8 | LOW | sed-based template expansion fragility |

**Highest priority**: Finding #3 — the header test skip logic actively masks failures as passes, which undermines the purpose of the security test suite.
