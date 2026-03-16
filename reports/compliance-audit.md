# HIPAA/GDPR Compliance Audit Report

**System:** Chronicle Research Platform
**Date:** 2026-03-16
**Auditor:** Automated compliance scan
**Scope:** Data-at-rest encryption, transport security, audit logging, session security, data retention, access control, right to erasure

---

## Summary

| Status | Count |
|--------|-------|
| PASS   | 6     |
| PARTIAL| 1     |
| FAIL   | 0     |

---

## Control Details

### CTRL-01: Transparent Data Encryption (TDE) — Data at Rest

**Status:** PASS
**Regulation:** HIPAA 164.312(a)(2)(iv), GDPR Art. 32(1)(a)

**Evidence:**
All 15 PHI tables are encrypted via Percona pg_tde 2.0.0 (`pg_tde_is_encrypted = true`):

| Table | Encrypted |
|-------|-----------|
| android_sensor_data | t |
| app_usage_survey | t |
| audit | t |
| audit_buffer | t |
| candidates | t |
| chronicle_usage_events | t |
| chronicle_usage_stats | t |
| devices | t |
| participant_stats | t |
| preprocessed_usage_events | t |
| questionnaire_submissions | t |
| sensor_data | t |
| study_participants | t |
| time_use_diary_submissions | t |
| upload_buffer | t |

Key provider: `chronicle-file-vault`, principal key: `chronicle-principal-key`.
Keyring directory: `/var/lib/postgresql/tde-keyring` on a named Docker volume.

---

### CTRL-02: Transport Encryption (SSL/TLS)

**Status:** PASS
**Regulation:** HIPAA 164.312(e)(1), GDPR Art. 32(1)(a)

**Evidence:**

| Parameter | Value |
|-----------|-------|
| ssl | on |
| ssl_cert_file | /var/lib/postgresql/ssl/server.crt |
| ssl_min_protocol_version | TLSv1.2 |
| Active connection TLS version | TLSv1.3 |
| ssl_ciphers | HIGH:MEDIUM:+3DES:!aNULL |

`pg_hba.conf` enforces `hostssl` with `scram-sha-256` for all Docker network and remote connections. Only localhost (127.0.0.1) allows non-SSL `host` connections (still requires scram-sha-256 password).

---

### CTRL-03: Audit Logging Infrastructure

**Status:** PASS
**Regulation:** HIPAA 164.312(b), GDPR Art. 30

**Evidence:**

- Active audit log: `/var/log/chronicle/audit.log` (700,398 bytes as of 2026-03-16)
- Rotated compressed logs present from 2026-02-25 through 2026-03-15 (8 archived files)
- **Loki** log aggregation service: health check returns `ready`
- **Promtail** agent configured to tail `/var/log/chronicle/audit*.log` and ship to Loki at `http://loki:3100/loki/api/v1/push`
- Grafana dashboard `chronicle-audit.json` provides visual audit log querying
- `ParticipantPurgeService` generates `AuditableEvent` entries for both preview (`PREVIEW_PARTICIPANT_PURGE`) and execution (`PURGE_PARTICIPANT_DATA`, `CREATE_JOB`) of data deletion operations

---

### CTRL-04: Cookie and Session Security

**Status:** PASS
**Regulation:** HIPAA 164.312(d), GDPR Art. 32(1)(b)

**Evidence** (from `AuthTokenController.kt`):

| Attribute | `chronicle_auth` cookie | `ol_csrf_token` cookie |
|-----------|------------------------|----------------------|
| HttpOnly | true | false (intentional: JS reads CSRF token) |
| Secure | true (when behind HTTPS/X-Forwarded-Proto) | true |
| SameSite | Strict | Strict |
| Path | /chronicle | /chronicle |
| Max-Age | 30 days (2,592,000s) | 30 days |

Additional protections:
- CSRF double-submit pattern: `ChronicleCookieOrBearerTokenResolver` validates that a CSRF header/param matches the CSRF cookie before accepting the auth cookie
- Auth management paths (`/set-cookie`, `/session`, `/testing-login`, `/logout`) return `null` from the token resolver to prevent expired cookie 401 loops
- Logout endpoint clears both cookies with `maxAge = 0`
- `SecureXmlFactory` provides XXE-protected XML parsing across the codebase

---

### CTRL-05: Data Retention and Backup Encryption

**Status:** PASS
**Regulation:** HIPAA 164.312(a)(2)(iv), 164.310(d)(2)(iv), GDPR Art. 5(1)(e)

**Evidence** (from `backup-chronicle.sh`):

- **Encryption:** AES-256-CBC with PBKDF2 key derivation (100,000 iterations) via OpenSSL
- **Key management:** Encryption key stored at `/etc/chronicle/backup-encryption-key` (outside backup directory, root-only readable)
- **Retention policy:** Automated pruning via `--prune` with retention tags
- **Backup script:** `/opt/chronicle/docker/backup-chronicle.sh` (executable, 13,390 bytes)
- **Operations:** `--full` (encrypted backup), `--verify` (integrity check), `--list` (inventory), `--prune` (retention enforcement)
- **Scope:** Database dump, TDE keyring, config/secrets, and audit logs
- **Schedule:** Cron at `0 2 * * *` (daily full backup), `0 3 * * 0` (weekly verify)

**Note:** Backup directory `/opt/chronicle/backups/` is currently empty. This may indicate backups are stored elsewhere or have not yet been initiated. Verify cron job is active.

---

### CTRL-06: Role-Based Access Control (RBAC)

**Status:** PASS
**Regulation:** HIPAA 164.312(a)(1), GDPR Art. 25(2)

**Evidence:**

| Metric | Value |
|--------|-------|
| Total permission entries | 143 |
| Distinct ACL keys (securable objects) | 128 |

- `permissions` table enforces per-object, per-principal access with `acl_key`, `principal_type`, `principal_id`, and `permissions` array
- Supports permission expiration via `expiration_date` column (defaults to infinity)
- `ParticipantPurgeController` requires `@RequiresStudyAccess(StudyPermission.DELETE_DATA)` for both preview and execution
- `ApiKeyAuthenticationFilter` maps HTTP methods to scopes (POST/PUT/PATCH/DELETE -> WRITE)
- Principals and permissions are cached in Hazelcast with EAGER load from DB

---

### CTRL-07: Right to Erasure (Participant Data Purge)

**Status:** PARTIAL
**Regulation:** GDPR Art. 17

**Evidence:**

- **Dedicated purge service:** `ParticipantPurgeService.kt` with preview and execute workflow
- **Purge controller:** `ParticipantPurgeController.kt` at REST API endpoint with `DELETE_DATA` permission requirement
- **Confirmation token:** HMAC-SHA256 signed, time-limited (10 minutes), prevents accidental deletion
- **Covered data tables** (7 of 15 PHI tables):
  - `chronicle_usage_events`
  - `preprocessed_usage_events`
  - `sensor_data`
  - `android_sensor_data`
  - `app_usage_survey`
  - `questionnaire_submissions`
  - `time_use_diary_submissions`
- **Audit trail:** Both preview and execution generate `AuditableEvent` records
- **Background jobs:** Deletion runs via `ChronicleJob` system (DeleteParticipantUsageData, DeleteParticipantTUDSubmissionData, DeleteParticipantAppUsageSurveyData)

**Gaps identified:**
1. **Enrollment record preserved:** The purge explicitly preserves participant enrollment (`study_participants`, `candidates`, `devices` records remain). This is by design (comment: "participant remains enrolled") but may not fully satisfy GDPR Art. 17 if a complete erasure is requested.
2. **Tables not covered by purge:** `participant_stats`, `upload_buffer`, `audit`, `audit_buffer` are not targeted by the purge service. Audit records may be exempt under GDPR Art. 17(3)(e) (legal obligation), but `participant_stats` and `upload_buffer` should be evaluated.
3. **No automated data retention expiry:** `StudyLimits.dataRetentionDuration` exists in the data model but no automated job was observed that purges data after the retention period expires.

---

## Recommendations

1. **CTRL-07 (High):** Extend `ParticipantPurgeService` to cover `participant_stats` and `upload_buffer` tables. Add an option for full erasure (including enrollment records) to satisfy complete GDPR Art. 17 requests.
2. **CTRL-07 (Medium):** Implement automated data retention enforcement that purges participant data when `StudyLimits.dataRetentionDuration` expires.
3. **CTRL-05 (Medium):** Verify the backup cron job is active and producing backups. The empty `/opt/chronicle/backups/` directory suggests backups may not be running.
4. **CTRL-02 (Low):** Consider restricting `ssl_ciphers` to remove `+3DES` and `MEDIUM` strength ciphers for stricter transport security.
