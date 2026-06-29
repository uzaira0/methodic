# Chronicle Data Classification Policy

This document defines the data classification tiers for all persistent data in the Chronicle platform. Classification drives encryption requirements, access controls, retention policies, and audit logging.

---

## Classification Tiers

### Tier 1 -- PHI (Protected Health Information)

Data that constitutes Protected Health Information under HIPAA. Breach of this data triggers HIPAA notification requirements.

| Table | Description |
|-------|-------------|
| `candidates` | Participant demographic/identity records (note: PII columns `first_name`, `last_name`, `dob`, `email`, `phone_number` have been dropped via migration) |
| `study_participants` | Enrollment records linking candidates to studies |
| `sensor_data` | iOS sensor data collected from participant devices |
| `android_sensor_data` | Android sensor data collected from participant devices |
| `chronicle_usage_events` | Raw device usage events |
| `chronicle_usage_stats` | Aggregated device usage statistics |
| `preprocessed_usage_events` | Processed/normalized usage events |
| `questionnaire_submissions` | Participant questionnaire responses |
| `time_use_diary_submissions` | Time-use diary entries from participants |
| `app_usage_survey` | App usage survey responses |

**Controls:**

- **Encryption**: Required. TDE at rest (via Percona `pg_tde` / `tde_heap` access method) + TLS in transit + AES-256-CBC encrypted backups.
- **Access**: Row-Level Security (RLS) enforced at the database level. All queries scoped to authorized studies via `chronicle_has_study_access()`. Candidates table uses `chronicle_has_candidate_access()` which checks study membership through `study_participants`.
- **Retention**: Per study protocol, with a minimum of 6 years per HIPAA requirements (45 CFR 164.530(j)).
- **Logging**: All access logged in `audit_logs` with `accessed_phi = true` flag. PHI field names recorded in `phi_fields` array.

---

### Tier 2 -- PII (Personally Identifiable Information)

Data that can identify an individual but is not health-related. Still subject to HIPAA and GDPR protections when linked to a study participant.

| Table | Description |
|-------|-------------|
| `devices` | Device tokens, device identifiers linked to participants |
| `upload_buffer` | Staging area for incoming data uploads (may contain raw PII/PHI in transit) |
| `participant_stats` | Per-participant usage statistics and metadata |

**Controls:**

- **Encryption**: Required. TDE at rest (`tde_heap` access method).
- **Access**: RLS enforced. Study-scoped via `chronicle_has_study_access()`.
- **Retention**: Same as the associated study. Deleted when study data is purged.
- **Logging**: Access logged in `audit_logs`.

---

### Tier 3 -- Sensitive Internal

Data that supports security, auditing, and authentication. Compromise of this data could enable unauthorized access.

| Table | Description |
|-------|-------------|
| `audit` | Legacy audit trail records |
| `audit_buffer` | Buffered audit events pending flush |
| `audit_logs` | HIPAA-compliant audit log (V2 migration) with PHI access tracking |
| `api_keys` | Hashed API keys (SHA-256) for programmatic study access |
| `refresh_tokens` | OAuth refresh tokens for session management |
| `permissions` | ACL permission grants |

**Controls:**

- **Encryption**: Required. TDE for `audit` and `audit_buffer`. API keys stored as SHA-256 hashes (key material never persisted in cleartext; only `key_hash` and `key_prefix` stored).
- **Access**: `audit_logs` are admin-read-only (RLS policy: `app.is_admin = true` for SELECT, INSERT always allowed for service account, UPDATE denied, DELETE admin-only). `api_keys` scoped by study via RLS. `permissions` managed by application authorization layer.
- **Retention**: `audit` / `audit_logs`: 6+ years (HIPAA minimum). `api_keys`: until revoked or expired (`expires_at` column). `refresh_tokens`: until expired or revoked.
- **Logging**: These tables ARE the audit trail. `audit_logs` is append-only (UPDATE policy returns `false`).

---

### Tier 4 -- Internal / Non-Sensitive

Operational data required for application function. No direct PII/PHI content.

| Table | Description |
|-------|-------------|
| `studies` | Study metadata (title, description, settings) |
| `organizations` | Organization records |
| `principals` | Security principal identities |
| `upgrades` | Schema migration tracking |
| `filtered_apps` | Per-study app filtering configuration |
| `default_filtered_apps` | System-wide default app filter list |
| `notifications` | Notification configuration and delivery tracking |
| `study_limits` | Per-study resource quotas and limits |
| `study_lifecycle_events` | Study status transition audit trail |
| `study_deletion_schedule` | Scheduled study deletions |
| `study_anonymization_config` | Per-study anonymization settings |
| `participant_pseudonyms` | Pseudonym mappings (study-scoped) |
| `questionnaires` | Questionnaire definitions |
| `time_use_diary_summarized` | Summarized TUD data |
| `organization_studies` | Organization-study membership |

**Controls:**

- **Encryption**: Optional. TLS in transit is sufficient. TDE not required but applied where table is study-scoped.
- **Access**: Application authentication required. Study-scoped tables enforce RLS.
- **Retention**: Application lifetime. Deleted when parent study or organization is removed.
- **Logging**: Standard application logging.

---

## GDPR / Data Subject Access Request (DSAR) Process

### Data Subject Access Request

1. Identify the participant across all studies by `participant_id` or `candidate_id`.
2. Query all Tier 1 and Tier 2 tables:
   ```sql
   -- Example: find all data for a participant
   SELECT * FROM study_participants WHERE candidate_id = '<CANDIDATE_ID>';
   SELECT * FROM sensor_data WHERE participant_id = '<PARTICIPANT_ID>';
   SELECT * FROM android_sensor_data WHERE participant_id = '<PARTICIPANT_ID>';
   SELECT * FROM chronicle_usage_events WHERE participant_id = '<PARTICIPANT_ID>';
   SELECT * FROM chronicle_usage_stats WHERE participant_id = '<PARTICIPANT_ID>';
   SELECT * FROM preprocessed_usage_events WHERE participant_id = '<PARTICIPANT_ID>';
   SELECT * FROM questionnaire_submissions WHERE participant_id = '<PARTICIPANT_ID>';
   SELECT * FROM time_use_diary_submissions WHERE participant_id = '<PARTICIPANT_ID>';
   SELECT * FROM app_usage_survey WHERE participant_id = '<PARTICIPANT_ID>';
   SELECT * FROM devices WHERE participant_id = '<PARTICIPANT_ID>';
   SELECT * FROM participant_stats WHERE participant_id = '<PARTICIPANT_ID>';
   ```
3. Export results as JSON (machine-readable format).
4. Log the DSAR fulfillment in `audit_logs` with action `DSAR_ACCESS`.

### Right to Erasure

1. DELETE from all Tier 1 and Tier 2 tables by `participant_id` / `candidate_id`.
2. Verify deletion by re-running the access queries (should return zero rows).
3. Log the erasure in `audit_logs` with action `DSAR_ERASURE`, including which tables were affected and row counts deleted.
4. Note: Audit log entries themselves are NOT deleted (legal retention requirement supersedes right to erasure for compliance records).

### Data Portability

Same process as Data Subject Access Request. Provide data in a machine-readable format (JSON). The export must include all Tier 1 and Tier 2 data associated with the data subject.

### Notes

- Candidate PII columns (`first_name`, `last_name`, `dob`, `email`, `phone_number`) have been dropped via migration. The `candidates` table retains only the `candidate_id` and study linkage.
- All DSAR operations must be performed by an admin (`app.is_admin = 'true'`) to bypass RLS and access cross-study data.
- DSAR requests must be fulfilled within 30 days (GDPR Art. 12(3)).
