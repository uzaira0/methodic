# Silent Failure Review — Final

Diff: 313 lines across 5 commits. Files: `docker-compose.traefik.yml`, `traefik.yml`, `dependency-scan.yml`, `api-header-tests.sh`, `methodic.gradle`.

---

## 1. docker-socket-proxy crash silently kills Docker discovery

**Severity: HIGH**

If `docker-socket-proxy` crashes or OOMs (64M limit), Traefik loses its Docker provider connection. The `depends_on` only gates startup order — it does not restart Traefik or re-establish the connection if the proxy dies later.

**What happens silently:**
- Traefik continues running and passes its own healthcheck (`traefik healthcheck` checks the Traefik process, not Docker provider connectivity).
- All existing routes from the file provider (`/etc/traefik/dynamic/`) keep working.
- But new containers, label changes, and container removals are invisible. Services that scale or restart get no routing updates.
- `restart: unless-stopped` will restart the proxy, but Traefik's Docker provider may not automatically reconnect depending on version behavior. Even if it does reconnect, there is a gap where discovery is dead with no alert.

**Recommendations:**
- Add a healthcheck to `docker-socket-proxy` (e.g., `wget --spider http://localhost:2375/version`).
- Use `depends_on` with `condition: service_healthy` so Traefik waits for a healthy proxy.
- Add a Prometheus alert or a monitoring check that queries `http://docker-socket-proxy:2375/containers/json` periodically from within the Traefik network.

---

## 2. Empty CROWDSEC_BOUNCER_API_KEY produces a broken CrowdSec config silently

**Severity: HIGH**

The entrypoint runs:
```sh
sed "s|${CROWDSEC_BOUNCER_API_KEY}|$CROWDSEC_BOUNCER_API_KEY|g" \
  /etc/traefik/crowdsec-waf.yml.template > /etc/traefik/dynamic/crowdsec-waf.yml
exec traefik
```

If `CROWDSEC_BOUNCER_API_KEY` is unset or empty in `.env`:
- The `sed` substitution replaces the placeholder with an empty string, producing `CrowdsecLapiKey: ""`.
- The file is written successfully — no error.
- Traefik starts, loads the dynamic config, and activates the CrowdSec bouncer middleware with an empty API key.
- The bouncer plugin will fail to authenticate with the CrowdSec LAPI. Depending on the plugin's `CrowdsecAppsecUnreachableBlock: false` setting, it may **fail open** — allowing all traffic through unfiltered.
- There is no validation step and no startup error.

**Additionally:** The `.env` variable `CROWDSEC_BOUNCER_API_KEY` is not declared with the `?` required-variable syntax (unlike `GRAFANA_ADMIN_PASSWORD` which uses `${GRAFANA_ADMIN_PASSWORD:?Set ...}`), so Compose will not catch a missing value.

**Recommendations:**
- Add a guard before `exec traefik`:
  ```sh
  if [ -z "$CROWDSEC_BOUNCER_API_KEY" ]; then
    echo "FATAL: CROWDSEC_BOUNCER_API_KEY is empty" >&2
    exit 1
  fi
  ```
- Or use the `${CROWDSEC_BOUNCER_API_KEY:?...}` syntax in `docker-compose.traefik.yml` to fail at compose-up time.
- Consider changing `CrowdsecAppsecUnreachableBlock` to `true` so that CrowdSec failures block traffic rather than allowing it.

---

## 3. api-header-tests.sh: `http_code -ge 400` with empty or non-numeric value

**Severity: MEDIUM**

Line 109:
```sh
if [ -n "$http_code" ] && [ "$http_code" -ge 400 ] 2>/dev/null && [ "$http_code" != "401" ]; then
```

The `http_code` is extracted via:
```sh
http_code=$(echo "$hdrs" | head -1 | grep -oE '[0-9]{3}' | head -1)
```

**Partial mitigation exists:** The `[ -n "$http_code" ]` check prevents the empty-string case, and `2>/dev/null` on the `-ge` comparison suppresses the bash error if the value is somehow non-numeric. When `-ge` fails on a non-numeric string, it returns false (exit code 2), and with stderr suppressed, execution falls through to the normal header checks. This is acceptable — a non-numeric code won't wrongly trigger the skip path.

**Remaining issue:** If the first line of `hdrs` contains a 3-digit number that is NOT the HTTP status code (e.g., from a malformed response or proxy header), the regex `[0-9]{3}` will match it and produce incorrect logic. This is an edge case but could cause tests to be silently skipped (counted as PASS with the "auth enforced" message) when they should be checking headers.

**Recommendations:**
- Parse the HTTP status more precisely: `grep -oE 'HTTP/[0-9.]+ [0-9]{3}' | grep -oE '[0-9]{3}$'`.
- Validate `http_code` is in the 100-599 range before using it.

---

## 4. `read_only: true` containers — EROFS write failures

**Severity: MEDIUM**

Containers set to `read_only: true`: prometheus, alertmanager, loki, promtail, grafana.

**Analysis per container:**

| Container | Writable paths | Risk |
|-----------|---------------|------|
| **Prometheus** | `/prometheus` (named volume) | **Missing tmpfs.** Prometheus writes lock files and WAL to `/prometheus` (covered by volume), but also writes to a temp dir. Default `TMPDIR` is `/tmp` which is read-only with no tmpfs mount. If Prometheus needs `/tmp` for compaction or rule evaluation temp files, it will get EROFS. |
| **Alertmanager** | tmpfs at `/tmp` | Alertmanager stores silences and notification state in `/alertmanager` by default. No volume is mounted there. If the default data dir overlaps with the read-only filesystem, state persistence fails silently on restart. Alertmanager uses `/tmp` (covered) but its `--storage.path` defaults to `data/` relative to working dir. |
| **Loki** | `/loki` (named volume), tmpfs at `/tmp` | Likely OK — primary write path is the named volume. |
| **Promtail** | tmpfs at `/tmp` and `/run` | Promtail stores its position file (tracking which log lines have been sent) — default path is `/tmp/positions.yaml`. With `tmpfs` on `/tmp`, positions are lost on every container restart, causing Promtail to **re-send all log lines from the beginning of the log files**. This is a silent data duplication issue. |
| **Grafana** | `/var/lib/grafana` (named volume), tmpfs at `/tmp` | Grafana also writes to `/var/lib/grafana/plugins` and session storage. The named volume covers this. But Grafana's SQLite database and internal caches need the volume to be writable — should be fine since it's not `:ro`. |

**Key findings:**
- **Prometheus has no `/tmp` tmpfs** — compaction or temporary file operations will hit EROFS silently.
- **Promtail positions file on tmpfs** — lost every restart, causing silent log re-ingestion (duplicated audit log entries in Loki).
- **Alertmanager has no persistent data volume** — notification state and silences lost on restart.

**Recommendations:**
- Add `tmpfs: ["/tmp:noexec,nosuid,size=32M"]` to Prometheus.
- Move Promtail's position file to a named volume: add `positions: {filename: /positions/positions.yaml}` in promtail config and mount a `promtail_positions` volume at `/positions`.
- Add a named volume for Alertmanager's data dir or pass `--storage.path=/tmp/alertmanager` if persistence is not needed.

---

## 5. CI workflow: Trivy fail-open behavior

**Severity: HIGH**

The `dependency-scan.yml` workflow uses `continue-on-error: true` on the Trivy scan step. The intent is to upload SARIF results even when vulnerabilities are found (exit-code 1). The final step then checks `steps.trivy.conclusion == 'failure'` to fail the job.

**The problem:** `continue-on-error: true` makes `steps.trivy.conclusion` always `'success'` — even when the step's exit code is non-zero. The property that captures the actual exit status is `steps.trivy.outcome`, not `steps.trivy.conclusion`. From the GitHub Actions docs:

- `outcome`: The actual result before `continue-on-error` is applied (`success`, `failure`, `cancelled`, `skipped`)
- `conclusion`: The final result after `continue-on-error` is applied (always `success` when `continue-on-error: true`)

**Consequence:** The "Fail on HIGH/CRITICAL vulnerabilities" step **never executes** because `conclusion` is always `'success'`. The entire scan is fail-open: it will never fail the CI pipeline regardless of what Trivy finds. Vulnerabilities are uploaded to the Security tab (if the SARIF step works), but the PR/push check shows green.

**Additionally:** If Trivy itself crashes (e.g., DB download fails, OOM), it also returns non-zero, which `continue-on-error` swallows. The SARIF upload step runs with `if: always()` but `trivy-fs.sarif` may not exist or may be malformed, causing a secondary silent failure.

**Recommendations:**
- Change the condition to `steps.trivy.outcome == 'failure'`:
  ```yaml
  - name: Fail on HIGH/CRITICAL vulnerabilities
    if: steps.trivy.outcome == 'failure'
    run: |
      echo "::error::Trivy found HIGH or CRITICAL vulnerabilities."
      exit 1
  ```
- Add a file-existence check before SARIF upload:
  ```yaml
  - name: Upload Trivy SARIF to GitHub Security
    uses: github/codeql-action/upload-sarif@v3
    if: always() && hashFiles('trivy-fs.sarif') != ''
  ```

---

## Summary

| # | Finding | Severity | Silent? | Fails Open? |
|---|---------|----------|---------|-------------|
| 1 | docker-socket-proxy crash kills Docker discovery | HIGH | Yes — Traefik healthcheck passes, no alert | No — existing routes work, new ones don't |
| 2 | Empty CROWDSEC_BOUNCER_API_KEY | HIGH | Yes — sed succeeds, Traefik starts | Yes — bouncer with empty key + `UnreachableBlock: false` passes traffic |
| 3 | http_code parsing edge case in header tests | MEDIUM | Partially — tests silently skipped as PASS | Yes — header checks bypassed |
| 4a | Prometheus missing /tmp tmpfs | MEDIUM | Yes — EROFS errors in container logs only | Depends — compaction may fail silently |
| 4b | Promtail positions lost on tmpfs | MEDIUM | Yes — duplicated logs, no error | N/A — data quality issue |
| 4c | Alertmanager no persistent state dir | LOW | Yes — silences/state lost on restart | N/A — operational issue |
| 5 | Trivy CI uses `conclusion` instead of `outcome` | HIGH | Yes — job always passes | Yes — vulnerabilities never fail the pipeline |
