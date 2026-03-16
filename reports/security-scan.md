# Chronicle Security Scan Report

**Date:** 2026-03-16
**Branch:** develop (commit 632fc81)
**Tools:** Semgrep 1.155.0, Gitleaks 8.21.2, Hadolint 2.14.0

---

## Summary

| Category | Critical | High | Medium | Low/Info | False Positive |
|---|---|---|---|---|---|
| SAST (Backend) | 0 | 0 | 4 | 4 | 8 |
| SAST (Frontend) | 0 | 0 | 1 | 0 | 1 |
| Secrets | 2 | 3 | 4 | 18 | 0 |
| Dockerfile Lint | 0 | 0 | 5 | 1 | 0 |
| SQL Injection | 0 | 0 | 1 | 0 | 0 |
| ReDoS | 0 | 0 | 0 | 0 | N/A |

**Total actionable findings: 20** (excluding false positives)

---

## 1. Semgrep SAST — Backend (Java/Kotlin)

### Finding 1: Cookie missing `secure` flag (FALSE POSITIVE)
- **Rule:** `kotlin.lang.security.cookie-missing-secure-flag`
- **Severity:** WARNING
- **Files:**
  - `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/AuthTokenController.kt:153`
  - `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/AuthTokenController.kt:162`
  - `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/AuthTokenController.kt:180`
  - `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/AuthTokenController.kt:189`
- **Analysis:** FALSE POSITIVE. The code dynamically sets `authCookie.secure = isSecure` based on `request.isSecure || request.getHeader("X-Forwarded-Proto") == "https"`. Semgrep's pattern matching does not track the dynamic assignment. The `secure` flag IS set when running behind HTTPS (which is the production configuration via Traefik).
- **Action:** No code change needed. Add a `// nosemgrep: cookie-missing-secure-flag` comment if desired.

### Finding 2: Cookie missing `HttpOnly` flag (FALSE POSITIVE — partial)
- **Rule:** `kotlin.lang.security.cookie-missing-httponly`
- **Severity:** WARNING
- **Files:**
  - `AuthTokenController.kt:153` — `authCookie` (line 148 sets `isHttpOnly = true`) — **FALSE POSITIVE**
  - `AuthTokenController.kt:162` — `csrfCookie` (line 157 sets `isHttpOnly = false`) — **TRUE POSITIVE (by design)**
  - `AuthTokenController.kt:180` — `authCookie` (line 175 sets `isHttpOnly = true`) — **FALSE POSITIVE**
  - `AuthTokenController.kt:189` — `csrfCookie` (line 184 sets `isHttpOnly = false`) — **TRUE POSITIVE (by design)**
- **Analysis:** The `authCookie` (JWT) correctly has `HttpOnly = true`. The CSRF cookie intentionally has `HttpOnly = false` because JavaScript must read it to include in request headers. This is the standard CSRF double-submit cookie pattern.
- **Action:** No change needed. The CSRF cookie being non-HttpOnly is architecturally correct.

---

## 2. Semgrep SAST — Frontend (JS/React)

### Finding 3: Non-literal RegExp construction
- **Rule:** `javascript.lang.security.audit.detect-non-literal-regexp`
- **Severity:** WARNING
- **File:** `chronicle-web/src/modern/lib/bootstrap-auth.ts:44`
- **Code:** `document.cookie.match(new RegExp(\`(?:^|; )${escapedName}=([^;]*)\`))`
- **Analysis:** FALSE POSITIVE. The `name` parameter is escaped on the previous line using `name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')`, which neutralizes all regex metacharacters. No ReDoS risk.
- **Action:** No change needed.

### Finding 4: Path traversal in test file
- **Rule:** `javascript.lang.security.audit.path-traversal.path-join-resolve-traversal`
- **Severity:** WARNING
- **File:** `chronicle-web/src/modern/state/golden-file.test.ts:11`
- **Code:** `readFileSync(join(__dirname, '../test/golden', \`${name}.json\`), 'utf-8')`
- **Analysis:** Low risk. This is a test-only file (`*.test.ts`), not shipped to production. The `name` parameter comes from hardcoded test constants, not user input.
- **Action:** No change needed.

---

## 3. Gitleaks Secrets Scan (27 findings)

### CRITICAL — Production secrets in tracked/rendered files

| # | File | Rule | Severity | Assessment |
|---|---|---|---|---|
| 1 | `docker/.env:22` | `generic-api-key` (MOBILE_APP_KEY) | **CRITICAL** | Real production secret. `.env` is gitignored but present on disk. Ensure it stays excluded from version control. |
| 2 | `docker/rhizome-docker.yaml:31,42` | `generic-api-key` (DB password) | **CRITICAL** | Rendered from template; file is gitignored. Verify with `git ls-files docker/rhizome-docker.yaml`. |
| 3 | `docker/chronicle-config.json:1` | `jwt` | **HIGH** | Generated JWT token. File is gitignored. |

### HIGH — SSL private keys

| # | File | Rule | Severity | Assessment |
|---|---|---|---|---|
| 4 | `docker/postgres-ssl/ca/ca.key:1` | `private-key` | **HIGH** | CA private key for internal PostgreSQL SSL. Should NOT be in version control. |
| 5 | `docker/postgres-ssl/client/client.key:1` | `private-key` | **HIGH** | Client private key for PostgreSQL SSL. Should NOT be in version control. |
| 6 | `docker/postgres-ssl/server/server.key` | `private-key` | **HIGH** | Server private key (permission denied — good, but still on disk). |

### MEDIUM — Test/development secrets

| # | File | Rule | Severity | Assessment |
|---|---|---|---|---|
| 7 | `rhizome/src/test/resources/auth0.yaml:3,7` | `generic-api-key` | MEDIUM | Test Auth0 credentials. Likely non-production but should be rotated if ever used in prod. |
| 8 | `rhizome/build/resources/test/auth0.yaml:3,7` | `generic-api-key` | MEDIUM | Build artifact copy of test credentials. |
| 9 | `chronicle-server/src/test/resources/auth0.yaml:2,6,11` | `generic-api-key` | MEDIUM | Test Auth0 credentials (clientSecret + signing secret). |
| 10 | `chronicle-server/build/resources/test/auth0.yaml:2,6,11` | `generic-api-key` | MEDIUM | Build artifact copy. |

### LOW — Test fixtures / false positives

| # | File | Rule | Severity | Assessment |
|---|---|---|---|---|
| 11 | `chronicle/app/src/debug/google-services.json` (x4) | `gcp-api-key` | LOW | Firebase API key for debug builds. These are client-side keys restricted by package name — low risk. |
| 12 | `chronicle/app/src/release/google-services.json` (x4) | `gcp-api-key` | LOW | Firebase API key for release builds. Same assessment. |
| 13 | `tests/security/session-management-tests.sh:147` | `jwt` | LOW | Intentionally expired test JWT (`exp: 1577836800` = 2020). Not a real secret. |
| 14 | `chronicle-server/.../DtoSerializationTests.kt:1310` | `generic-api-key` | LOW | Hardcoded test value `chk_abc123def456ghi789`. Not a real key. |
| 15 | `chronicle-web/.../auth-utils.test.js:213` | `generic-api-key` | LOW | Test UUID token. Not a real secret. |

### Recommendations — Secrets

1. **Verify gitignore coverage:** Run `git ls-files docker/.env docker/rhizome-docker.yaml docker/chronicle-config.json` — all should return empty.
2. **Move SSL private keys out of version control:** The `docker/postgres-ssl/ca/ca.key` and `docker/postgres-ssl/client/client.key` files should be added to `.gitignore` and removed from the repo with `git rm --cached`. Generate them at deploy time or store in a secrets manager.
3. **Rotate test Auth0 credentials** if they were ever used in a non-test environment.
4. **Add `.gitleaksignore`** to suppress known false positives (test JWTs, Firebase client keys, test fixture values).

---

## 4. Hadolint Dockerfile Lint

### Dockerfile.backend

| Line | Rule | Severity | Finding |
|---|---|---|---|
| 7 | DL3008 | WARNING | `apt-get install` without pinned versions |
| 86 | DL3018 | WARNING | `apk add` without pinned versions |

### Dockerfile.frontend.prod

| Line | Rule | Severity | Finding |
|---|---|---|---|
| 30 | DL3018 | WARNING | `apk add` without pinned versions |
| 30 | DL4006 | WARNING | Missing `SHELL ["/bin/ash", "-eo", "pipefail"]` before `RUN` with pipe |
| 30 | SC2162 | INFO | `read` without `-r` flag will mangle backslashes |
| 43 | DL3018 | WARNING | `apk add` without pinned versions |

### Recommendations — Dockerfiles

1. Pin package versions for reproducible builds: `apt-get install curl=7.88.1-10+deb12u5` / `apk add curl=8.5.0-r0`.
2. Add `SHELL ["/bin/ash", "-eo", "pipefail"]` before any `RUN` command that uses pipes in `Dockerfile.frontend.prod`.
3. Use `read -r` to avoid backslash mangling.

---

## 5. SQL Injection Audit

### Finding: String.format used for SQL table names in pipeline steps (MITIGATED)
- **Severity:** MEDIUM (mitigated by input validation)
- **Files:**
  - `chronicle-server/src/main/kotlin/com/openlattice/chronicle/pipeline/steps/TimeBucketingStep.kt:42`
  - `chronicle-server/src/main/kotlin/com/openlattice/chronicle/pipeline/steps/FeatureExtractionStep.kt:40`
  - `chronicle-server/src/main/kotlin/com/openlattice/chronicle/pipeline/steps/AggregationStep.kt:40`
  - `chronicle-server/src/main/kotlin/com/openlattice/chronicle/pipeline/steps/DeidentificationStep.kt:38`
  - `chronicle-server/src/main/kotlin/com/openlattice/chronicle/pipeline/steps/PipelineStepExecutor.kt:25` (string interpolation in `countRows`)
- **Analysis:** Table names (`outputTable`, `sourceTable`) are injected into SQL via `String.format()` and string interpolation. However, `PipelineJobRunner.kt:24-30` validates all table names against `^[a-zA-Z_][a-zA-Z0-9_]{0,62}$` before execution. This regex-based allowlist effectively prevents SQL injection.
- **Residual risk:** If a new caller invokes `PipelineStepExecutor.execute()` directly without going through `PipelineJobRunner`, the validation would be bypassed.
- **Recommendation:** Move the `validateTableName` check into each `PipelineStepExecutor.execute()` implementation (defense-in-depth) rather than relying solely on the caller.

### Finding: ImportController uses string interpolation for table name (MITIGATED)
- **Severity:** MEDIUM (mitigated)
- **File:** `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/ImportController.kt:416`
- **Code:** `"INSERT INTO ${ChroniclePostgresTables.SYSTEM_APPS.name} SELECT * FROM $sourceTable ON CONFLICT DO NOTHING"`
- **Analysis:** `sourceTable` is validated by `SqlIdentifierValidator.validateImportTableName()` and the endpoint requires admin access (`ensureAdminAccess()`). Defense-in-depth is present.

### General SQL posture
The codebase consistently uses `PreparedStatement` with parameterized queries (`ps.setObject()`, `ps.setString()`) for all user-supplied data values. Table/column names come from enum constants (`ChroniclePostgresTables`, column enums) resolved at compile time. The SQL injection surface is limited to the pipeline and import features, both of which have input validation.

---

## 6. ReDoS Detection

The Semgrep `p/regex-dos` ruleset is no longer available (HTTP 404). Manual review was performed:

- **`bootstrap-auth.ts:43`** — Cookie regex uses `[^;]*` (non-greedy character class) which cannot cause catastrophic backtracking.
- **`PipelineJobRunner.kt:24`** — `^[a-zA-Z_][a-zA-Z0-9_]{0,62}$` is a simple character class regex with bounded repetition. No ReDoS risk.
- **No user-facing regex compilation** was found in backend code.

**Result:** No ReDoS vulnerabilities detected.

---

## Priority Action Items

| Priority | Action | Effort |
|---|---|---|
| ~~P0~~ | ~~Verify secret files are not tracked in git~~ — **VERIFIED:** `docker/.env`, `docker/rhizome-docker.yaml`, `docker/chronicle-config.json`, and all SSL keys return empty from `git ls-files`. They are properly gitignored. | Done |
| **P1** | Move `validateTableName` into `PipelineStepExecutor` implementations for defense-in-depth | 30 min |
| **P2** | Pin package versions in Dockerfiles | 30 min |
| **P2** | Add `SHELL` directive and `-r` flag fix in `Dockerfile.frontend.prod` | 10 min |
| **P3** | Add `.gitleaksignore` for known false positives | 15 min |
| **P3** | Rotate test Auth0 credentials if they were ever used outside test environments | 15 min |
