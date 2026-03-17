# Efficiency Review — Security Hardening Diff (5 commits, 313 lines)

**Scope**: docker-compose.traefik.yml, traefik.yml, dependency-scan.yml, api-header-tests.sh, methodic.gradle

---

## 1. Docker Socket Proxy — Latency on Docker API Calls

**Finding: Negligible latency, but dual endpoint configuration is redundant.**

The docker-socket-proxy (tecnativa/docker-socket-proxy:0.3.0) adds an HAProxy hop between Traefik and the Docker socket. On a local bridge network this adds sub-millisecond latency per Docker API call. Traefik's `watch: true` means it polls/streams container events continuously — the proxy does not sit in the request hot path for HTTP traffic, only for service-discovery metadata. The 64M memory limit is appropriate for this lightweight process.

However, the Docker endpoint is configured **twice**: once via `DOCKER_HOST` env var in docker-compose.traefik.yml (line 57) and once via `endpoint:` in traefik.yml (line 9). Either one is sufficient — Traefik uses the static config `endpoint` first, and `DOCKER_HOST` as a fallback. The env var is unnecessary and creates a maintenance hazard (changing one but not the other). **Recommendation: Remove the `DOCKER_HOST` env var from docker-compose.traefik.yml and keep only the `endpoint` in traefik.yml, which is the canonical location for provider config.**

**Severity**: Low (no functional impact, minor maintenance burden).

---

## 2. CI Workflow — Submodule Checkout for Trivy FS Scan

**Finding: `submodules: recursive` is necessary but expensive. Could be optimized.**

Trivy's `fs` scan type analyzes lock files and build manifests (build.gradle, package.json, bun.lockb) to find vulnerable dependencies. Since this project's dependency declarations live in submodules (chronicle-web has package.json, chronicle-server has build.gradle), skipping `submodules: recursive` would cause Trivy to miss most dependencies. **The recursive checkout IS required for correct scanning.**

However, there are two efficiency improvements available:

- **Shallow submodule clone**: Add `fetch-depth: 1` to the checkout step. Trivy only needs the current tree, not history. This is especially impactful given the 6+ submodules.
  ```yaml
  - uses: actions/checkout@v4
    with:
      submodules: recursive
      fetch-depth: 1
  ```

- **Pin Trivy action version**: Using `aquasecurity/trivy-action@master` means every run pulls the latest commit, which is unpredictable and defeats caching. Pin to a release tag (e.g., `@0.28.0`) for reproducibility and to benefit from GitHub's action cache.

- **Redundant failure step**: The `continue-on-error: true` + separate "Fail on HIGH/CRITICAL" step (lines 69-74) is functionally equivalent to just letting the step fail normally and using `if: always()` on the upload steps. The current pattern works but adds an unnecessary step execution.

**Severity**: Medium (recursive clone without shallow fetch can add 30-60s to CI time).

---

## 3. read_only + tmpfs — Memory Pressure Analysis

**Finding: Mostly correct, but Prometheus is missing a tmpfs and Grafana may need additional writable paths.**

The diff adds `read_only: true` to five containers: Prometheus, Alertmanager, Loki, Promtail, and Grafana. All except Prometheus get `tmpfs` mounts. Analysis per container:

| Container | read_only | tmpfs | Named Volume | Risk |
|-----------|-----------|-------|--------------|------|
| Prometheus | Yes | **None** | `/prometheus` (data) | **Prometheus writes WAL to `/prometheus` (covered by named volume) but may also need to write lock files or temporary files. Test for startup failures.** |
| Alertmanager | Yes | `/tmp:16M` | None | Alertmanager stores notification state in `/alertmanager/data` by default — **no volume is mounted for this**. On restart, it will lose silences and notification history. With `read_only`, it will fail to write state entirely. Needs a volume or `--storage.path` pointed at a tmpfs. |
| Loki | Yes | `/tmp:64M` | `/loki` (data) | OK — Loki's data dir is on a named volume. 64M tmpfs is sufficient for temp operations. |
| Promtail | Yes | `/tmp:16M`, `/run:1M` | None | OK — Promtail's positions file defaults to `/tmp/positions.yaml`. With 16M tmpfs this is fine, but note `noexec` should not affect Promtail. |
| Grafana | Yes | `/tmp:64M` | `/var/lib/grafana` (data) | Grafana writes plugin cache, session data, and CSV exports to `/tmp`. 64M is adequate. However, Grafana also writes to `/var/lib/grafana/plugins/` which is covered by the named volume. **Risk: Grafana may attempt to write to `/etc/grafana/` or `/usr/share/grafana/` on startup — test this.** |

**Total tmpfs memory overhead**: 16M + 64M + 16M + 1M + 64M = **161M** of RAM reserved for tmpfs across 4 containers. This is negligible on a server with enough RAM to run PostgreSQL + a JVM backend. tmpfs pages are only allocated on write, so actual consumption will be well under the limits.

**Severity**: Medium for Alertmanager (potential crash on write); Low for the rest.

---

## 4. TOCTOU Pattern in api-header-tests.sh

**Finding: No TOCTOU vulnerability, but the `check_security_headers` skip-on-error logic has a false-positive risk.**

The new logic (lines 106-112) extracts the HTTP status code from the first line of headers and skips security header checks for any 4xx/5xx response except 401:

```bash
http_code=$(echo "$hdrs" | head -1 | grep -oE '[0-9]{3}' | head -1)
if [ -n "$http_code" ] && [ "$http_code" -ge 400 ] 2>/dev/null && [ "$http_code" != "401" ]; then
    pass "$label — endpoint returns $http_code ..."
    return
fi
```

This marks tests as **PASS** when the endpoint returns an error, which masks real failures. If Traefik is misconfigured and returns 502 to every request, every security header test will pass. A `skip` would be more honest than a `pass` here.

Additionally, the `grep -oE '[0-9]{3}'` on the HTTP status line could match a 3-digit number in the HTTP version string (e.g., `HTTP/1.1` does not match, but `HTTP/100` would). This is unlikely but the pattern is fragile. A safer extraction: `grep -oP 'HTTP/\S+ \K[0-9]{3}'`.

**Severity**: Low (test script, not production code).

---

## 5. api-header-tests.sh — Sequential curl Calls (Missed Concurrency)

**Finding: The rate-limit test sends 30 sequential requests with no parallelism, which is correct for its purpose (testing sequential rate limiting). However, the security header tests in sections 1-4 and 6-7 make ~25 individual curl calls sequentially where many could run in parallel.**

Each `curl` call has a 10-second timeout. In the worst case (unreachable backend), the test script takes 250+ seconds. Launching independent tests as background jobs with `wait` would cut wall-clock time significantly.

That said, this is a test utility script, not a hot path. The inefficiency costs seconds per manual run, not production throughput.

**Severity**: Low (developer convenience only).

---

## 6. Dependency Version Bumps — No Efficiency Impact

Jackson 2.19.0 to 2.21.1 and Jetty 12.0.22 to 12.0.32 are security/maintenance bumps. No architectural impact. Jetty 12.0.32 includes performance improvements to HTTP/2 handling, so this is net-positive for backend throughput.

---

## Summary of Actionable Items

| # | Issue | Severity | Action |
|---|-------|----------|--------|
| 1 | Dual Docker endpoint config (env var + traefik.yml) | Low | Remove `DOCKER_HOST` env var from compose, keep `endpoint` in traefik.yml |
| 2 | CI checkout missing `fetch-depth: 1` | Medium | Add `fetch-depth: 1` to checkout step |
| 3 | Trivy action pinned to `@master` | Medium | Pin to a release tag |
| 4 | Alertmanager `read_only` with no state volume | Medium | Add `--storage.path=/tmp/alertmanager` or a named volume |
| 5 | Prometheus `read_only` without tmpfs | Low | Add tmpfs for `/tmp` (Prometheus may write temp files) |
| 6 | `check_security_headers` marks errors as PASS | Low | Change to `skip` instead of `pass` for 4xx/5xx responses |
| 7 | Grafana `read_only` writable path coverage | Low | Verify startup works; may need tmpfs for additional paths |
