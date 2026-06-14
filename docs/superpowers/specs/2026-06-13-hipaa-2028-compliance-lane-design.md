# HIPAA-2028 Compliance Lane — Design

**Date:** 2026-06-13
**Status:** Roadmap approved; W1 ready to spec into an implementation plan.
**Scope:** Backend (`chronicle-server`), shared models (`chronicle-models`), Android collection modules (`chronicle/`), and infra (`docker/`, CI). **Frontend (`chronicle-web`) is OUT OF SCOPE** until explicitly greenlit — a current compliance constraint. New configuration is applied DB-direct (the way the beta studies are driven today), not via the web study form.

---

## 1. Context

The proposed HIPAA Security Rule overhaul (the Jan-2025 NPRM, expected to land for ~2028 compliance) flips today's *addressable* controls to **required**: mandatory MFA, enforced access control / least privilege, encryption of ePHI at rest and in transit, asset inventory, vulnerability scans every 6 months, and an annual penetration test. This lane brings Chronicle to that bar. e2ee of sensor payloads is added as defense-in-depth beyond the rule's letter.

This design is grounded in a verified audit of the current code (file:line evidence inline), not assumptions. Two prior assumptions were **corrected** by that audit:

- **MFA infrastructure already exists** — `MfaClaimValidator` (RFC 8176 `amr`) is implemented but gated behind `chronicle.security.require-mfa`, which defaults `false` and is never set true. MFA is a *configuration + IdP* task, not a greenfield build, and the web login is **OIDC-delegated** (not React-frontend auth) — so it is not blocked by the frontend freeze.
- **Encryption at rest is largely done** — `pg_tde` (AES-256, runtime table discovery, hourly `EncryptionHealthService` verification) is solid; production custodies the principal key in **Vault**; backups are AES-256-CBC, pbkdf2-600k, key-separated, restore-verified. The remaining gaps are key *rotation* and transport hardening, not encryption itself.

### Operating principle for this lane

**The tests are the compliance evidence.** Every workstream below names the test type that produces a durable, retained artifact (JUnit report, SARIF, parity fixture, dated compliance report). A control with no test that exercises it is, for audit purposes, not in place.

---

## 2. Workstreams

Build order: **W1 → W2 → W3 → W4 → W5**. W1 is the keystone — the difference between "we declared RLS" and "RLS engages."

### W1 — Make RLS + audit immutability actually engage *(mandate: access control / least privilege + audit integrity)*

**Current state (verified):**
- RLS is well-built: `V1__enable_row_level_security.sql` runs `ENABLE` + `FORCE ROW LEVEL SECURITY` on the PHI tables (17 in V1), with `chronicle_has_study_access()` keyed on the `app.authorized_studies` session var. Per-request plumbing: `RLSContextFilter.kt` + `RLSContextManager.kt` set the session vars after JWT auth.
- The **policy logic is already proven** by `RLSStudyIsolationTest.kt`, which creates a `chronicle_app_test` (NOSUPERUSER, NOBYPASSRLS) role, runs the *verbatim* V1 migration, and asserts isolation / `WITH CHECK` / admin-bypass / empty-context-denies under `SET LOCAL ROLE`.
- Audit immutability via `REVOKE UPDATE/DELETE` on `audit_logs` (V15), `study_settings_audit` (V25), `participant_collection_acknowledgment` (V26); V27 adds the consent-trail columns.
- The roles `chronicle_app` (NOSUPERUSER) and `chronicle_admin` (NOSUPERUSER, BYPASSRLS, 5-conn) already exist in `docker/init-db-roles.sql`.

**Gap:** the deployed app connects to Postgres as **`chronicle`, a superuser** (`docker/rhizome-docker.yaml`, `.env.example`; the runtime pool is built in `rhizome/.../DataSourceManager.kt:34-41` from the `hikari` Properties). A superuser **silently bypasses RLS and every REVOKE** — so the proven policy and the audit REVOKEs are inert in production. V15 even documents "the actual JDBC connection user is 'chronicle'." There is also **no test asserting the configured runtime role is non-superuser** — the isolation test simulates the role via `SET LOCAL ROLE`, which cannot catch a superuser connection on the live request path.

**Target design:**
- App datasource connects **AS `chronicle_app`** (NOSUPERUSER) — least privilege at the connection level, so RLS engages without relying on every code path remembering to `SET ROLE`.
- Flyway / migration runner and table bootstrap connect as `chronicle_admin` (or the table owner) — a separate, privileged datasource used only for schema work.
- Layer the existing session-var plumbing (`RLSContextManager`) on top for study-scoping.
- Apply the V27 consent-trail immutability **trigger** (belt-and-suspenders beyond REVOKE).

**Approach decision (flag for the plan):** connect-as-`chronicle_app` (recommended) vs. connect-as-privileged-then-`SET LOCAL ROLE chronicle_app` per request. Recommended on its merits: a least-privilege connection cannot bypass even if a code path forgets to drop privileges; `SET ROLE`-from-superuser leaves the pool one missed call away from full bypass. Reserve a separate `chronicle_admin` datasource for the operations that genuinely need elevation (migrations, table management).

**Verification → evidence:**
- *Integration (Testcontainers, real Postgres) — NEW:* a regression guard that resolves the **configured runtime hikari role** and asserts it is `NOSUPERUSER` (fails the build if prod config points at a superuser). This is the test that would have caught the current gap.
- *Integration — extend existing:* generalize `RLSStudyIsolationTest` from `study_participants` to a parameterized sweep over all RLS-protected tables.
- *Integration — audit immutability:* as `chronicle_app`, `UPDATE`/`DELETE` on each of the three audit tables → expect `PSQLException` SQLState `42501` (insufficient_privilege); `INSERT` succeeds. As superuser → succeeds (control case documenting why the role matters; guards against regression to a superuser pool).
- *Migration tests — extend `MigrationRoundtripTest`:* roles created with correct attributes; REVOKEs present post-migration; V27 trigger applies and rejects mutation of an existing consent row.
- *Property-based (jqwik):* random (authorized-studies set, row.study_id) → visible iff member.
- *Mutation (PIT, already wired):* target `RLSContextManager` / `RLSContextFilter` to confirm the session-var logic is genuinely covered.
- **Evidence artifact:** "RLS isolation + audit immutability" JUnit report + a generated compliance-evidence markdown mapping each test to its control.

### W2 — e2ee / envelope encryption of sensor payloads *(mandate: encryption of ePHI; defense-in-depth)*

**Current state (verified):** none. `AndroidSensorSample` / `ChronicleData` carry no ciphertext field; the device uploads plaintext over TLS; the backend writes plaintext into TDE Postgres. Single point of compromise = the backend process.

**Target design:** the device encrypts each upload batch under a study public key (envelope/AEAD); the backend stores ciphertext; the study private key is custodied in **Vault** (already in prod for TDE). Android + `chronicle-models` (envelope type) + backend (decrypt-on-read / decrypt-on-export). No frontend.

**Verification → evidence:**
- *Unit (crypto round-trip):* encrypt→decrypt == plaintext; flip one ciphertext byte → AEAD auth failure; wrong key → failure.
- *Cross-implementation parity (Android Kotlin ↔ server Kotlin):* shared JSON test vectors live in `chronicle-models` (both Android and server depend on it); the device-side encrypt and server-side decrypt both run against them — guards against device/server crypto drift.
- *Contract / serialization:* the ciphertext envelope round-trips through Jackson; legacy plaintext samples still deserialize (backward-compat).
- *Property-based:* random payload sizes round-trip.
- **Evidence artifact:** the parity fixture file + round-trip test report.

### W3 — Turn MFA on *(mandate: mandatory MFA)*

**Current state (verified):** `MfaClaimValidator` validates the RFC 8176 `amr` claim (accepted: `mfa`, `otp`, `hwk`) but is only wired in when `chronicle.security.require-mfa` is true (default false, `ChronicleServerSecurityPod.kt:85-86,428-432`). Researcher/web login is OIDC-delegated (PKCE, external IdP). The mobile API-key path has no step-up mechanism.

**Target design:** enable the flag; configure the IdP to enforce MFA and emit `amr`; validate end-to-end. Design the mobile path explicitly — either an out-of-band enrollment factor or a documented compensating control (API keys are per-device, per-`(studyId, participantId, deviceId)`, revocable). Mostly backend/IdP/infra + a browser redirect; no React code.

**Verification → evidence:**
- *Unit (`MfaClaimValidator`):* `amr` present-with-accepted-value → valid; absent → invalid; wrong value → invalid.
- *Integration (Spring Security filter):* matrix of `require-mfa` {true,false} × `amr` {present, absent, wrong} → expected 200/401.
- **Evidence artifact:** the auth-enforcement matrix report.

### W4 — Encryption-at-rest + transport hardening *(mandate: encryption at rest/in transit, key management)*

**Current state (verified):** TDE solid (AES-256, runtime discovery, hourly `EncryptionHealthService`); prod custodies the principal key in Vault; backups encrypted + restore-verified. **Gaps:** no TDE **key rotation** automation (`scripts/rotate-secrets.sh` explicitly skips the TDE key); staging uses an on-host file keyring; the JDBC URL relies on env for `sslmode`; no mTLS Traefik↔backend.

**Target design:** automated TDE principal-key rotation + monitoring of rotation age; staging → Vault; explicit `sslmode` on the connection string; mTLS on the backend bridge.

**Verification → evidence:**
- *Integration (Percona `pg_tde` container, if pullable in the local runner):* rotate the principal key → data still readable; `pg_tde_is_encrypted()` true pre/post.
- *Smoke:* a connection with `sslmode=disable` is refused; `verify-full` works.
- *IaC (existing Checkov / conftest / hadolint, extend) + container-structure-test.*
- **Evidence artifact:** rotation log + SSL-enforcement smoke report.

### W5 — Continuous vuln-scan + pentest cadence + compliance evidence *(mandate: 6-month vuln scans, annual pentest, written analysis)*

**Current state:** all scanners exist (semgrep, grype, OWASP dep-check, ZAP, the `chronicle-*` security skills).

**Target design:** scheduled 6-month vuln-scan + annual pentest jobs that emit dated, HIPAA-mapped evidence artifacts with retention. Leverage `chronicle-compliance-audit` + `hipaa-compliance-report-generator`.

**Caveat (from project memory):** GitHub Actions is infra-broken on these repos (jobs die in seconds). The cadence must run on a **self-hosted runner or a local scheduled job**, not GH-hosted Actions; verification is done with local gradle/bun/security runs.

**Verification → evidence:** dated SARIF bundle + a signed compliance report per cycle.

---

## 3. Cross-cutting

- **Structural search/refactor uses `astg`** (ast-grep), not grep, for code-shape queries — e.g. locating every `HikariDataSource(...)` / datasource-construction site for the W1 role change, and confirming no call path constructs a superuser pool. Raw text (`rg`) only for config keys/strings.
- **Test infrastructure:** Testcontainers is already a dependency (`chronicle-server/build.gradle`) and the `storage/rls/` suite uses it. The non-negotiable rule for every DB-layer compliance test: **connect as a NOSUPERUSER role** (the existing suite does this via `SET LOCAL ROLE chronicle_app_test`) — an in-memory DB or a superuser connection bypasses RLS and would make the test structurally unable to detect the very gap it claims to cover.
- **Run CI locally** (project memory): verify with local gradle/bun/security runs; do not rely on GH Actions.
- **No frontend** anywhere in this lane. New module/config surfaces are exercised DB-direct.

## 4. Dependencies & order

- **W1** has no prerequisites — roles and policy already exist; it is wiring + verification. Do it first; it lights up two mandates at once and closes HANDOFF Issue 1 / methodic#50.
- **W2** benefits from Vault (already in prod for TDE) but otherwise stands alone.
- **W3** depends on IdP configuration access (external).
- **W4** depends on the Percona/Vault environment for full rotation testing.
- **W5** is independent and can run in parallel as a scheduled job.

## 5. Open questions

1. **W1 elevation model** — confirm connect-as-`chronicle_app` (recommended) vs. `SET ROLE` per request.
2. **W2 key custody** — per-study keypair in Vault; who holds the private key (backend-only decrypt vs. researcher-held)?
3. **W3 mobile MFA** — out-of-band factor vs. documented compensating control for the per-device API-key path.
4. **W4 CI environment** — is the Percona `pg_tde` image pullable in the local runner for rotation tests, or is W4 verified as a staging smoke test?
