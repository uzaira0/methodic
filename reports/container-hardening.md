# Chronicle Container Hardening Report

**Date:** 2026-03-16
**Scope:** All `chronicle-*` containers in the Docker Compose deployment at `/opt/chronicle`
**Containers audited:** 13

---

## 1. Non-Root User Operation

| Container | Config User | Runtime User | Status | Recommendation |
|-----------|-------------|-------------|--------|----------------|
| chronicle-frontend | `nginx` | nginx | PASS | |
| chronicle-backend | *(empty)* | chronicle | PASS | Set `USER chronicle` in Dockerfile to satisfy static scanners (currently uses `su-exec` at runtime) |
| chronicle-postgres | `26` | postgres | PASS | |
| chronicle-falco | `0` | root | WARN | Requires root for kernel tracing; acceptable for security tooling |
| chronicle-promtail | *(empty)* | root | WARN | Runs as root to read log files; consider mounting logs with group read and running as non-root |
| chronicle-traefik | *(empty)* | root | WARN | Runs as root for port 80/443 binding; mitigate with `cap_drop: ALL` + `cap_add: NET_BIND_SERVICE` |
| chronicle-crowdsec | *(empty)* | root | WARN | Security tooling; consider running as non-root with volume permissions adjusted |
| chronicle-fail2ban | *(empty)* | root | WARN | Requires root for iptables manipulation; acceptable |
| chronicle-grafana | `472` | grafana | PASS | |
| chronicle-vault | *(empty)* | root | WARN | Runs as root; Vault official image supports non-root operation with IPC_LOCK cap |
| chronicle-prometheus | `nobody` | nobody | PASS | |
| chronicle-loki | `10001` | loki | PASS | |
| chronicle-alertmanager | `nobody` | nobody | PASS | |

**Summary:** 7/13 PASS, 6/13 WARN. All application containers (frontend, backend, postgres, grafana, prometheus, loki, alertmanager) run as non-root. Root usage is confined to infrastructure/security tooling (Falco, Traefik, CrowdSec, Fail2ban, Promtail, Vault).

---

## 2. Capability Dropping

| Container | cap_drop | cap_add | Status | Recommendation |
|-----------|----------|---------|--------|----------------|
| chronicle-frontend | ALL | *(none)* | PASS | |
| chronicle-backend | *(none)* | *(none)* | FAIL | Add `cap_drop: [ALL]` to compose service |
| chronicle-postgres | *(none)* | *(none)* | FAIL | Add `cap_drop: [ALL]` to compose service |
| chronicle-falco | *(none)* | *(none)* | WARN | Privileged container; cap_drop not applicable |
| chronicle-promtail | ALL | *(none)* | PASS | |
| chronicle-traefik | *(none)* | *(none)* | FAIL | Add `cap_drop: [ALL]`, `cap_add: [NET_BIND_SERVICE]` |
| chronicle-crowdsec | *(none)* | *(none)* | FAIL | Add `cap_drop: [ALL]` |
| chronicle-fail2ban | *(none)* | CAP_NET_ADMIN, CAP_NET_RAW | FAIL | Add `cap_drop: [ALL]` (keep cap_add for iptables) |
| chronicle-grafana | ALL | *(none)* | PASS | |
| chronicle-vault | *(none)* | CAP_IPC_LOCK | FAIL | Add `cap_drop: [ALL]` (keep IPC_LOCK) |
| chronicle-prometheus | ALL | *(none)* | PASS | |
| chronicle-loki | ALL | *(none)* | PASS | |
| chronicle-alertmanager | ALL | *(none)* | PASS | |

**Summary:** 6/13 PASS, 6/13 FAIL, 1/13 WARN. The monitoring stack is well-hardened. Backend, postgres, traefik, crowdsec, fail2ban, and vault are missing `cap_drop: [ALL]`.

---

## 3. Read-Only Root Filesystem

| Container | read_only | Status | Recommendation |
|-----------|-----------|--------|----------------|
| chronicle-frontend | true | PASS | |
| chronicle-backend | false | FAIL | Set `read_only: true`, add tmpfs for `/tmp`, `/var/log/chronicle` |
| chronicle-postgres | false | WARN | Postgres needs writable data dirs; use tmpfs for `/tmp`, `/run` |
| chronicle-falco | false | WARN | Privileged; not applicable |
| chronicle-promtail | false | FAIL | Set `read_only: true`, add tmpfs for `/tmp`, `/run` |
| chronicle-traefik | false | FAIL | Set `read_only: true`, add tmpfs for `/tmp` |
| chronicle-crowdsec | false | FAIL | Set `read_only: true` with appropriate tmpfs mounts |
| chronicle-fail2ban | false | FAIL | Set `read_only: true` with tmpfs for `/tmp`, `/var/run` |
| chronicle-grafana | false | FAIL | Set `read_only: true`, add tmpfs for `/tmp` |
| chronicle-vault | false | FAIL | Set `read_only: true` with tmpfs for `/tmp`, `/vault/logs` |
| chronicle-prometheus | false | FAIL | Set `read_only: true`, add tmpfs for `/tmp` |
| chronicle-loki | false | FAIL | Set `read_only: true`, add tmpfs for `/tmp` |
| chronicle-alertmanager | false | FAIL | Set `read_only: true`, add tmpfs for `/tmp` |

**Summary:** 1/13 PASS (frontend only), 10/13 FAIL, 2/13 WARN. This is the weakest control across the deployment.

---

## 4. Memory Limits

| Container | Limit | Status | Recommendation |
|-----------|-------|--------|----------------|
| chronicle-frontend | 128 MB | PASS | |
| chronicle-backend | 3072 MB | PASS | Appropriate for JVM with -Xmx2g |
| chronicle-postgres | 1024 MB | PASS | |
| chronicle-falco | 512 MB | PASS | |
| chronicle-promtail | 128 MB | PASS | |
| chronicle-traefik | 256 MB | PASS | |
| chronicle-crowdsec | 256 MB | PASS | |
| chronicle-fail2ban | 128 MB | PASS | |
| chronicle-grafana | 256 MB | PASS | |
| chronicle-vault | 256 MB | PASS | |
| chronicle-prometheus | 512 MB | PASS | |
| chronicle-loki | 512 MB | PASS | |
| chronicle-alertmanager | 128 MB | PASS | |

**Summary:** 13/13 PASS. All containers have memory limits set.

---

## 5. Network Isolation & Port Bindings

| Container | Published Ports | Networks | Status | Recommendation |
|-----------|----------------|----------|--------|----------------|
| chronicle-frontend | none | chronicle-internal, traefik-apps | PASS | |
| chronicle-backend | none | chronicle-internal, traefik-apps | PASS | |
| chronicle-postgres | none | chronicle-internal | PASS | No external exposure |
| chronicle-falco | none | chronicle-internal | PASS | |
| chronicle-promtail | none | chronicle-internal | PASS | |
| chronicle-traefik | 80, 443 (TCP+UDP) | traefik-apps | PASS | Expected for reverse proxy |
| chronicle-crowdsec | none | chronicle-internal, traefik-apps | PASS | |
| chronicle-fail2ban | none | host | WARN | Host network required for iptables; acceptable but increases attack surface |
| chronicle-grafana | none | chronicle-internal, traefik-apps | PASS | |
| chronicle-vault | none | chronicle-internal | PASS | |
| chronicle-prometheus | none | chronicle-internal | PASS | |
| chronicle-loki | none | chronicle-internal | PASS | |
| chronicle-alertmanager | none | chronicle-internal | PASS | |

**Summary:** 12/13 PASS, 1/13 WARN. Only Traefik exposes ports (expected). Postgres, Vault, and monitoring are properly isolated on internal-only networks. Fail2ban uses host networking (required for iptables).

---

## 6. Additional Security Controls

| Container | no-new-privileges | pids_limit | privileged | Status | Recommendation |
|-----------|-------------------|------------|------------|--------|----------------|
| chronicle-frontend | true | 512 | false | PASS | |
| chronicle-backend | true | 512 | false | PASS | |
| chronicle-postgres | true | 512 | false | PASS | |
| chronicle-falco | false (label=disable) | unlimited | **true** | WARN | Privileged mode required for syscall tracing; ensure Falco image is pinned and trusted |
| chronicle-promtail | true | unlimited | false | WARN | Set `pids_limit` |
| chronicle-traefik | true | unlimited | false | WARN | Set `pids_limit` |
| chronicle-crowdsec | false | unlimited | false | FAIL | Add `security_opt: [no-new-privileges:true]` and `pids_limit` |
| chronicle-fail2ban | false | unlimited | false | FAIL | Add `security_opt: [no-new-privileges:true]` and `pids_limit` |
| chronicle-grafana | true | unlimited | false | WARN | Set `pids_limit` |
| chronicle-vault | false | unlimited | false | FAIL | Add `security_opt: [no-new-privileges:true]` and `pids_limit` |
| chronicle-prometheus | true | unlimited | false | WARN | Set `pids_limit` |
| chronicle-loki | true | unlimited | false | WARN | Set `pids_limit` |
| chronicle-alertmanager | true | unlimited | false | WARN | Set `pids_limit` |

**Summary:** 3/13 PASS, 7/13 WARN, 3/13 FAIL. Core app containers have pids_limit. CrowdSec, Fail2ban, and Vault are missing `no-new-privileges`.

---

## 7. Dockerfile Lint Results

### Dockerfile.backend

**Hadolint:**
| Rule | Severity | Finding |
|------|----------|---------|
| DL3008 | warning | `apt-get install` packages not version-pinned (builder stage) |
| DL3018 | warning | `apk add` packages not version-pinned (runtime stage) |

**Checkov:**
| Check | Status | Finding |
|-------|--------|---------|
| CKV_DOCKER_2 | FAIL | No `HEALTHCHECK` instruction (mitigated: healthcheck defined in docker-compose) |
| CKV_DOCKER_3 | FAIL | No `USER` instruction (mitigated: `su-exec chronicle` in CMD, runtime confirms non-root) |
| All other checks (223) | PASS | |

**Recommendation:** Add `HEALTHCHECK` and `USER chronicle` directives to the Dockerfile for defense-in-depth, even though compose overrides them.

### Dockerfile.frontend.prod

**Hadolint:**
| Rule | Severity | Finding |
|------|----------|---------|
| DL3018 | warning | `apk add` packages not version-pinned |
| DL4006 | warning | Missing `SHELL ["/bin/ash", "-eo", "pipefail"]` before piped RUN |
| SC2162 | info | `read` without `-r` flag |

**Recommendation:** Add `SHELL` instruction before the brotli compression RUN step. Pin `brotli` and `nginx` package versions.

---

## 8. Traefik Security Configuration

### TLS Configuration
| Control | Status | Evidence |
|---------|--------|----------|
| HTTPS entrypoint | PASS | Port 443 with HTTP/3 (QUIC) enabled |
| HTTP-to-HTTPS redirect | PASS | `redirect-to-https` middleware defined in dynamic config |
| TLS minimum version | WARN | No explicit `minVersion` set; Traefik defaults to TLS 1.2 (acceptable, but explicit is better) |

### Security Headers
| Control | Status | Evidence |
|---------|--------|----------|
| X-Content-Type-Options | PASS | `contentTypeNosniff=true` on all routers |
| X-XSS-Protection | PASS | `browserXssFilter=true` on all routers |
| X-Frame-Options | PASS | `frameDeny=true` on web routers |
| Strict-Transport-Security | PASS | 1-year HSTS with includeSubdomains and preload on web routers |
| Content-Security-Policy | PASS | `default-src 'none'; frame-ancestors 'none'` on web API |
| Referrer-Policy | PASS | `strict-origin-when-cross-origin` on web routers |

### Rate Limiting
| Router | Average | Burst | Status |
|--------|---------|-------|--------|
| Mobile API | 5/s | 10 | PASS |
| Web API | 20/s | 30 | PASS |
| External Mobile | 3/s | 8 | PASS |
| External Web | 15/s | 25 | PASS |
| Frontend static | 50/s | 100 | PASS |

### Request Body Limits
| Control | Status | Evidence |
|---------|--------|----------|
| Body size limit | PASS | 10 MB max on API endpoints (`chronicle-body-limit`) |

### WAF / IP Reputation
| Control | Status | Evidence |
|---------|--------|----------|
| CrowdSec bouncer | PASS | Active on mobile and web API routers via `crowdsec-waf@file` |
| CrowdSec AppSec | PASS | `CrowdsecAppsecEnabled: true` with failure-block mode |

### Traefik Dashboard
| Control | Status | Evidence |
|---------|--------|----------|
| API insecure mode | FAIL | `api.insecure: true` exposes dashboard on port 8080 without auth |

**Recommendation:** Disable `api.insecure` or restrict the Traefik dashboard behind authentication and IP allowlisting. Currently the dashboard is not published externally (no port binding for 8080), but it is accessible from within the Docker network.

---

## 9. Docker Socket Protection

| Control | Status | Evidence |
|---------|--------|----------|
| Socket mount mode | PASS | `/var/run/docker.sock` mounted as `:ro` (read-only) |
| Static config mount | PASS | `traefik.yml` mounted as `:ro` |
| Dynamic config mount | PASS | `dynamic/` mounted as `:ro` |

---

## 10. Secrets Management

| Control | Status | Evidence |
|---------|--------|----------|
| Env var secrets | PASS | All secrets (`POSTGRES_PASSWORD`, `JWT_SECRET`, `SMTP_PASSWORD`, etc.) sourced from `.env` file, not hardcoded in compose |
| .env file protection | PASS | `.env` listed in `docker/.gitignore` |
| CrowdSec LAPI key | FAIL | API key hardcoded in `docker/traefik/dynamic/crowdsec-waf.yml`: `uwjDlud4AYG4x5IMVV89zCxyNdIhecx/qUwEJmKhMK8` |

**Recommendation:** Move the CrowdSec LAPI key to `.env` and reference it via environment variable substitution, or use Docker secrets.

---

## Summary Scorecard

| Control Area | PASS | WARN | FAIL | Priority |
|-------------|------|------|------|----------|
| Non-root users | 7 | 6 | 0 | Low (root confined to infra tooling) |
| Capability dropping | 6 | 1 | 6 | **High** |
| Read-only rootfs | 1 | 2 | 10 | **High** |
| Memory limits | 13 | 0 | 0 | -- |
| Network isolation | 12 | 1 | 0 | Low |
| Security options (no-new-priv, pids) | 3 | 7 | 3 | Medium |
| Dockerfile lint | -- | 2 | 2 | Low (mitigated at compose level) |
| Traefik security | 11 | 1 | 1 | Medium |
| Docker socket | 3 | 0 | 0 | -- |
| Secrets management | 2 | 0 | 1 | Medium |

## Top Recommendations (Priority Order)

1. **Add `cap_drop: [ALL]` to backend, postgres, traefik, crowdsec, fail2ban, and vault** in `docker-compose.traefik.yml`. Add back only required capabilities (e.g., `NET_BIND_SERVICE` for Traefik, `NET_ADMIN`+`NET_RAW` already present for Fail2ban, `IPC_LOCK` already present for Vault).

2. **Enable `read_only: true`** on backend, promtail, traefik, crowdsec, fail2ban, grafana, vault, prometheus, loki, and alertmanager. Add `tmpfs` mounts for `/tmp` and service-specific writable paths.

3. **Rotate the CrowdSec LAPI key** in `docker/traefik/dynamic/crowdsec-waf.yml` and move it to `.env` or Docker secrets.

4. **Disable `api.insecure: true`** in Traefik static config or add authentication middleware to the dashboard.

5. **Add `security_opt: [no-new-privileges:true]`** to crowdsec, fail2ban, and vault services.

6. **Set `pids_limit`** on all containers currently without it (promtail, traefik, crowdsec, fail2ban, grafana, vault, prometheus, loki, alertmanager).

7. **Add `USER chronicle` and `HEALTHCHECK`** directives to `Dockerfile.backend` for static analysis compliance.

8. **Pin package versions** in both Dockerfiles (`apk add package=version`).
