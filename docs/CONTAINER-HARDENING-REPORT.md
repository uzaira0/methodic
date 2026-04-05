# Container / Docker Security Audit Report

**Project:** Chronicle  
**Date:** 2026-04-05  
**Auditor:** Automated (Checkov 3.2.508, Hadolint 2.14.0, manual review)

---

## Executive Summary

The Chronicle container stack demonstrates **strong security posture** in its production Traefik deployment (`docker-compose.traefik.yml`), which applies comprehensive hardening: `no-new-privileges`, `cap_drop: ALL` with minimal re-grants, `read_only` root filesystems, resource limits, health checks, and Docker secrets. The dev/staging compose files (`docker-compose.yml`, `docker-compose.dev.yml`, `docker-compose.prod.yml`) are weaker, as expected, but some gaps would be risky if accidentally used in production.

**Findings by severity:**

| Severity | Count |
|----------|-------|
| CRITICAL | 1 |
| HIGH     | 5 |
| MEDIUM   | 8 |
| LOW      | 6 |
| INFO     | 4 |

---

## 1. Checkov Findings (Dockerfiles)

### FAILED Checks

| Check | File | Severity | Description |
|-------|------|----------|-------------|
| CKV_DOCKER_2 | `Dockerfile.backend` | MEDIUM | No HEALTHCHECK instruction |
| CKV_DOCKER_3 | `Dockerfile.backend` | MEDIUM | No USER instruction (uses `su-exec` at runtime instead) |
| CKV_DOCKER_2 | `Dockerfile.frontend` | MEDIUM | No HEALTHCHECK instruction |
| CKV_DOCKER_3 | `Dockerfile.frontend` | MEDIUM | No USER instruction |
| CKV_DOCKER_2 | `Dockerfile.frontend.dev` | LOW | No HEALTHCHECK (dev only) |
| CKV_DOCKER_3 | `Dockerfile.frontend.dev` | LOW | No USER instruction (dev only) |

**Mitigating factors:**
- `Dockerfile.backend` uses `su-exec chronicle` in CMD to drop privileges at runtime; the compose files also define health checks. The Dockerfile-level USER directive would be cleaner.
- `Dockerfile.frontend.prod` passes both checks (has `USER nginx` and `HEALTHCHECK`).
- `Dockerfile.frontend` is only used by the base compose, not production.

### Recommendations

1. **Dockerfile.backend** -- Add `USER chronicle` after the `RUN adduser` block and remove `su-exec` from CMD. The `envsubst` + `chown` operations in the compose command can use an entrypoint script with `gosu`/`su-exec` only when needed.
2. **Dockerfile.frontend** -- Add `USER nobody` and a basic `HEALTHCHECK` even though this is a build-output container.

---

## 2. Hadolint Findings

| Rule | File | Severity | Description |
|------|------|----------|-------------|
| DL3008 | `Dockerfile.backend:7` | WARNING | apt-get packages not version-pinned (`curl`, `unzip`, `dos2unix`, `git`) |
| DL3018 | `Dockerfile.backend:86` | WARNING | apk packages not version-pinned (`gettext`, `su-exec`) |
| DL3018 | `Dockerfile.frontend.prod:30` | WARNING | apk packages not version-pinned (`brotli`) |
| DL3018 | `Dockerfile.frontend.prod:43` | WARNING | apk packages not version-pinned (`nginx`, `nginx-mod-http-brotli`) |
| DL4006 | `Dockerfile.frontend.prod:30` | WARNING | Missing `SHELL ["/bin/sh", "-o", "pipefail", "-c"]` before piped RUN |
| SC2162 | `Dockerfile.frontend.prod:30` | INFO | `read` without `-r` will mangle backslashes |
| DL3018 | `Dockerfile.frontend.dev:10` | WARNING | apk packages not version-pinned (`python3`, `make`, `g++`) |

### Recommendations

1. Pin package versions in builder stages for reproducible builds (e.g., `curl=7.88.1-10+deb12u8`).
2. Add `SHELL ["/bin/sh", "-o", "pipefail", "-c"]` before piped RUN commands in `Dockerfile.frontend.prod`.

---

## 3. Docker Compose Manual Security Review

### 3.1 docker-compose.traefik.yml (Production) -- WELL HARDENED

| Control | Status | Notes |
|---------|--------|-------|
| `no-new-privileges` | PASS | All services |
| `cap_drop: ALL` | PASS | All services |
| Minimal `cap_add` | PASS | Only NET_BIND_SERVICE (traefik), SETUID/SETGID/CHOWN/DAC_OVERRIDE/FOWNER (postgres, backend) |
| `read_only` root FS | PASS | Frontend, Prometheus, Alertmanager, Loki, Promtail, Grafana |
| Resource limits (memory) | PASS | All services have memory limits |
| PID limits | PASS | All services have PID limits |
| Health checks | PASS | All services |
| Docker secrets | PASS | Passwords use Docker secrets mechanism |
| Internal network isolation | PASS | `chronicle-internal` is `internal: true` |
| No privileged mode | PASS | |
| No host network mode | PASS | |
| Image version pinning | PASS | All images use specific version tags |
| tmpfs for writable paths | PASS | `noexec,nosuid` on all tmpfs mounts |
| Docker socket protection | PASS | Uses `tecnativa/docker-socket-proxy` instead of direct mount |

**Remaining gaps in traefik compose:**

| Finding | Severity | Detail |
|---------|----------|--------|
| C-1: Backend not `read_only` | MEDIUM | `chronicle-backend` does not have `read_only: true` because it needs to write rendered config files and audit logs. Mitigated by tmpfs for `/tmp` and volume mounts, but an attacker with RCE could write to arbitrary paths in the container. |
| C-2: Postgres not `read_only` | LOW | PostgreSQL needs writable data directory; this is inherent. |
| C-3: Promtail mounts Docker socket | HIGH | `/var/run/docker.sock:/var/run/docker.sock:ro` gives Promtail read access to the Docker API. A compromised Promtail could enumerate all containers, read env vars, and inspect networks. |
| C-4: Promtail mounts host container logs | MEDIUM | `/var/lib/docker/containers` is mounted read-only but exposes all container logs on the host, not just Chronicle's. |
| C-5: Shared Traefik network | MEDIUM | All services on `traefik-apps` can reach each other directly, bypassing WAF/rate-limiting. Already documented in the compose file comments. |

### 3.2 docker-compose.prod.yml -- MODERATE HARDENING

| Finding | Severity | Detail |
|---------|----------|--------|
| P-1: No `security_opt`, `cap_drop` | HIGH | No containers have `no-new-privileges`, `cap_drop`, or capability restrictions. |
| P-2: No resource limits | HIGH | No memory or PID limits on any service. |
| P-3: Backend missing health check | MEDIUM | Backend `expose: 40320` but no health check defined (unlike base compose). |
| P-4: Nginx runs as root | MEDIUM | `nginx:alpine` runs as root by default; no `user:` directive. |
| P-5: No `read_only` on any container | MEDIUM | |
| P-6: Postgres runs as `user: "999:999"` | PASS | Good -- non-root. |

**Recommendation:** If `docker-compose.prod.yml` is still a deployment target, port the security controls from `docker-compose.traefik.yml`. Otherwise, mark it as deprecated.

### 3.3 docker-compose.yml / docker-compose.dev.yml -- DEV ONLY

| Finding | Severity | Detail |
|---------|----------|--------|
| D-1: Hardcoded credentials | LOW | `POSTGRES_USER: oltest`, `POSTGRES_PASSWORD: test` -- acceptable for local dev only. |
| D-2: No security controls | LOW | No cap_drop, no resource limits, no read_only. Expected for dev. |
| D-3: Backend port exposed in dev | LOW | `docker-compose.dev.yml` exposes `40320:40320` to host (dev convenience). |
| D-4: Frontend port exposed in dev | LOW | Port `9000:9000` exposed. |

### 3.4 docker-compose.kafka.yml

| Finding | Severity | Detail |
|---------|----------|--------|
| K-1: Kafka port exposed to host | HIGH | `ports: - "9092:9092"` exposes Kafka broker on all interfaces. Should be `127.0.0.1:9092:9092` or removed entirely. |
| K-2: Kafka UI uses `:latest` tag | MEDIUM | `provectuslabs/kafka-ui:latest` -- not version-pinned. |
| K-3: Kafka UI exposed on port 8080 | MEDIUM | Management UI accessible without authentication from any host. |
| K-4: No security controls | MEDIUM | No cap_drop, resource limits, or read_only on any service. |
| K-5: PLAINTEXT listeners | MEDIUM | Kafka uses PLAINTEXT protocol for inter-broker and client comms. Should use SASL_SSL in production. |

### 3.5 docker-compose.opensearch.yml

| Finding | Severity | Detail |
|---------|----------|--------|
| O-1: Default password in compose | HIGH | `OPENSEARCH_INITIAL_ADMIN_PASSWORD=${OPENSEARCH_PASSWORD:-Chronicle123!}` -- weak default password that will be used if env var is unset. |
| O-2: Port 9200 exposed to all interfaces | HIGH | OpenSearch REST API accessible from any host. Should be `127.0.0.1:9200:9200`. |
| O-3: Dashboards port 5601 exposed | MEDIUM | Same issue. |
| O-4: No security controls | MEDIUM | No cap_drop, resource limits, or read_only. |

### 3.6 docker-compose.loki.yml

| Finding | Severity | Detail |
|---------|----------|--------|
| L-1: Grafana default credentials | MEDIUM | Default admin/admin if `GRAFANA_ADMIN_PASSWORD` is not set (uses `:?` so it will fail, which is good). |
| L-2: No security controls on Loki/Promtail | MEDIUM | No cap_drop, resource limits. |
| L-3: Ports bound to localhost | PASS | Both `3100` and `3000` are `127.0.0.1` bound. |

---

## 4. Hardcoded Secrets

| Finding | Severity | File | Detail |
|---------|----------|------|--------|
| S-1: CrowdSec LAPI key hardcoded | CRITICAL | `traefik/dynamic/crowdsec-waf.yml` | `CrowdsecLapiKey` and `CrowdsecAppsecKey` are hardcoded in the WAF config file committed to the repository. This key grants control over the CrowdSec WAF decisions (ban/unban IPs). |

**Note:** The `docker-compose.traefik.yml` correctly uses a template-based approach (`crowdsec-waf.yml.template` + `sed` at startup) with `CROWDSEC_BOUNCER_API_KEY` from the environment, and even has a fail-open guard (`if [ -z ... ]; exit 1`). However, `crowdsec-waf.yml` itself contains the actual key and is tracked in git. This file should be in `.gitignore` or removed.

**Recommendation:** Add `docker/traefik/dynamic/crowdsec-waf.yml` to `.gitignore` immediately and rotate the CrowdSec bouncer API key.

---

## 5. Traefik Security Review

### 5.1 TLS Configuration -- STRONG

| Control | Status | Detail |
|---------|--------|--------|
| TLS minimum version | PASS | `minVersion: VersionTLS12` in both `traefik/traefik.yml` and `traefik-tls.yml` |
| Cipher suites | PASS | AEAD-only ciphers (GCM + ChaCha20), no CBC. TLS 1.3 ciphers always enabled by Go. |
| SNI strict mode | PASS | `sniStrict: true` prevents serving certs for unknown domains |
| HTTP-to-HTTPS redirect | PASS | Global redirect in entryPoints config |
| HTTP/3 (QUIC) | PASS | Enabled on port 443/udp |

### 5.2 HSTS -- STRONG

| Control | Status | Detail |
|---------|--------|--------|
| HSTS enabled | PASS | `stsSeconds=31536000` (1 year) on all routers |
| includeSubDomains | PASS | Enabled |
| preload | PASS | Enabled |

### 5.3 Rate Limiting -- GOOD

| Route | Rate | Burst |
|-------|------|-------|
| Mobile API (internal domain) | 5 req/s | 10 |
| Mobile API (external domain) | 3 req/s | 8 |
| Web API (internal domain) | 20 req/s | 30 |
| Web API (external domain) | 15 req/s | 25 |
| Frontend | 50 req/s | 100 |
| Request body limit | 10 MB | -- |

### 5.4 Dashboard / API -- SECURE

| Control | Status | Detail |
|---------|--------|--------|
| Dashboard disabled | PASS | `api.dashboard: false` in `traefik/traefik.yml` |
| API insecure disabled | PASS | `api.insecure: false` in `traefik.yml` (Dokploy variant) |
| Docker socket proxy | PASS | Uses `tecnativa/docker-socket-proxy` with read-only access, `POST: 0` |

### 5.5 Security Headers -- COMPREHENSIVE

All web-facing routes include:
- `X-Frame-Options: DENY`
- `X-Content-Type-Options: nosniff`
- `X-XSS-Protection: 1; mode=block`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Content-Security-Policy` with restrictive directives, hash-based script allowlisting
- `Cross-Origin-Opener-Policy: same-origin` (in nginx.prod.conf)
- `Permissions-Policy` (in nginx.prod.conf)

### 5.6 WAF (CrowdSec) -- GOOD WITH CAVEAT

- CrowdSec bouncer plugin is applied as the first middleware on all external routes.
- AppSec (layer-7 WAF) is enabled.
- **Good:** `CrowdsecAppsecFailureBlock: true` -- blocks requests when AppSec is unavailable.
- **Concern:** `CrowdsecAppsecUnreachableBlock: false` -- allows traffic through when the CrowdSec LAPI is unreachable. This is a fail-open configuration. Consider setting to `true` for defense-in-depth, accepting the availability tradeoff.

### 5.7 Grafana Access Control -- GOOD

- IP-restricted to private networks only via `ipallowlist.sourcerange=127.0.0.1/32,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16`
- External domain blocks `/grafana` and `/prometheus/` paths explicitly.

---

## 6. Nginx Security Review (nginx.prod.conf)

| Control | Status | Detail |
|---------|--------|--------|
| TLS 1.2+ only | PASS | `ssl_protocols TLSv1.2 TLSv1.3` |
| Strong cipher suites | PASS | AEAD only, ECDHE + DHE |
| Session tickets disabled | PASS | `ssl_session_tickets off` |
| Server tokens hidden | PASS | `server_tokens off` |
| HSTS | PASS | 1 year, includeSubDomains, preload |
| CSP | PASS | Restrictive, with report-uri |
| Rate limiting | PASS | Per-zone limits for mobile, web, general |
| Connection limits | PASS | `limit_conn conn_limit 20` |
| Hidden files blocked | PASS | `location ~ /\.` |
| Internal routes blocked | PASS | `/chronicle/`, `/datastore/`, `/principal/`, `/compliance/`, `/import/` return 404 |
| CORS origin validation | PASS | Map-based, only configured domains |

**Gap:** `client_max_body_size 50M` in nginx vs 10MB in Traefik -- inconsistency. If nginx is in the path, an attacker could send a 50MB payload to the backend.

---

## 7. Prioritized Recommendations

### CRITICAL

| # | Finding | Action |
|---|---------|--------|
| 1 | S-1: CrowdSec API key in git | Rotate the key immediately. Add `docker/traefik/dynamic/crowdsec-waf.yml` to `.gitignore`. The template-based approach in the compose file is correct -- just ensure the generated file is never committed. |

### HIGH

| # | Finding | Action |
|---|---------|--------|
| 2 | C-3: Promtail Docker socket mount | Replace with Docker socket proxy (like Traefik uses) or use a dedicated logging driver. The socket gives full read access to the Docker API. |
| 3 | K-1: Kafka port exposed on all interfaces | Bind to `127.0.0.1:9092:9092` or remove the port binding entirely (internal network suffices). |
| 4 | O-1/O-2: OpenSearch weak default + exposed port | Remove default password, bind port to `127.0.0.1`. |
| 5 | P-1: prod.yml lacks all security controls | Port `security_opt`, `cap_drop`, resource limits from `docker-compose.traefik.yml`, or deprecate this file. |

### MEDIUM

| # | Finding | Action |
|---|---------|--------|
| 6 | C-1: Backend not read_only | Use an entrypoint script to render configs into a tmpfs, then set `read_only: true`. |
| 7 | C-4: Promtail reads all container logs | Mount only Chronicle container logs via named volume, not `/var/lib/docker/containers`. |
| 8 | C-5: Shared Traefik network | Create per-project Traefik networks (already noted in compose comments). |
| 9 | K-2: Kafka UI `:latest` tag | Pin to a specific version. |
| 10 | Body size inconsistency | Align nginx `client_max_body_size` with Traefik's 10MB limit. |
| 11 | CrowdSec unreachable fail-open | Set `CrowdsecAppsecUnreachableBlock: true` in the template. |
| 12 | CSP `unsafe-inline` for styles | Replace with hash-based or nonce-based style-src if feasible. |

### LOW

| # | Finding | Action |
|---|---------|--------|
| 13 | Hadolint: Pin package versions | Pin apt/apk package versions in all Dockerfiles for reproducible builds. |
| 14 | Hadolint: Add `pipefail` shell option | Add `SHELL ["/bin/sh", "-o", "pipefail", "-c"]` in `Dockerfile.frontend.prod`. |
| 15 | Checkov: Add HEALTHCHECK to backend Dockerfile | Even though compose defines it, Dockerfile-level HEALTHCHECK is defense-in-depth. |
| 16 | Checkov: Add USER to backend Dockerfile | Replace `su-exec` pattern with proper USER directive + entrypoint. |

---

## 8. Positive Findings

The production Traefik deployment (`docker-compose.traefik.yml`) demonstrates security practices that exceed what is typically seen in self-hosted research deployments:

1. **Docker Socket Proxy** -- Traefik uses `tecnativa/docker-socket-proxy` instead of mounting the Docker socket directly. Read-only access with `POST: 0` prevents container manipulation.
2. **Comprehensive capability dropping** -- Every service drops ALL capabilities and re-adds only what is needed.
3. **Read-only root filesystems** -- Frontend, Prometheus, Alertmanager, Loki, Promtail, and Grafana all use `read_only: true` with minimal tmpfs mounts.
4. **PID limits** -- All services have PID limits, preventing fork bombs.
5. **Internal network isolation** -- `chronicle-internal` is a bridge network with `internal: true`, preventing outbound internet access.
6. **Docker secrets** -- Passwords use the Docker secrets mechanism rather than plain environment variables.
7. **TLS hardening** -- TLS 1.2+ with AEAD-only ciphers, SNI strict mode, HSTS with preload.
8. **CrowdSec WAF** -- Layer-7 application firewall with IP reputation, applied as first middleware on all routes.
9. **IP-restricted monitoring** -- Grafana and Prometheus are not publicly accessible.
10. **Fail-closed guards** -- The Traefik entrypoint exits fatally if `CROWDSEC_BOUNCER_API_KEY` is empty, preventing a fail-open WAF deployment.

---

*Generated by automated container security audit. Manual verification of recommendations is advised before applying changes.*
