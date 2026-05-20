# Chronicle Database Performance Review

Generated: 2026-04-05

## Executive Summary

Chronicle's upload hot path writes to a single `upload_buffer` table (simple INSERT, no contention), which is a good architecture for high-throughput ingestion. However, the hot path also issues **3 sequential reads** before each write (participation status, device check, and storage resolution), which become the bottleneck under load. Several download queries lack optimal indexes.

---

## Query Inventory

### HOT PATH: Usage Event Upload (`AppDataUploadService`)

Every Android device upload (every 15 minutes per device) executes these queries **in sequence**:

#### H1. Get Participation Status
```sql
SELECT participation_status FROM study_participants
WHERE study_id = ? AND participant_id = ?
```
- **Table**: `study_participants`
- **WHERE columns**: `study_id`, `participant_id`
- **Index**: PRIMARY KEY (`study_id`, `participant_id`) -- COVERED
- **Classification**: HOT -- runs on every upload
- **Assessment**: Optimal. PK lookup, single row.

#### H2. Check Known Datasource (isKnownDatasource)
```sql
SELECT count(*) FROM DEVICES
WHERE study_id = ? AND participant_id = ? AND source_device_id = ?
```
- **Table**: `DEVICES`
- **WHERE columns**: `study_id`, `participant_id`, `source_device_id`
- **Index**: UNIQUE index on (`study_id`, `participant_id`, `source_device_id`) -- COVERED
- **Classification**: HOT -- runs on every upload
- **Assessment**: Optimal. Unique index exact match.

#### H3. Insert to Upload Buffer
```sql
INSERT INTO upload_buffer (study_id, participant_id, upload_data, uploaded_at, upload_type)
VALUES (?, ?, ?::jsonb, ?, 'Android')
```
- **Table**: `upload_buffer`
- **WHERE columns**: N/A (INSERT)
- **Index**: Index on (`study_id`, `participant_id`) exists
- **Classification**: HOT -- runs on every upload
- **Assessment**: Good. Append-only INSERT with no ON CONFLICT. The JSONB cast adds CPU cost but avoids index contention. **No primary key on upload_buffer** -- this is intentional (queue table).

#### H4. Insert/Update Participant Stats (via Hazelcast)
```sql
INSERT INTO participant_stats (...)
VALUES (...)
ON CONFLICT (study_id, participant_id) DO UPDATE SET ...
```
- **Table**: `participant_stats`
- **WHERE columns**: `study_id`, `participant_id` (conflict target)
- **Index**: PRIMARY KEY (`study_id`, `participant_id`) -- COVERED
- **Classification**: HOT -- runs on every upload
- **Assessment**: Runs through Hazelcast `executeOnKey`, serializing per participant. Under load, Hazelcast may batch these. The UPSERT itself is efficient (PK-based).

---

### HOT PATH: Sensor Data Upload (`SensorDataUploadService`)

#### H5. Insert Sensor Data to Upload Buffer
```sql
INSERT INTO upload_buffer (study_id, participant_id, upload_data, uploaded_at, upload_type, source_device_id)
VALUES (?, ?, ?::jsonb, now(), 'Ios', ?)
```
- **Table**: `upload_buffer`
- **Classification**: HOT
- **Assessment**: Same as H3. Simple append.

Note: The sensor upload path also calls `getParticipationStatus` (H1) and `isKnownDatasource` (H2) before writing, identical to the usage event path.

---

### WARM PATH: Background Data Movement

#### W1. Move from Upload Buffer (getMoveSql)
```sql
DELETE FROM upload_buffer WHERE (study_id, participant_id) IN (
    SELECT study_id, participant_id
    FROM upload_buffer
    WHERE upload_type = 'Android'
    ORDER BY study_id, participant_id
    FOR UPDATE SKIP LOCKED
    LIMIT 128
) AND upload_type = 'Android'
RETURNING *
```
- **Table**: `upload_buffer`
- **WHERE columns**: `study_id`, `participant_id`, `upload_type`
- **Index**: Index on (`study_id`, `participant_id`) -- PARTIALLY COVERED
- **Classification**: WARM -- runs every 5 minutes via scheduled task
- **Assessment**: **MISSING INDEX on `upload_type`**. The subquery filters on `upload_type` but no index includes it. For a queue table that grows/shrinks constantly, this matters. The `FOR UPDATE SKIP LOCKED` pattern is correct for concurrent consumers.
- **RECOMMENDATION**: Add composite index `(upload_type, study_id, participant_id)` to support the subquery filter efficiently.

#### W2. Insert Android Sensor Data (MoveAndroidSensorDataToStorageTask)
```sql
INSERT INTO android_sensor_data (study_id, participant_id, sample_id, sensor_type,
    sample_timestamp, sensor_timezone, device_id, sensor_x, sensor_y, sensor_z, sensor_w, sensor_accuracy)
VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT (sample_id) DO NOTHING
```
- **Table**: `android_sensor_data`
- **WHERE columns**: `sample_id` (conflict target)
- **Index**: PRIMARY KEY (`sample_id`) -- COVERED
- **Classification**: WARM -- batch task every 5 minutes
- **Assessment**: Efficient. `ON CONFLICT DO NOTHING` is idempotent. Batched via `addBatch()`.

---

### COLD PATH: Data Downloads (`DataDownloadService`)

#### C1. Download Usage Events
```sql
SELECT ... FROM chronicle_usage_events
WHERE study_id = ? AND participant_id = ANY(?) AND timestamp >= ? AND timestamp < ?
ORDER BY timestamp ASC
```
- **Table**: `chronicle_usage_events` (Postgres event storage)
- **WHERE columns**: `study_id`, `participant_id`, `timestamp`
- **Classification**: COLD -- researcher data export
- **Assessment**: This runs against the event storage Postgres database. A composite index on `(study_id, participant_id, timestamp)` is needed. **Verify this index exists on the event storage database.**

#### C2. Download Preprocessed Usage Events
```sql
SELECT ... FROM preprocessed_usage_events
WHERE study_id = ? AND participant_id = ANY(?) AND app_datetime_start >= ? AND app_datetime_start < ?
```
- **Table**: `preprocessed_usage_events` (Postgres event storage)
- **WHERE columns**: `study_id`, `participant_id`, `app_datetime_start`
- **Classification**: COLD
- **Assessment**: Same concern as C1. Needs index on `(study_id, participant_id, app_datetime_start)`.

#### C3. Download App Usage Survey Data
```sql
SELECT ... FROM app_usage_survey
WHERE study_id = ? AND participant_id = ANY(?) AND timestamp >= ? AND timestamp < ?
```
- **Table**: `app_usage_survey`
- **WHERE columns**: `study_id`, `participant_id`, `timestamp`
- **Index**: **NO INDEX DEFINED** in `ChroniclePostgresTables.kt`
- **Classification**: COLD
- **Assessment**: **MISSING INDEX**. The `app_usage_survey` table has a primary key on `(app_package_name, app_package_name, timestamp)` -- note the **duplicate column bug** in the PK definition. This PK does not cover the download query's WHERE clause at all.
- **RECOMMENDATION**: Fix the PK to `(study_id, participant_id, app_package_name, timestamp)` and add index on `(study_id, participant_id, timestamp)`.

#### C4. Download Android Sensor Data
```sql
SELECT ... FROM android_sensor_data
WHERE study_id = ? AND participant_id = ANY(?) AND sample_timestamp >= ? AND sample_timestamp < ?
ORDER BY sample_timestamp ASC
```
- **Table**: `android_sensor_data`
- **WHERE columns**: `study_id`, `participant_id`, `sample_timestamp`
- **Index**: Index on (`study_id`, `participant_id`, `sample_timestamp`) -- COVERED
- **Classification**: COLD
- **Assessment**: Optimal. Composite index matches the query perfectly with sort order.

#### C5. Download iOS Sensor Data
```sql
SELECT ... FROM ios_sensor_data
WHERE study_id = ? AND participant_id = ANY(?) AND sensor_type = ANY(?) AND recorded_date_time >= ? AND recorded_date_time < ?
ORDER BY recorded_date_time ASC
```
- **Table**: `ios_sensor_data` (Postgres event storage)
- **WHERE columns**: `study_id`, `participant_id`, `sensor_type`, `recorded_date_time`
- **Classification**: COLD
- **Assessment**: Needs index on `(study_id, participant_id, sensor_type, recorded_date_time)` on event storage. **Verify on target database.**

#### C6. Download Questionnaire Submissions
```sql
SELECT participant_id, question_title, completed_at, responses
FROM questionnaire_submissions
WHERE study_id = ? AND questionnaire_id = ?
```
- **Table**: `questionnaire_submissions`
- **WHERE columns**: `study_id`, `questionnaire_id`
- **Index**: PRIMARY KEY is `(submission_id, question_title)` -- **DOES NOT COVER** this query
- **Classification**: COLD
- **Assessment**: **MISSING INDEX on `(study_id, questionnaire_id)`**. Full table scan for each download.
- **RECOMMENDATION**: Add index on `(study_id, questionnaire_id)`.

---

### ENROLLMENT PATH

#### E1. Count Study Participants (isKnownParticipant)
```sql
SELECT count(*) FROM study_participants WHERE study_id = ? AND participant_id = ?
```
- **Table**: `study_participants`
- **Index**: PRIMARY KEY (`study_id`, `participant_id`) -- COVERED
- **Classification**: WARM -- enrollment only
- **Assessment**: Optimal.

#### E2. Insert Device
```sql
INSERT INTO DEVICES (...) VALUES (?,?,?,?,?,?::jsonb,?)
ON CONFLICT (study_id, participant_id, source_device_id) DO UPDATE SET device_token = EXCLUDED.device_token
```
- **Table**: `DEVICES`
- **Index**: UNIQUE index on (`study_id`, `participant_id`, `source_device_id`) -- COVERED
- **Classification**: WARM
- **Assessment**: Optimal. Upsert on unique index.

#### E3. Get Device Types
```sql
SELECT DISTINCT study_id, participant_id, array_agg(distinct device_type)
FROM DEVICES
WHERE study_id = ANY(?) AND participant_id = ANY(?)
GROUP BY study_id, participant_id
```
- **Table**: `DEVICES`
- **WHERE columns**: `study_id`, `participant_id`
- **Index**: Unique index on (`study_id`, `participant_id`, `source_device_id`) can serve as prefix index -- PARTIALLY COVERED
- **Classification**: COLD -- admin/dashboard query
- **Assessment**: Acceptable. The unique index prefix covers the filter.

#### E4. Get Organization ID for Study
```sql
SELECT organization_id FROM organization_studies WHERE study_id = ? LIMIT 1
```
- **Table**: `organization_studies`
- **WHERE columns**: `study_id`
- **Index**: PRIMARY KEY is (`organization_id`, `study_id`). Index on `organization_id` exists.
- **Classification**: WARM
- **Assessment**: **SUBOPTIMAL**. The PK is `(organization_id, study_id)`, so a lookup by `study_id` alone requires a scan or the separate `organization_id` index (which does not help). **MISSING INDEX on `study_id`**.
- **RECOMMENDATION**: Add index on `organization_studies(study_id)`.

---

## Missing Index Summary

| Priority | Table | Missing Index | Affected Query | Impact |
|----------|-------|--------------|----------------|--------|
| HIGH | `upload_buffer` | `(upload_type, study_id, participant_id)` | W1 (getMoveSql) | Background task scans without type filter |
| HIGH | `app_usage_survey` | `(study_id, participant_id, timestamp)` | C3 | Full scan on download; also fix duplicate PK bug |
| HIGH | `questionnaire_submissions` | `(study_id, questionnaire_id)` | C6 | Full scan on download |
| MEDIUM | `organization_studies` | `(study_id)` | E4 | PK is (org_id, study_id), lookup by study_id alone |
| LOW | Event storage tables | Verify composite indexes exist | C1, C2, C5 | Applies to the Postgres event storage deployment |

## Bugs Found

### `app_usage_survey` Duplicate PK Column
In `ChroniclePostgresTables.kt`:
```kotlin
.primaryKey(PostgresEventColumns.APP_PACKAGE_NAME, PostgresEventColumns.APP_PACKAGE_NAME, PostgresEventColumns.TIMESTAMP)
```
`APP_PACKAGE_NAME` is listed twice. This should likely be:
```kotlin
.primaryKey(STUDY_ID, PARTICIPANT_ID, PostgresEventColumns.APP_PACKAGE_NAME, PostgresEventColumns.TIMESTAMP)
```

---

## N+1 Query Patterns

### Upload Hot Path: 3 Queries Before Write
Each usage event upload executes:
1. `getParticipationStatus()` -- 1 query
2. `isKnownDatasource()` -- 1 query
3. `INSERT INTO upload_buffer` -- 1 query
4. `insertOrUpdateParticipantStats()` -- 1 upsert (via Hazelcast)

Total: **4 database round-trips per upload request**.

**Recommendation**: Consider caching participation status and device enrollment in an in-memory cache (Hazelcast already present) with short TTL (e.g., 60s). This would reduce the hot path to 2 DB round-trips (INSERT + stats upsert). At 1000 devices, this saves ~2000 unnecessary SELECTs per upload cycle.

### MoveAndroidSensorDataToStorageTask: PreparedStatement per Row
In `MoveAndroidSensorDataToStorageTask.moveToStorage()`, a new `PreparedStatement` is created inside the `while (rs.next())` loop for each upload_buffer row. Each row may contain hundreds of sensor samples batched with `addBatch()`, which is good -- but the PS allocation per outer row is wasteful.

**Recommendation**: Move `prepareStatement(INSERT_ANDROID_SENSOR_DATA_SQL)` outside the result set loop and reuse it across all rows.

---

## Recommended EXPLAIN ANALYZE Commands

Run these against the production database to validate index usage and identify actual bottlenecks.

### Hot path queries (run during peak traffic)

```sql
-- H1: Participation status lookup
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT participation_status FROM study_participants
WHERE study_id = '<sample-study-uuid>' AND participant_id = '<sample-participant>';

-- H2: Device check
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT count(*) FROM "DEVICES"
WHERE study_id = '<sample-study-uuid>'
  AND participant_id = '<sample-participant>'
  AND source_device_id = '<sample-device>';

-- H3: Upload buffer insert timing (check for lock contention)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
INSERT INTO upload_buffer (study_id, participant_id, upload_data, uploaded_at, upload_type)
VALUES ('<uuid>', 'test', '[]'::jsonb, now(), 'Android');
-- Then: DELETE FROM upload_buffer WHERE study_id = '<uuid>' AND participant_id = 'test';
```

### Background task queries

```sql
-- W1: Move SQL subquery (check if upload_type filter causes seq scan)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT study_id, participant_id
FROM upload_buffer
WHERE upload_type = 'Android'
ORDER BY study_id, participant_id
FOR UPDATE SKIP LOCKED
LIMIT 128;
```

### Cold path queries (run before large exports)

```sql
-- C3: App usage survey (likely missing index)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM app_usage_survey
WHERE study_id = '<uuid>'
  AND participant_id = ANY(ARRAY['p1', 'p2'])
  AND timestamp >= '2026-01-01'
  AND timestamp < '2026-04-01';

-- C4: Android sensor data download
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM android_sensor_data
WHERE study_id = '<uuid>'
  AND participant_id = ANY(ARRAY['p1'])
  AND sample_timestamp >= '2026-01-01'
  AND sample_timestamp < '2026-04-01'
ORDER BY sample_timestamp ASC;

-- C6: Questionnaire submissions (likely missing index)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT participant_id, question_title, completed_at, responses
FROM questionnaire_submissions
WHERE study_id = '<uuid>' AND questionnaire_id = '<questionnaire-uuid>';
```

### Table size check (run periodically)

```sql
-- Upload buffer should stay small; if it grows, the move task is falling behind
SELECT count(*), pg_size_pretty(pg_total_relation_size('upload_buffer')) AS size
FROM upload_buffer;

-- Check for upload_buffer bloat by type
SELECT upload_type, count(*), min(uploaded_at), max(uploaded_at)
FROM upload_buffer
GROUP BY upload_type;

-- Sensor data growth rate
SELECT pg_size_pretty(pg_total_relation_size('android_sensor_data')) AS size,
       count(*) AS rows
FROM android_sensor_data;
```

---

## Load Test Correlation

When running `tests/load/chronicle-load-test.js` at 1000 VUs, monitor:

1. **Connection pool**: `SELECT count(*) FROM pg_stat_activity WHERE datname = 'chronicle';`
2. **Lock contention**: `SELECT * FROM pg_locks WHERE NOT granted;`
3. **Upload buffer drain**: Watch buffer size growth vs. drain rate
4. **Slow queries**: `SELECT * FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 20;`
