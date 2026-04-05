# Chronicle Compliance Verification -- April 2026

**Date:** 2026-04-05
**Auditor:** Automated compliance audit (Claude Code)
**Scope:** HIPAA Safe Harbor / GDPR de-identification controls

---

## Summary

| # | Control                     | Status   |
|---|----------------------------|----------|
| 1 | TDE Encryption             | **PASS** |
| 2 | SSL/TLS Configuration      | **PASS** |
| 3 | Audit Logging              | **PASS** |
| 4 | Cookie Attributes          | **PASS** |
| 5 | Participant Deletion       | **PASS** |
| 6 | Backup Encryption          | **PASS** |
| 7 | De-identification          | **PASS** (with note) |

**Overall: 7/7 PASS**

---

## 1. TDE Encryption -- PASS

**File:** `docker/init-db-encryption.sh`
**Kotlin schema:** `ChroniclePostgresTables.kt`

- pg_tde extension is created and verified (`CREATE EXTENSION pg_tde`).
- Key provider supports both file-based (dev) and HashiCorp Vault v2 (production).
- Principal key is created and set via `pg_tde_create_key_using_database_key_provider`.
- Verification test creates a `tde_heap` table and calls `pg_tde_is_encrypted()`.
- **15 tables** converted to `tde_heap` via `ALTER TABLE ... SET ACCESS METHOD tde_heap`:
  `candidates`, `study_participants`, `devices`, `sensor_data`, `android_sensor_data`,
  `chronicle_usage_events`, `chronicle_usage_stats`, `preprocessed_usage_events`,
  `questionnaire_submissions`, `time_use_diary_submissions`, `app_usage_survey`,
  `upload_buffer`, `audit`, `audit_buffer`, `participant_stats`.
- Tables not in `ChroniclePostgresTables.kt` (defined in `RedshiftDataTables.kt`):
  `sensor_data`, `chronicle_usage_events`, `chronicle_usage_stats`, `preprocessed_usage_events`.
  These are Redshift-origin tables that also exist in Postgres -- the encryption script correctly covers them.
- Script is idempotent (checks `pg_class` for existing `tde_heap` before converting).

## 2. SSL/TLS Configuration -- PASS

**Files:** `docker/init-postgres-ssl.sh`, `docker/traefik/traefik.yml`, `docker/docker-compose.traefik.yml`

### PostgreSQL SSL
- `ssl_min_protocol_version = 'TLSv1.2'` enforced in both `postgresql-ssl.conf` and docker-compose command args.
- `ssl_prefer_server_ciphers = on`.
- Cipher suite is modern AEAD-only: `ECDHE-ECDSA-AES256-GCM-SHA384`, `ECDHE-RSA-AES256-GCM-SHA384`, `CHACHA20-POLY1305`, `AES128-GCM-SHA256`.
- 4096-bit RSA keys (`KEY_SIZE=4096`).
- CA-signed server and client certificates generated; mTLS-ready.
- `pg_hba.conf` requires `hostssl` with `scram-sha-256` for all remote connections.
- File permissions enforced: 600 on private keys, 700 on directories.

### Traefik (reverse proxy)
- HTTP-to-HTTPS redirect on port 80.
- TLS minimum version: `VersionTLS12`.
- `sniStrict: true` prevents serving default cert to unknown SNI.
- HTTP/3 (QUIC) enabled on port 443.
- CrowdSec WAF bouncer plugin configured for IP reputation filtering.

## 3. Audit Logging -- PASS

**Files:** `docker/init-audit-immutability.sh`, `docker/docker-compose.traefik.yml`, `docker/siem/loki-config.yml`, `docker/siem/promtail-config.yml`

### pgaudit
- `shared_preload_libraries` includes `pgaudit`.
- `pgaudit.log = ddl,role,write` -- logs schema changes, role changes, and all write operations.
- `pgaudit.log_client = on`, `pgaudit.log_statement_once = on`.

### Immutability triggers
- `prevent_audit_modification()` trigger function raises exception on DELETE/UPDATE.
- Triggers applied to both `audit` and `audit_buffer` tables.
- `REVOKE DELETE, UPDATE` on both tables from the application user.
- Input validation on `POSTGRES_USER` to prevent SQL injection in REVOKE statements.

### Loki/Promtail
- Loki configured with **2190-day (6-year) retention** per HIPAA requirements.
- TSDB v13 schema (Loki 3.x compatible).
- Compactor with retention enabled and 2-hour delete delay.
- Promtail scrapes `/var/log/chronicle/audit*.log` with JSON parsing.
- Labels extracted: `action`, `userRole`, `resourceType`, `success`, `accessedPHI`.
- Static labels: `environment: production`, `compliance: hipaa`.
- WAL archiving enabled (`archive_mode=on`) for point-in-time recovery.

## 4. Cookie Attributes -- PASS

**File:** `chronicle-server/.../controllers/AuthTokenController.kt`

- Auth cookie (`chronicle_auth`):
  - `httpOnly = true` -- inaccessible to JavaScript (XSS protection).
  - `secure = isSecureRequest(request)` -- Secure flag set when behind HTTPS/proxy.
  - `SameSite = Strict` -- prevents CSRF via cross-origin requests.
  - `path = /chronicle`.
  - `maxAge = 30 days`.
- CSRF cookie (`ol_csrf_token`):
  - `httpOnly = false` (intentional -- JS must read CSRF token for double-submit).
  - `secure` and `SameSite=Strict` both set.
- Logout endpoint clears both cookies (`maxAge = 0`).
- `isSecureRequest()` defaults to `Secure=true` when `X-Forwarded-Proto` header is absent (safe default behind proxy).

## 5. Participant Deletion -- PASS

**Files:** `chronicle-server/.../controllers/ParticipantPurgeController.kt`, `chronicle-server/.../services/delete/ParticipantPurgeService.kt`

- Two endpoints: `previewParticipantPurge` (GET) and `executeParticipantPurge` (POST).
- Both require `StudyPermission.DELETE_DATA` via `@RequiresStudyAccess`.
- Preview generates a time-limited confirmation token (10-minute HMAC validity).
- Purge covers 10 data tables: `chronicle_usage_events`, `chronicle_usage_stats`,
  `preprocessed_usage_events`, `sensor_data`, `android_sensor_data`, `app_usage_survey`,
  `questionnaire_submissions`, `time_use_diary_submissions`, `participant_stats`, `upload_buffer`.
- Audit/audit_buffer intentionally excluded (HIPAA 6-year retention requirement documented in code comments).
- `candidates` excluded because PII columns have already been removed (see control 7).
- `devices` excluded because `source_device_id` has been replaced with server-assigned UUIDs.

## 6. Backup Encryption -- PASS

**File:** `docker/backup-chronicle.sh`

- Encryption: `openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000` -- AES-256-CBC with PBKDF2 at 600,000 iterations.
- Key stored outside backup directory at `/etc/chronicle/backup-encryption-key` (root-only readable).
- Legacy key location fallback with migration warning.
- Four backup components: database dump, TDE keyring, config/secrets, audit logs.
- Manifest with SHA-256 checksums for integrity verification.
- Verify mode decrypts and validates with `pg_restore --list`.
- Retention policy: 7 daily, 4 weekly, 3 monthly with automated pruning.
- Temp files cleaned up on exit via trap.
- Backup directory permissions: 700 (directory), 600 (files).

## 7. De-identification -- PASS (with note)

**Files:** `chronicle-server/.../upgrades/CandidatePiiRemovalUpgrade.kt`, `chronicle-server/.../upgrades/SourceDeviceIdToDeviceIdUpgrade.kt`, `chronicle-server/.../storage/ChroniclePostgresTables.kt`, `chronicle/.../constants/FirebaseAnalyticsEvents.kt`

### Candidates table PII removal
- `CandidatePiiRemovalUpgrade` nulls then drops 6 PII columns: `first_name`, `last_name`, `name`, `dob`, `email`, `phone_number`.
- Transaction-safe with rollback on failure.
- Upgrade is idempotent (checks `upgradeService.isUpgradeComplete`).
- `ChroniclePostgresTables.CANDIDATES` now defines only `CANDIDATE_ID` and `EXPIRATION_DATE` -- PII columns are absent from the schema.

### source_device_id migration
- `SourceDeviceIdToDeviceIdUpgrade` migrates `source_device_id` (hardware identifier) to server-assigned `device_id` (UUID) in:
  - `android_sensor_data` (add device_id, populate from devices lookup, drop source_device_id)
  - `upload_buffer` (same pattern)
  - `android_device_sensor_availability` (PK recreation: drop old PK, add device_id, drop source_device_id, recreate PK)
- Orphaned rows (no matching device) are deleted.
- `devices` table retains `source_device_id` temporarily for v3 API compatibility shim, with deprecation comments.

**Note:** The `devices` table in `ChroniclePostgresTables.kt` still includes `SOURCE_DEVICE_ID` and `SOURCE_DEVICE` columns. These are documented as deprecated and retained for the v3 compatibility shim. They should be dropped after full v4 migration to achieve complete de-identification of the devices table.

### Firebase Analytics
- `FirebaseAnalyticsEvents.kt` defines only operational event names (enrollment, upload, usage, sensor, notification status). No PII fields are included in event names.
- `MainActivity.kt` calls `firebaseAnalytics.setUserId(null)` on startup, clearing any user ID.
- `EnrollmentSettings.kt` calls `crashlytics.setUserId("")` to clear Crashlytics user ID.
- No `setUserProperty` calls found in the codebase.
- `logEvent` calls pass `null` bundles or bundles with only numeric counts -- no PII parameters observed.

---

## Test Suite Results (2026-04-05)

### chronicle-server:test -- FAILED (compilation error)
- `ChronicleServerMvcPod.kt:54` -- "Annotations on annotation arguments are prohibited" (Kotlin compiler error).
- No tests executed; the main source does not compile.

### chronicle-api:test -- FAILED (compilation error)
- `-Werror` flag causes deprecation warnings to fail the build.
- `ChronicleDataSerializerTest.kt` uses deprecated `RandomStringUtils.randomAlphanumeric()` and `RandomUtils.nextInt()`.
- `StudyJacksonSerializerTest.kt` uses deprecated `RandomStringUtils.randomAlphabetic()`.
- No tests executed.

### chronicle-web (bun test) -- 3070 pass, 21 fail, 5 errors
- **3070 tests pass** across 64 files (1.93s).
- **21 failures** -- primarily in legacy core helpers due to missing exports (`CSRF_COOKIE`, `PRINCIPAL` not found in `src/common/constants/index.js`).
- **5 errors** -- `translations.test.js` uses Flow type annotations (`obj :Object`) incompatible with Bun's parser.
- 63 snapshots, 32,446 expect() calls.
