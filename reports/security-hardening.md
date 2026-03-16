# Chronicle Security Hardening Report

**Date:** 2026-03-16
**Scope:** Full deployment at `/opt/chronicle`
**Reviewer:** Automated security audit (Claude)

---

## Executive Summary

The Chronicle deployment demonstrates a mature security posture with defense-in-depth architecture. TDE encryption, RLS, CrowdSec WAF, Falco runtime monitoring, JWT blocklist/revocation, error sanitization, SQL injection prevention, and HIPAA-compliant audit logging are all present. This report identifies remaining gaps and hardening opportunities.

**Findings by Severity:**
- CRITICAL: 3
- HIGH: 7
- MEDIUM: 10
- LOW: 6

---

## 1. Authentication Architecture

### F-1.1: Traefik API Dashboard Exposed Without Authentication
| Field | Value |
|---|---|
| **Severity** | CRITICAL |
| **File** | `/opt/chronicle/docker/traefik/traefik.yml` |
| **Current State** | `api: insecure: true` exposes the Traefik dashboard on port 8080 (inside Docker network). While not mapped to host ports directly, any container on the `traefik` network can access full Traefik configuration, including all routing rules and middleware secrets. |
| **Recommendation** | Set `api: insecure: false` and either disable the dashboard entirely (`api: dashboard: false`) or add BasicAuth middleware with IP restriction. At minimum, add `api: dashboard: false` in production. |
| **Effort** | Low (1 line change) |

### F-1.2: CrowdSec Bouncer API Key Hardcoded in File Provider
| Field | Value |
|---|---|
| **Severity** | CRITICAL |
| **File** | `/opt/chronicle/docker/traefik/dynamic/crowdsec-waf.yml` |
| **Current State** | `CrowdsecLapiKey: "uwjDlud4AYG4x5IMVV89zCxyNdIhecx/qUwEJmKhMK8"` is committed to source control. This key allows any holder to query CrowdSec decisions and potentially manipulate the bouncer. |
| **Recommendation** | Move the key to `.env` and reference it via Traefik's environment variable interpolation or use a file provider template rendered by envsubst. Rotate the key immediately since it is in version history. |
| **Effort** | Low (template + envsubst) |

### F-1.3: JWT Uses HS256 Symmetric Signing
| Field | Value |
|---|---|
| **Severity** | MEDIUM |
| **File** | `ChronicleServerSecurityPod.kt` line 213-214 |
| **Current State** | JWT signing enforces HS256 only. The same secret is shared between the token generator (`generate-jwt.sh`) and the verifier (backend). If the secret leaks, any party can forge tokens. |
| **Recommendation** | For a single-server deployment, HS256 is acceptable provided the secret is strong (64+ bytes from `openssl rand -base64 64`). Document minimum secret length requirement. Consider migrating to RS256/ES256 asymmetric signing for future multi-service deployments. |
| **Effort** | Medium (RS256 migration) / Low (document secret requirements) |

### F-1.4: Testing Login Endpoint Available in Production
| Field | Value |
|---|---|
| **Severity** | HIGH |
| **File** | `AuthTokenController.kt` lines 98-137 |
| **Current State** | The `/chronicle/v3/auth/testing-login` endpoint is `permitAll()`. It relies on `userListingService.issueTestingToken()` returning null to disable. If the testing token configuration is accidentally enabled, it bypasses all authentication. |
| **Recommendation** | Add an explicit environment variable check (e.g., `TESTING_LOGIN_ENABLED=false`) and refuse to register the endpoint at all in production. Alternatively, move it behind admin authentication. |
| **Effort** | Low |

### F-1.5: CSRF Token Accepted via Query Parameter
| Field | Value |
|---|---|
| **Severity** | MEDIUM |
| **File** | `ChronicleCookieOrBearerTokenResolver.kt` line 79-80 |
| **Current State** | CSRF validation accepts the token from `csrfToken` query parameter in addition to the `X-CSRF-Token` header. Query parameters appear in access logs, browser history, and referer headers. |
| **Recommendation** | Remove the query parameter fallback and require the `X-CSRF-Token` header exclusively. Update the frontend to always send the header. |
| **Effort** | Low |

### F-1.6: JWT Blocklist Fails Open on Hazelcast Failure
| Field | Value |
|---|---|
| **Severity** | MEDIUM |
| **File** | `JwtBlocklistFilter.kt` line 56-59 |
| **Current State** | If Hazelcast is unreachable, the blocklist check is skipped and the request proceeds. An attacker who can cause Hazelcast instability could use revoked tokens. |
| **Recommendation** | This is a defensible design choice (availability over consistency). Document the fail-open behavior explicitly. Consider adding a metric counter for blocklist check failures and alert on it. Add a circuit breaker that fails closed after sustained Hazelcast outage (>5 min). |
| **Effort** | Medium |

---

## 2. Network Security

### F-2.1: Docker Socket Mounted Read-Only into Traefik
| Field | Value |
|---|---|
| **Severity** | HIGH |
| **File** | `docker-compose.traefik.yml` line 35 |
| **Current State** | `/var/run/docker.sock:/var/run/docker.sock:ro` gives Traefik read access to the Docker daemon. A Traefik vulnerability could allow container enumeration, image inspection, and environment variable disclosure (including secrets). |
| **Recommendation** | Deploy a Docker socket proxy like `tecnativa/docker-socket-proxy` that limits Docker API access to only the endpoints Traefik needs (containers, networks). |
| **Effort** | Medium |

### F-2.2: Postgres Not Port-Restricted to Backend Only
| Field | Value |
|---|---|
| **Severity** | LOW |
| **File** | `docker-compose.traefik.yml` |
| **Current State** | Postgres is on `chronicle-internal` network but accessible to all containers on that network (Prometheus, Loki, Promtail, Alertmanager, Grafana). These monitoring containers do not need database access. |
| **Recommendation** | Create a dedicated `chronicle-db` network containing only `postgres` and `chronicle-backend`. Keep monitoring services on a separate `chronicle-monitoring` network. |
| **Effort** | Medium |

### F-2.3: Prometheus Metrics Endpoint Unauthenticated
| Field | Value |
|---|---|
| **Severity** | MEDIUM |
| **File** | `ChronicleServerSecurityPod.kt` line 172 |
| **Current State** | `/prometheus/**` is `permitAll()`. The comment acknowledges this should be restricted. Metrics expose pool sizes, connection counts, and internal service names. |
| **Recommendation** | Add a Traefik middleware that restricts `/prometheus/` to the Prometheus container's IP. Or add BasicAuth for the metrics scraper. Since Prometheus scrapes internally, this is reachable only from the Docker network but still violates least privilege. |
| **Effort** | Low |

### F-2.4: Vault Listener Has TLS Disabled
| Field | Value |
|---|---|
| **Severity** | LOW |
| **File** | `docker/security/vault/vault-config.hcl` line 12 |
| **Current State** | `tls_disable = 1` on the Vault listener. Communication between backend and Vault is unencrypted within the Docker network. |
| **Recommendation** | Acceptable for an isolated Docker network but should be documented. For enhanced security, enable TLS between backend and Vault using self-signed certificates. |
| **Effort** | Medium |

### F-2.5: Falco Runs as Privileged Container
| Field | Value |
|---|---|
| **Severity** | LOW |
| **File** | `docker-compose.security.yml` line 137 |
| **Current State** | `privileged: true` is required for Falco's kernel module/eBPF access but grants full host access. |
| **Recommendation** | This is inherent to Falco's architecture. Consider switching to Falco's modern eBPF driver which requires only `SYS_ADMIN` and `SYS_RESOURCE` capabilities instead of full privileged mode. |
| **Effort** | Medium |

---

## 3. Data Protection

### F-3.1: Localhost PostgreSQL Connections Allow Non-SSL
| Field | Value |
|---|---|
| **Severity** | LOW |
| **File** | `docker/postgres-ssl/pg_hba-ssl.conf` lines 9-11 |
| **Current State** | `host` (not `hostssl`) for 127.0.0.1 and ::1. Backend connects via hostname `postgres` (Docker DNS) which resolves to a Docker network IP, not localhost, so this is not exploitable in the current topology. |
| **Recommendation** | Change localhost entries to `hostssl` for defense in depth. No functional impact since the backend connects via Docker network. |
| **Effort** | Low |

### F-3.2: Backup Encryption Key Location
| Field | Value |
|---|---|
| **Severity** | MEDIUM |
| **File** | `docker/backup-chronicle.sh` line 30 |
| **Current State** | Encryption key defaults to `/etc/chronicle/backup-encryption-key` with fallback to legacy location. The key permissions and creation are not enforced by the script. |
| **Recommendation** | Add a check in the backup script that verifies the key file has `0600` permissions and is owned by root. Refuse to run if permissions are too open. Add documentation for key rotation. |
| **Effort** | Low |

### F-3.3: TDE Uses File-Based Key Provider
| Field | Value |
|---|---|
| **Severity** | MEDIUM |
| **File** | `docker-compose.traefik.yml` line 69 |
| **Current State** | `PG_TDE_KEY_PROVIDER: ${PG_TDE_KEY_PROVIDER:-file}`. File-based key storage means the encryption key sits on a Docker volume alongside the encrypted data. An attacker with volume access has both. |
| **Recommendation** | Migrate to Vault-based key provider (`PG_TDE_KEY_PROVIDER=vault`) now that Vault infrastructure is deployed. This separates the key from the data. |
| **Effort** | Medium |

---

## 4. Input Validation

### F-4.1: Import Table Name Validation Allows Dots and Hyphens
| Field | Value |
|---|---|
| **Severity** | HIGH |
| **File** | `SqlIdentifierValidator.kt` lines 239-268 |
| **Current State** | `validateImportTableName()` allows dots in table names (regex `^[a-zA-Z0-9_.-]+$`). A dot allows schema-qualified names like `pg_catalog.pg_shadow` which could read password hashes. Hyphens require quoting and could cause SQL syntax errors. |
| **Recommendation** | Remove dots and hyphens from the import table name pattern. If schema-qualified names are needed, validate schema and table separately against allowlists. |
| **Effort** | Low |

### F-4.2: Participant ID Not Validated on Unauthenticated Endpoints
| Field | Value |
|---|---|
| **Severity** | HIGH |
| **File** | Multiple controllers (TUD, Survey, Study) |
| **Current State** | Participant IDs are accepted as free-form strings on `permitAll()` endpoints (TUD submission, survey, enrollment). There is no length limit or format validation. An attacker could submit arbitrary strings as participant IDs, potentially causing storage bloat or log injection. |
| **Recommendation** | Add `@Size(max=64)` and `@Pattern(regexp="^[a-zA-Z0-9_-]+$")` constraints on all `participantId` path variables and request parameters. |
| **Effort** | Low |

### F-4.3: Request Body Size Not Limited at Application Level
| Field | Value |
|---|---|
| **Severity** | MEDIUM |
| **File** | Controllers accepting `@RequestBody List<...>` |
| **Current State** | Traefik limits body size to 10MB (`chronicle-body-limit`), but this is only on the web/mobile routers. The application itself has no `spring.servlet.multipart.max-file-size` or Jackson deserialization limits. A large JSON array could exhaust memory. |
| **Recommendation** | Add `server.max-http-header-size` and `spring.mvc.max-request-size` configuration. Add `@Size(max=10000)` on collection-typed `@RequestBody` parameters. |
| **Effort** | Low |

### F-4.4: Study ID Enumeration on Unauthenticated Endpoints
| Field | Value |
|---|---|
| **Severity** | MEDIUM |
| **File** | `TimeUseDiaryController.kt`, `SurveyController.kt` |
| **Current State** | Unauthenticated endpoints like TUD submission and survey access use `studyService.getStudyId(studyId)` and return `checkNotNull(realStudyId) { "invalid study id" }`. This reveals whether a study UUID exists. |
| **Recommendation** | Return a generic error that does not distinguish between "study not found" and "invalid request" for unauthenticated endpoints. Or accept the risk since UUIDs are unguessable (128-bit entropy). |
| **Effort** | Low |

---

## 5. Secrets Management

### F-5.1: Vault Integration Not Yet Active
| Field | Value |
|---|---|
| **Severity** | HIGH |
| **File** | `docker-compose.traefik.yml` line 217 |
| **Current State** | `VAULT_ENABLED: ${VAULT_ENABLED:-false}`. Vault infrastructure is deployed but disabled by default. All secrets (DB password, JWT secret, SMTP credentials, Hazelcast passwords) are stored in the `.env` file on disk. |
| **Recommendation** | Enable Vault integration: initialize Vault, seed secrets, set `VAULT_ENABLED=true`. Update the backend startup to fetch secrets from Vault instead of environment variables. This removes plaintext secrets from the `.env` file. |
| **Effort** | High |

### F-5.2: JWT Secret Strength Not Enforced
| Field | Value |
|---|---|
| **Severity** | HIGH |
| **File** | `docker/generate-jwt.sh`, `ChronicleServerSecurityPod.kt` |
| **Current State** | No minimum length check on `JWT_SECRET`. A weak secret (e.g., "password") would allow token forgery via brute force. The script suggests `openssl rand -base64 64` but does not enforce it. |
| **Recommendation** | Add a startup check in the backend that rejects `JWT_SECRET` shorter than 32 bytes. Add a similar check in `generate-jwt.sh`. |
| **Effort** | Low |

### F-5.3: Environment Variables Visible in Docker Inspect
| Field | Value |
|---|---|
| **Severity** | MEDIUM |
| **File** | `docker-compose.traefik.yml` (all service `environment:` blocks) |
| **Current State** | Secrets like `POSTGRES_PASSWORD`, `JWT_SECRET`, `HAZELCAST_SERVER_PASSWORD` are passed as environment variables. Anyone with Docker CLI access can `docker inspect chronicle-backend` and see all secrets in plaintext. |
| **Recommendation** | Use Docker secrets (`docker secret create`) or Vault agent injection to deliver secrets via files instead of environment variables. Vault integration (F-5.1) addresses this. |
| **Effort** | High (tied to F-5.1) |

---

## 6. Logging and Monitoring

### F-6.1: Alertmanager Has No Configured Receivers
| Field | Value |
|---|---|
| **Severity** | CRITICAL |
| **File** | `docker/monitoring/alertmanager.yml` line 19 |
| **Current State** | `webhook_configs: []` with a comment "WARNING: No receivers configured -- alerts will be silently discarded." All security and reliability alerts (DB exhaustion, backend down, connection timeouts) are generated but never delivered. |
| **Recommendation** | Configure at least one receiver: email (using existing SMTP), Slack webhook, or PagerDuty. This is critical for HIPAA incident response requirements. |
| **Effort** | Low |

### F-6.2: No HTTP-Level Security Alert Rules
| Field | Value |
|---|---|
| **Severity** | MEDIUM |
| **File** | `docker/monitoring/prometheus-rules.yml` lines 43-47 |
| **Current State** | Alert rules only cover HikariCP metrics. There are no alerts for 401/403 spikes, 429 rate-limiting events, or unusual traffic patterns. The backend uses Dropwizard metrics which lack `http_requests_total`. |
| **Recommendation** | Enable Traefik's Prometheus metrics (`metrics: prometheus: entryPoint: metrics`) to get `traefik_service_requests_total{code="401"}` counters. Add alert rules for auth failure spikes and rate limit triggers. |
| **Effort** | Medium |

### F-6.3: Audit Log Rotation Not Configured at Application Level
| Field | Value |
|---|---|
| **Severity** | LOW |
| **File** | `docker-compose.traefik.yml` line 222 |
| **Current State** | Audit logs are written to `/var/log/chronicle` volume. The HIPAA 6-year retention is documented but there is no visible log rotation configuration (logback/log4j2 rolling policy). Logs could grow unbounded. |
| **Recommendation** | Configure rolling file appender in the backend's logging configuration with time-based rotation (daily) and size caps. Promtail will still ingest rotated files. |
| **Effort** | Low |

---

## 7. Dependency Security

### F-7.1: Java 17 LTS -- Check for Security Updates
| Field | Value |
|---|---|
| **Severity** | MEDIUM |
| **File** | `docker/Dockerfile.backend` (eclipse-temurin:17-jdk) |
| **Current State** | Uses Java 17 LTS (Temurin). Java 17 receives updates until 2029. However, the Dockerfile does not pin a specific patch version, relying on `17-jdk` tag which could pull an outdated image from cache. |
| **Recommendation** | Pin to a specific Temurin release (e.g., `eclipse-temurin:17.0.14_7-jdk`) and update on a regular cadence (monthly). Use `docker pull` or CI rebuild to pick up security patches. |
| **Effort** | Low |

### F-7.2: Redshift JDBC Driver is Outdated
| Field | Value |
|---|---|
| **Severity** | LOW |
| **File** | `chronicle-server/build.gradle` line 204 |
| **Current State** | `com.amazon.redshift:redshift-jdbc42:2.1.0.32`. Check for known CVEs. If Redshift is no longer used (data moved to local Postgres), this dependency adds unnecessary attack surface. |
| **Recommendation** | If Redshift is no longer used, remove the dependency entirely. Otherwise, update to the latest version. |
| **Effort** | Low |

### F-7.3: Twilio SDK Version
| Field | Value |
|---|---|
| **Severity** | LOW |
| **File** | `chronicle-server/build.gradle` line 207 |
| **Current State** | `com.twilio.sdk:twilio:9.6.1`. Twilio SDK has had CVEs in older versions. Verify this is current. |
| **Recommendation** | Update to the latest Twilio SDK version and set up Dependabot/Renovate for automated dependency updates. |
| **Effort** | Low |

### F-7.4: No Automated Dependency Vulnerability Scanning
| Field | Value |
|---|---|
| **Severity** | HIGH |
| **File** | N/A |
| **Current State** | SpotBugs with FindSecBugs is configured for static analysis, and `dependency-license-report` is present, but there is no OWASP Dependency-Check, Snyk, or Trivy integration for CVE scanning. |
| **Recommendation** | Add `org.owasp:dependency-check-gradle` plugin to the build. Run `dependencyCheckAnalyze` in CI. Alternatively, add Trivy scanning for Docker images in CI pipeline. |
| **Effort** | Low |

---

## 8. Container Security

### F-8.1: Backend Container Runs Config Rendering as Root
| Field | Value |
|---|---|
| **Severity** | MEDIUM |
| **File** | `docker-compose.traefik.yml` lines 236-261 |
| **Current State** | The backend's `command` runs `envsubst` and `chown` as root, then drops to `chronicle` user via `su-exec`. The window between container start and `su-exec` runs as root. |
| **Recommendation** | Use a multi-stage init container or Docker's `--init` with an entrypoint script that drops privileges immediately after config rendering. Or pre-render config in a sidecar init container. |
| **Effort** | Medium |

### F-8.2: Frontend Container is Read-Only (Good)
| Field | Value |
|---|---|
| **Severity** | N/A (positive finding) |
| **File** | `docker-compose.traefik.yml` line 438 |
| **Current State** | `read_only: true` with `cap_drop: ALL` and minimal tmpfs mounts. This is excellent hardening. |

### F-8.3: No Resource Limits on Postgres Replica
| Field | Value |
|---|---|
| **Severity** | LOW |
| **File** | `docker-compose.traefik.yml` lines 124-166 |
| **Current State** | `postgres-replica` has 512M memory limit but no PID limit (unlike primary which has `pids: 512`). The replica also lacks `security_opt: no-new-privileges`. Wait -- it does have both. This is fine. |

---

## 9. CORS Configuration

### F-9.1: CORS is Well-Configured (Positive Finding)
| Field | Value |
|---|---|
| **Severity** | N/A (positive finding) |
| **File** | `docker-compose.traefik.yml`, `cors.yaml.template` |
| **Current State** | CORS origins are restricted to `${DOMAIN}` and `${EXT_DOMAIN}`. No wildcard origins. Credentials allowed only on web router. Mobile router blocks browser-based CORS. |

---

## 10. Error Handling

### F-10.1: Error Sanitization is Comprehensive (Positive Finding)
| Field | Value |
|---|---|
| **Severity** | N/A (positive finding) |
| **File** | `ChronicleServerExceptionHandler.kt`, `GlobalExceptionHandler.kt` |
| **Current State** | SQL exceptions always return generic 500. Authentication errors return generic 401/403. Error IDs enable log correlation without leaking details. Log injection prevention is implemented. |

---

## Summary of Positive Security Controls Already in Place

1. **TDE encryption** on 15 tables with pg_tde
2. **PostgreSQL SSL** enforced for all non-local connections (TLSv1.2 minimum)
3. **Row-Level Security (RLS)** with context filter in Spring Security chain
4. **JWT blocklist** with per-token and global revocation
5. **CrowdSec WAF** with AppSec (OWASP rules) and IP reputation
6. **Fail2ban** for brute-force, rate-limit abuse, and scanner detection
7. **Falco** runtime monitoring for shell spawning, privilege escalation, crypto mining
8. **CSRF protection** on cookie-based authentication (double-submit cookie pattern)
9. **SQL injection prevention** via `SqlIdentifierValidator` allowlist-based validation
10. **Error sanitization** preventing information disclosure
11. **Security headers** (CSP, HSTS, X-Frame-Options, X-Content-Type-Options, Permissions-Policy)
12. **Container hardening** (no-new-privileges, cap_drop ALL, read-only filesystem, PID limits, memory limits)
13. **Non-root containers** (chronicle user for backend, nginx user for frontend, postgres UID 26)
14. **Audit logging** with HIPAA-compliant fields (PHI access tracking, error correlation IDs)
15. **pgaudit** for DDL, role, and write statement auditing
16. **Backup encryption** (AES-256-CBC with PBKDF2)
17. **Network segmentation** (internal vs. traefik networks)
18. **API key authentication** with scope enforcement (READ_ONLY, WRITE, ADMIN)
19. **Rate limiting** at Traefik layer (mobile: 5 req/s, web: 20 req/s, frontend: 50 req/s)
20. **Request body size limit** (10MB at Traefik)

---

## Prioritized Remediation Roadmap

### Immediate (This Week)
| # | Finding | Severity | Effort |
|---|---------|----------|--------|
| F-1.1 | Disable Traefik API dashboard | CRITICAL | Low |
| F-1.2 | Move CrowdSec API key to .env | CRITICAL | Low |
| F-6.1 | Configure Alertmanager receiver | CRITICAL | Low |
| F-1.4 | Guard testing-login endpoint | HIGH | Low |
| F-5.2 | Enforce JWT secret minimum length | HIGH | Low |

### Short-Term (This Month)
| # | Finding | Severity | Effort |
|---|---------|----------|--------|
| F-4.1 | Remove dots from import table name regex | HIGH | Low |
| F-4.2 | Add participant ID validation | HIGH | Low |
| F-7.4 | Add OWASP Dependency-Check | HIGH | Low |
| F-1.5 | Remove CSRF query parameter fallback | MEDIUM | Low |
| F-2.3 | Restrict /prometheus/ access | MEDIUM | Low |
| F-3.2 | Enforce backup key file permissions | MEDIUM | Low |

### Medium-Term (This Quarter)
| # | Finding | Severity | Effort |
|---|---------|----------|--------|
| F-2.1 | Deploy Docker socket proxy | HIGH | Medium |
| F-5.1 | Enable Vault integration | HIGH | High |
| F-3.3 | Switch TDE to Vault key provider | MEDIUM | Medium |
| F-6.2 | Add Traefik Prometheus metrics + HTTP alerts | MEDIUM | Medium |
| F-2.2 | Network segmentation for DB | LOW | Medium |
| F-8.1 | Separate config rendering from main container | MEDIUM | Medium |

### Long-Term (Next Quarter)
| # | Finding | Severity | Effort |
|---|---------|----------|--------|
| F-1.3 | Evaluate RS256/ES256 migration | MEDIUM | Medium |
| F-1.6 | Circuit breaker for JWT blocklist | MEDIUM | Medium |
| F-5.3 | Docker secrets or Vault agent for env vars | MEDIUM | High |
| F-2.5 | Falco eBPF driver (drop privileged) | LOW | Medium |

---

*Report generated by automated security review. Findings should be validated by a human security engineer before remediation.*
