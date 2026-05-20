#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUDY_ID="${CHRONICLE_STUDY_ID:-54a6a4ea-ae90-483f-bbdb-0d9113fe40ca}"
PARTICIPANT_ID="${CHRONICLE_PARTICIPANT_ID:-}"
POSTGRES_CONTAINER="${CHRONICLE_POSTGRES_CONTAINER:-chronicle-postgres}"
POSTGRES_USER="${POSTGRES_USER:-}"
POSTGRES_DB="${POSTGRES_DB:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"

usage() {
  cat <<'EOF'
Usage: scripts/chronicle-dogfood-report.sh [options]

Prints a local Postgres dogfood report for one Chronicle participant: device
inventory, upload queues, usage rows, ActivityClass coverage, sensor data,
sensor availability, upload lag, and future timestamp skew.

Options:
  --study-id UUID         study UUID
  --participant-id ID     participant ID
  -h, --help              show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --study-id) STUDY_ID="${2:?missing --study-id value}"; shift 2 ;;
    --participant-id) PARTICIPANT_ID="${2:?missing --participant-id value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -f "$ROOT_DIR/docker/.env" ]]; then
  [[ -n "$POSTGRES_USER" ]] || POSTGRES_USER="$(awk -F= '/^POSTGRES_USER=/{print substr($0,index($0,"=")+1)}' "$ROOT_DIR/docker/.env")"
  [[ -n "$POSTGRES_DB" ]] || POSTGRES_DB="$(awk -F= '/^POSTGRES_DB=/{print substr($0,index($0,"=")+1)}' "$ROOT_DIR/docker/.env")"
  [[ -n "$POSTGRES_PASSWORD" ]] || POSTGRES_PASSWORD="$(awk -F= '/^POSTGRES_PASSWORD=/{print substr($0,index($0,"=")+1)}' "$ROOT_DIR/docker/.env")"
fi

if [[ -z "$PARTICIPANT_ID" && -f /tmp/chronicle-tablet-upload-test-ids.txt ]]; then
  PARTICIPANT_ID="$(sed -n '1p' /tmp/chronicle-tablet-upload-test-ids.txt)"
fi

[[ -n "$PARTICIPANT_ID" ]] || { echo "Missing participant id." >&2; exit 1; }
[[ -n "$POSTGRES_USER" && -n "$POSTGRES_DB" && -n "$POSTGRES_PASSWORD" ]] || {
  echo "Missing Postgres credentials. Provide docker/.env or env vars." >&2
  exit 1
}

psql_report() {
  docker exec -i \
    -e "PGPASSWORD=$POSTGRES_PASSWORD" \
    "$POSTGRES_CONTAINER" \
    psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      -v ON_ERROR_STOP=1 \
      -v study_id="$STUDY_ID" \
      -v participant_id="$PARTICIPANT_ID" \
      -P pager=off \
      "$@"
}

echo "Chronicle dogfood report"
echo "study_id=$STUDY_ID"
echo "participant_id=$PARTICIPANT_ID"
echo "generated_at=$(date -Is)"
echo

psql_report <<'SQL'
\echo '== Device Inventory =='
SELECT
  device_id,
  device_type,
  source_device_id,
  source_device ->> 'manufacturer' AS manufacturer,
  source_device ->> 'model' AS model,
  source_device ->> 'os' AS os,
  source_device ->> 'osVersion' AS os_version
FROM devices
WHERE study_id = :'study_id'::uuid
  AND participant_id = :'participant_id'
ORDER BY device_id;

\echo '== Upload Buffer =='
SELECT
  upload_type,
  count(*) AS batches,
  coalesce(sum(jsonb_array_length(data)), 0) AS buffered_items,
  min(uploaded_at) AS oldest_buffered_at,
  max(uploaded_at) AS newest_buffered_at
FROM upload_buffer
WHERE study_id = :'study_id'::uuid
  AND participant_id = :'participant_id'
GROUP BY upload_type
ORDER BY upload_type;

\echo '== Usage Events Summary =='
SELECT
  count(*) AS total_usage_rows,
  count(activity_class) AS rows_with_activity_class,
  round(100.0 * count(activity_class) / nullif(count(*), 0), 1) AS pct_with_activity_class,
  min(event_timestamp) AS first_event_at,
  max(event_timestamp) AS latest_event_at,
  max(uploaded_at) AS latest_uploaded_at,
  round(avg(extract(epoch FROM uploaded_at - event_timestamp))::numeric, 1) AS avg_upload_lag_seconds,
  round(max(extract(epoch FROM uploaded_at - event_timestamp))::numeric, 1) AS max_upload_lag_seconds,
  count(*) FILTER (WHERE event_timestamp > uploaded_at + interval '5 minutes') AS future_skew_rows
FROM chronicle_usage_events
WHERE study_id = :'study_id'
  AND participant_id = :'participant_id';

\echo '== ActivityClass Coverage By App =='
SELECT
  app_package_name,
  count(*) AS total_rows,
  count(activity_class) AS rows_with_activity_class,
  round(100.0 * count(activity_class) / nullif(count(*), 0), 1) AS pct_with_activity_class
FROM chronicle_usage_events
WHERE study_id = :'study_id'
  AND participant_id = :'participant_id'
GROUP BY app_package_name
ORDER BY total_rows DESC, app_package_name
LIMIT 25;

\echo '== Top Activity Classes =='
SELECT
  app_package_name,
  activity_class,
  count(*) AS rows
FROM chronicle_usage_events
WHERE study_id = :'study_id'
  AND participant_id = :'participant_id'
  AND activity_class IS NOT NULL
GROUP BY app_package_name, activity_class
ORDER BY rows DESC, app_package_name, activity_class
LIMIT 25;

\echo '== Sensor Data Summary =='
SELECT
  count(*) AS total_sensor_rows,
  count(DISTINCT sensor_type) AS sensor_type_count,
  min(sample_timestamp) AS first_sample_at,
  max(sample_timestamp) AS latest_sample_at,
  count(*) FILTER (WHERE sample_timestamp > now() + interval '5 minutes') AS future_skew_rows
FROM android_sensor_data
WHERE study_id = :'study_id'::uuid
  AND participant_id = :'participant_id';

\echo '== Sensor Data By Type =='
SELECT
  sensor_type,
  count(*) AS rows,
  min(sample_timestamp) AS first_sample_at,
  max(sample_timestamp) AS latest_sample_at
FROM android_sensor_data
WHERE study_id = :'study_id'::uuid
  AND participant_id = :'participant_id'
GROUP BY sensor_type
ORDER BY rows DESC, sensor_type;

\echo '== Sensor Availability =='
SELECT
  device_id,
  source_device_id,
  reported_at,
  array_length(available_sensors, 1) AS available_count,
  available_sensors,
  unavailable_sensors
FROM android_device_sensor_availability
WHERE study_id = :'study_id'::uuid
  AND participant_id = :'participant_id'
ORDER BY reported_at DESC;
SQL
