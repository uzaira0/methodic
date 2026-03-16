# Chronicle Supply Chain Security Report

**Generated:** 2026-03-16
**Scanner:** Trivy 0.69.3 (vuln DB updated 2026-03-16)
**Scope:** chronicle-backend:latest, chronicle-frontend:latest, source dependencies

---

## Executive Summary

| Category              | Critical | High | Medium | Low |
|-----------------------|----------|------|--------|-----|
| Backend (Java JARs)   | 0        | 4    | 8      | -   |
| Frontend (npm/bun)    | 0        | 5    | 0      | -   |
| Base images (Alpine)  | 0        | 0    | 0      | 0   |
| **Total**             | **0**    | **9**| **8**  | -   |

**Overall risk:** MODERATE -- no critical vulnerabilities, but 9 HIGH findings require remediation, primarily DoS vectors in Jetty, Jackson, and credential leakage in axios.

---

## 1. Backend Vulnerabilities (Java JARs)

207 JARs scanned in `chronicle-backend:latest`. Base image Alpine 3.21.6 is clean.

### HIGH Severity

| Dependency | Installed | Fixed | CVE | CVSS | Title | Recommendation |
|---|---|---|---|---|---|---|
| jackson-core | 2.21.0 | 2.21.1 | GHSA-72hv-8253-57qq | 8.7 (v4) | Number length constraint bypass in async parser (DoS) | Upgrade to 2.21.1. Patch release, low risk. |
| jackson-core | 2.17.2 (transitive) | 2.18.6 / 2.21.1 | GHSA-72hv-8253-57qq | 8.7 (v4) | Same as above (older transitive copy) | Force version alignment to 2.21.1 via Gradle constraint. |
| jetty-http2-common | 12.0.22 | 12.0.25 | CVE-2025-5115 | 7.5 (v3.1) | HTTP/2 "MadeYouReset" DoS via control frames | Upgrade Jetty to 12.0.25+. |
| jetty-server | 12.0.22 | 12.0.32 | CVE-2026-1605 | 7.5 (v3.1) | DoS via unreleased JDK Inflater from compressed requests | Upgrade Jetty to 12.0.32+. |

### MEDIUM Severity

| Dependency | Installed | Fixed | CVE | Title |
|---|---|---|---|---|
| netty-codec-http | 4.1.128.Final | 4.1.129.Final | CVE-2025-67735 | Request smuggling via CRLF injection |
| commons-compress | 1.25.0 | 1.26.0 | CVE-2024-25710 | DoS via infinite loop on corrupted DUMP file |
| commons-compress | 1.25.0 | 1.26.0 | CVE-2024-26308 | OOM unpacking broken Pack200 file |
| commons-lang3 | 3.17.0 | 3.18.0 | CVE-2025-48924 | Uncontrolled recursion |
| log4j-core | 2.24.3 | 2.25.3 | CVE-2025-68161 | Info disclosure via missing TLS hostname verification |
| poi-ooxml | 5.2.5 | 5.4.0 | CVE-2025-31672 | Unexpected data from duplicate zip entries |
| angus-smtp | 2.0.2 / 2.0.3 | 2.0.4 | CVE-2025-7962 | Jakarta Mail SMTP injection |

---

## 2. Frontend Vulnerabilities (npm/bun)

53 production dependencies, 59 devDependencies. 1,442 resolved packages in lockfile.

### HIGH Severity

| Dependency | Installed | Fixed | CVE | Title | Recommendation |
|---|---|---|---|---|---|
| axios | 0.26.1 | 0.30.0 / 1.8.2 | CVE-2025-27152 | SSRF and credential leakage via absolute URL | **Priority: upgrade to axios >= 1.8.2.** Direct dependency. |
| axios | 0.26.1 | 0.30.3 / 1.13.5 | CVE-2026-25639 | DoS via `__proto__` key in mergeConfig | Same upgrade resolves both. |
| immutable | 4.0.0-rc.10 | 4.3.8 | CVE-2026-29063 | Prototype pollution / unexpected behavior | Upgrade to immutable >= 4.3.8. |
| node-fetch | 2.6.1 (transitive) | 2.6.7 | CVE-2022-0235 | Sensitive information exposure to unauthorized actor | Ensure transitive resolution >= 2.6.7 via overrides. |
| validator | 13.11.0 | 13.15.22 | CVE-2025-12758 | Incomplete filtering bypass | Upgrade to validator >= 13.15.22. Direct dependency. |

---

## 3. License Compliance

### Backend (OS packages)
- **GPL-2.0-only / GPL-3.0-or-later:** alpine-baselayout, apk-tools, busybox, gettext, libunistring (system packages, acceptable for container runtime; not linked into application)
- **LGPL-2.1-or-later:** gettext-libs, libgomp, libintl (dynamic linking, compliant)
- **MPL-2.0:** ca-certificates-bundle (reciprocal, file-level copyleft only)
- **Java JARs:** Predominantly Apache-2.0, MIT, EPL-2.0 (Eclipse Jetty), BSD. No copyleft contamination in application code.

### Frontend (OS packages)
- **GPL-2.0-only:** alpine-baselayout, apk-tools, busybox, scanelf (system only)
- **BSD-2-Clause/BSD-3-Clause:** nginx, pcre (permissive)
- **npm packages:** Predominantly MIT, Apache-2.0, ISC. No GPL dependencies in application bundle.

**Verdict:** No copyleft license risk for distributed application code. GPL packages are limited to container OS tooling (not linked/bundled).

---

## 4. Docker Image Security

### Base Images
| Image | Version | OS Vulns | Status |
|---|---|---|---|
| alpine | 3.21.6 | 0 HIGH/CRITICAL | Clean |
| eclipse-temurin | 17-jdk-alpine (build only) | N/A | Not in runtime image |
| oven/bun | 1-alpine (build only) | N/A | Not in runtime image |

### Image Hardening Assessment
| Check | Backend | Frontend |
|---|---|---|
| Non-root user | Yes (`chronicle` via su-exec) | N/A (static file copier) |
| Minimal base (Alpine) | Yes (3.21) | Yes (3.21) |
| Multi-stage build | Yes (3 stages: build, jlink, runtime) | Yes (2 stages: build, runtime) |
| Custom JRE (jlink) | Yes (strips ~81MB) | N/A |
| No package manager in runtime | No (apk present) | No (apk present) |
| Read-only filesystem | Not enforced | Not enforced |
| Image size | 187MB | 12.3MB |

### Image Provenance
| Property | Backend | Frontend |
|---|---|---|
| OCI source label | Yes (github.com/methodic-labs/chronicle) | No |
| OCI vendor label | Yes (Methodic Labs) | No |
| Image signing (cosign/notary) | Not configured | Not configured |
| SBOM embedded | Not embedded (255 components detected via scan) | Not embedded |

---

## 5. Supply Chain Risks

### Dependency Confusion
- **`lattice-fabricate`** and **`import-sort-style-openlattice`** are unscoped npm packages with internal/organization naming. If these are private packages, they are vulnerable to dependency confusion attacks (an attacker could publish same-named packages to the public npm registry).
- **Recommendation:** Move to scoped packages (e.g., `@openlattice/fabricate`) or use `.npmrc` with registry scoping.

### Dependency Locking & Verification
| Mechanism | Backend (Gradle) | Frontend (Bun) |
|---|---|---|
| Lockfile | **Missing** | Present (`bun.lock`) |
| Dependency verification (checksums) | **Missing** (`gradle/verification-metadata.xml` not found) | Bun lockfile includes integrity hashes |
| Version pinning | Ranges in build.gradle | Mixed (~ and ^ ranges in package.json) |

**Backend risk:** Without `verification-metadata.xml` or a Gradle lockfile, builds are not reproducible and are vulnerable to dependency substitution if a repository is compromised.

### Transitive Dependency Risks
- **jackson-core 2.17.2** appears as a transitive dependency alongside the direct 2.21.0 version. This version mismatch indicates incomplete version alignment.
- **node-fetch 2.6.1** is a transitive dependency (likely via an older package) with a known information disclosure vulnerability from 2022.

---

## 6. Bloated/Unnecessary Dependencies

Top JARs by size in the runtime image:

| JAR | Size | Assessment |
|---|---|---|
| hazelcast-5.5.0.jar | 16.0 MB | Required (caching layer). Has 1 HIGH vuln. |
| aws-java-sdk-ec2-1.12.783.jar | 8.8 MB | **Likely unnecessary** -- EC2 API unlikely needed. Review if only S3/KMS are used. |
| poi-ooxml-lite-5.2.5.jar | 5.7 MB | Required for Excel export. Has MEDIUM vuln. |
| twilio-9.6.1.jar | 4.7 MB | Required if SMS notifications active. Otherwise removable. |
| kotlin-reflect-2.3.10.jar | 3.3 MB | Required by Kotlin serialization. |

**Potential savings:** Removing `aws-java-sdk-ec2` alone saves ~9MB. If Twilio SMS is not in use, another ~5MB.

---

## 7. Recommendations (Priority Order)

### Immediate (HIGH -- address within 1 week)

1. **Upgrade axios** from 0.26.1 to >= 1.8.2 in `chronicle-web/package.json`. CVE-2025-27152 enables SSRF and credential leakage. This is a direct dependency and the most actionable fix.

2. **Upgrade Jetty** from 12.0.22 to >= 12.0.32 in Gradle dependencies. Two HIGH DoS vulnerabilities (CVE-2025-5115, CVE-2026-1605) are network-exploitable without authentication.

3. **Upgrade jackson-core** to 2.21.1 and enforce version alignment across all modules using a Gradle platform/BOM constraint to eliminate the stale 2.17.2 transitive copy.

### Short-term (MEDIUM -- address within 1 month)

4. **Upgrade validator** from 13.11.0 to >= 13.15.22 (direct frontend dependency).
5. **Upgrade immutable** from 4.0.0-rc.10 to >= 4.3.8 (direct frontend dependency; also exits pre-release).
6. **Upgrade netty-codec-http** to >= 4.1.129.Final (request smuggling).
7. **Upgrade commons-compress** to >= 1.26.0 (DoS vectors).
8. **Upgrade angus-smtp** to >= 2.0.4 (SMTP injection).
9. **Upgrade log4j-core** to >= 2.25.3 (TLS hostname verification bypass).

### Structural Improvements (address within 1 quarter)

10. **Enable Gradle dependency verification:** Generate `gradle/verification-metadata.xml` with `./gradlew --write-verification-metadata sha256`. This prevents dependency substitution attacks.
11. **Enable Gradle dependency locking:** Add `dependencyLocking { lockAllConfigurations() }` to prevent silent version drift.
12. **Scope internal npm packages:** Rename `lattice-fabricate` to `@openlattice/fabricate` (or add `.npmrc` registry scoping) to prevent dependency confusion.
13. **Add OCI labels to frontend image** for traceability (source, vendor, version).
14. **Configure image signing** with cosign for both images to establish provenance.
15. **Remove `aws-java-sdk-ec2`** if EC2 APIs are not used -- it adds 9MB and attack surface.
16. **Pin frontend `^` ranges** to `~` for production dependencies to reduce unexpected breaking changes.
17. **Add `node-fetch` override** in package.json to force >= 2.6.7 for transitive resolution.

---

## Appendix: Scan Metadata

- **Trivy version:** 0.69.3
- **Vulnerability DB:** Updated 2026-03-16T00:39:57Z
- **Java DB:** Updated 2026-03-15T01:29:12Z
- **Backend image:** chronicle-backend:latest (alpine 3.21.6, 187MB, 207 JARs, 255 SBOM components)
- **Frontend image:** chronicle-frontend:latest (alpine 3.21.6, 12.3MB, 1,442 npm packages)
- **Scan types:** Vulnerability (HIGH/CRITICAL/MEDIUM), License, Secret, Filesystem
