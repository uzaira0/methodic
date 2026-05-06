# Supply Chain & Dependency Security Audit

**Project:** Chronicle  
**Date:** 2026-04-05  
**Auditor:** Automated (Claude Code)  
**Scope:** Backend (Gradle/JVM), Frontend (Bun/npm), Docker images, Licenses

---

## Executive Summary

Chronicle's dependency posture is **generally well-maintained** with recent library versions and proactive CVE remediation (forced transitive overrides in `gradles/methodic.gradle`). Key findings:

- **4 HIGH frontend vulnerabilities** (lodash, node-fetch, path-to-regexp, validator)
- **SnakeYAML pinned to 2.2** but Gradle resolves it to 2.5 via transitive override (acceptable)
- **commons-collections 3.2.2** present transitively (deserialization gadget chain risk)
- **Docker images run as root** in both Dockerfiles (Hadolint DL3002)
- **Private key committed** in `docker/postgres-ssl/server/server.key`
- **No critical CVEs** in backend JVM dependencies

---

## 1. Backend Dependencies (Gradle / JVM)

### 1.1 Critical Library Versions

| Library | Declared | Resolved | Status |
|---------|----------|----------|--------|
| Log4j (API + Core + Web) | 2.24.3 | 2.24.3 | SAFE (>=2.17.0 required) |
| Jackson Databind | 2.21.1 | 2.21.1 | SAFE (current) |
| Spring Framework | 6.2.16 | 6.2.16 | SAFE (current patch) |
| Spring Security | 6.5.8 | 6.5.8 | SAFE (current patch) |
| SnakeYAML | 2.2 (declared) | 2.5 (resolved) | SAFE -- CVE-2022-1471 affects <2.0 |
| Netty | 4.1.128.Final | 4.1.128.Final | SAFE (forced in methodic.gradle) |
| Guava | 33.4.8-jre | 33.4.8-jre | SAFE (current) |
| Kotlin | 2.3.10 | 2.3.10 | SAFE (current) |
| Jetty | 12.0.32 | 12.0.32 | SAFE (current) |
| PostgreSQL JDBC | 42.7.10 | 42.7.10 | SAFE (current) |
| protobuf-java | forced 3.25.5 | 3.25.5 | SAFE (CVE remediation force) |
| grpc-netty-shaded | forced 1.71.0 | 1.71.0 | SAFE (CVE remediation force) |

### 1.2 Concerns

| Library | Version | Issue | Severity | Recommendation |
|---------|---------|-------|----------|----------------|
| commons-collections (v3) | 3.2.2 | Transitive via AWS SDK. Deserialization gadget chain (CVE-2015-6420, CVE-2017-15708). Not directly exploitable unless untrusted deserialization is used, but widens attack surface. | MEDIUM | Exclude or force upgrade to commons-collections 3.2.3+ or ensure no Java serialization of untrusted input. |
| commons-collections4 | 4.1 (declared) -> 4.4 (resolved) | Declared at 4.1 in methodic.gradle but resolved to 4.4 via POI transitive. The declaration should be updated to match. | LOW | Update `ext.commons_collections4_version` to `4.4` in methodic.gradle. |
| commons-beanutils | forced 1.11.0 | Already force-overridden (good). | OK | No action needed. |
| Twilio SDK | 9.6.1 (resolved) vs 7.34.1 (declared) | The `ext.twilio_version` in methodic.gradle says `7.34.1` but the resolved tree shows `9.6.1`. Version declaration is stale. | LOW | Update `ext.twilio_version` to `9.6.1` in methodic.gradle. |
| Kryo-shaded | 4.0.0 | Old version; Kryo 5.x is current. Kryo 4 has known deserialization risks if exposed to untrusted data. | LOW | Upgrade to Kryo 5.x if feasible; ensure Kryo is never used to deserialize untrusted input. |
| spring-vault-core | 3.1.2 | Pins Spring to 6.1.12 transitively (resolved up to 6.2.16 via force). Vault integration may have incompatibilities. | LOW | Test with Spring 6.2.x; upgrade spring-vault-core to 3.2.x when available. |
| jjwt (via Twilio) | 0.11.2 | Outdated; current is 0.12.x. No critical CVEs but missing security improvements. | LOW | Upgrade Twilio SDK or exclude and provide jjwt 0.12.x. |
| Apache Commons Compress | 1.25.0 | Via POI 5.2.5. CVE-2024-25710 and CVE-2024-26308 affect <1.26.0 (DoS via crafted archives). | MEDIUM | Upgrade POI to 5.3.0+ or force `commons-compress:1.27.1`. |

### 1.3 OWASP Dependency Check

The `dependencyCheckAnalyze` task failed -- likely needs an NVD API key configured. **Recommendation:** Add `nvd.api.key` to gradle.properties or CI environment to enable automated CVE scanning.

### 1.4 Forced Transitive Overrides (Positive Finding)

The project proactively forces secure versions of transitive dependencies in `gradles/methodic.gradle` (lines 48-61):
- protobuf-java 3.25.5
- commons-beanutils 1.11.0
- grpc-netty-shaded 1.71.0
- All Netty modules pinned to 4.1.128.Final

This is good practice and should be maintained.

### 1.5 Log4j Mitigation (Positive Finding)

The JVM argument `-Dlog4j2.formatMsgNoLookups=true` is set in `chronicle-server/build.gradle:97` as defense-in-depth against Log4Shell, even though 2.24.3 is well past the vulnerable range. This is good practice.

---

## 2. Frontend Dependencies (Bun)

### 2.1 Grype Scan Results (HIGH severity)

| Library | Installed | Fixed | CVE | Description |
|---------|-----------|-------|-----|-------------|
| lodash | 4.17.21 | 4.18.0 | CVE-2026-4800 | Arbitrary code execution via untrusted input in template imports |
| node-fetch | 2.6.1 | 2.6.7 / 3.1.1 | CVE-2022-0235 | Sensitive information exposure to unauthorized actor |
| path-to-regexp | 0.1.12 | 0.1.13 | CVE-2026-4867 | ReDoS via catastrophic backtracking from malformed URL parameters |
| validator | 13.11.0 | 13.15.22 | CVE-2025-12758 | Incomplete filtering bypass |

### 2.2 Recommendations

- **lodash 4.17.21 -> 4.18.0**: Critical upgrade. The template injection CVE is exploitable if user input reaches `_.template()` imports.
- **node-fetch 2.6.1 -> 2.6.7**: Transitive dependency. Check which package pulls it in and override in package.json resolutions.
- **path-to-regexp 0.1.12 -> 0.1.13**: Likely transitive via `react-router-dom@5.3.0` (which uses `path-to-regexp@0.1.x`). The migration to `react-router-dom-modern@7.13.1` will resolve this.
- **validator 13.11.0 -> 13.15.22**: Update directly.

### 2.3 Additional Frontend Notes

- Uses Bun as package manager with `bun.lock` (no `package-lock.json`), so `npm audit` is not usable.
- 1698 packages in node_modules -- typical for a React application of this size.
- React 19.2.4, Redux Toolkit 2.11.2, Axios 1.13.6 -- all current.

---

## 3. Docker Image Security

### 3.1 Checkov / Hadolint Config Scan

| Dockerfile | Finding | Severity | Details |
|------------|---------|----------|---------|
| Dockerfile.backend | DS-0002: No non-root USER directive | HIGH | Container runs as root by default |
| Dockerfile.backend | DS-0026: No HEALTHCHECK | LOW | Healthcheck defined in docker-compose instead |
| Dockerfile.frontend | DS-0002: No non-root USER directive | HIGH | Container runs as root by default |
| Dockerfile.frontend | DS-0026: No HEALTHCHECK | LOW | Static file container, less critical |

### 3.2 Analysis

**Dockerfile.backend**: Actually uses `su-exec chronicle` in CMD (line 110) to drop privileges at runtime, and creates a `chronicle` user (line 87). However, the Dockerfile itself lacks a `USER chronicle` directive, meaning build steps and the initial CMD exec context are root. **The runtime security is acceptable** but adding `USER chronicle` before CMD would satisfy container scanners and provide defense-in-depth.

**Dockerfile.frontend**: A static file copy container (`alpine:3.21`). Runs `cp` then `tail -f /dev/null`. Low risk since it only holds built assets, but should still run as non-root.

### 3.3 Secret in Docker Directory

**CRITICAL**: Gitleaks detected a private key at `docker/postgres-ssl/server/server.key`. If this is a production key, it must be removed from the repository immediately and rotated. If it is a development-only key, it should be documented as such and excluded from production builds.

### 3.4 Base Image Assessment

- **eclipse-temurin:17-jdk** (builder): Well-maintained, Eclipse Adoptium. Current.
- **alpine:3.21** (runtime): Minimal attack surface. Current.
- **oven/bun:1-alpine** (frontend builder): Official Bun image. Current.
- JLink custom JRE reduces runtime image to only required modules -- excellent practice.

---

## 4. License Audit

### 4.1 Project Licensing

| Module | License |
|--------|---------|
| chronicle-server | Apache License 2.0 |
| chronicle-api | GNU General Public License v3+ |
| chronicle-models | GNU General Public License v3+ |
| chronicle-web | Apache License 2.0 |

### 4.2 License Compatibility Concerns

**Mixed GPL/Apache licensing**: `chronicle-api` and `chronicle-models` are GPL v3+, while `chronicle-server` is Apache 2.0. This is architecturally valid (GPL modules can depend on Apache modules, and Apache modules can link to GPL modules if the combined work is distributed under GPL). However:

- If `chronicle-server` (Apache 2.0) links against `chronicle-api` and `chronicle-models` (GPL v3), the resulting binary distribution must comply with GPL v3 terms for the combined work.
- All runtime dependencies appear to use Apache 2.0, MIT, BSD, or similarly permissive licenses.
- No AGPL dependencies were detected in the runtime classpath.

### 4.3 Dependency License Report Plugin

The project has `com.github.jk1.dependency-license-report` plugin v1.16 configured in `chronicle-server/build.gradle`. Run `./gradlew generateLicenseReport` to produce a full HTML license inventory.

---

## 5. Supply Chain Hardening Recommendations

### 5.1 Immediate Actions (P0)

1. **Upgrade lodash to 4.18.0** in chronicle-web -- arbitrary code execution CVE.
2. **Upgrade node-fetch to >=2.6.7** -- information disclosure CVE.
3. **Verify docker/postgres-ssl/server/server.key** is not a production key. If it is, rotate immediately.
4. **Force commons-compress to >=1.26.0** in methodic.gradle resolution strategy to remediate DoS CVEs.

### 5.2 Short-term Actions (P1)

5. **Add `USER chronicle` to Dockerfile.backend** before CMD for defense-in-depth.
6. **Upgrade path-to-regexp** (complete migration to react-router-dom v7).
7. **Upgrade validator to >=13.15.22** in chronicle-web.
8. **Configure NVD API key** for OWASP dependency-check to enable automated CVE scanning in CI.
9. **Update stale version declarations** in methodic.gradle (commons_collections4_version, twilio_version).

### 5.3 Medium-term Actions (P2)

10. **Add Gradle dependency-updates plugin** (ben-manes) to track outdated dependencies.
11. **Pin Dockerfile base image digests** (e.g., `alpine:3.21@sha256:...`) to prevent supply chain attacks via tag mutation.
12. **Add SBOM generation** to CI pipeline (e.g., `syft` or Gradle CycloneDX plugin).
13. **Evaluate Kryo upgrade** from 4.x to 5.x.
14. **Upgrade spring-vault-core** to align with Spring 6.2.x.

---

## 6. Positive Security Findings

- Proactive transitive dependency forcing for CVE remediation (protobuf, netty, beanutils, grpc)
- Log4j at 2.24.3 with `formatMsgNoLookups=true` defense-in-depth
- Jackson at 2.21.1 (latest)
- Spring Framework 6.2.16 and Spring Security 6.5.8 (current patches)
- JLink custom JRE minimizes runtime attack surface
- Multi-stage Docker builds with Alpine runtime
- `bun install --frozen-lockfile` in Docker (reproducible builds)
- License report plugin integrated
- SnakeYAML resolved to 2.5 (safe against CVE-2022-1471)
