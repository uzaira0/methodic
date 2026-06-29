#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUDY_ID="${CHRONICLE_STUDY_ID:-54a6a4ea-ae90-483f-bbdb-0d9113fe40ca}"
SENSORS=""
SAMPLING_RATE_HZ=""
DUTY_ACTIVE_SECONDS=""
DUTY_PERIOD_SECONDS=""
POSTGRES_CONTAINER="${CHRONICLE_POSTGRES_CONTAINER:-chronicle-postgres}"
POSTGRES_USER="${POSTGRES_USER:-}"
POSTGRES_DB="${POSTGRES_DB:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
SHOW_ONLY=0

usage() {
  cat <<'EOF'
Usage: scripts/chronicle-set-android-sensors.sh [options]

Shows or updates the local Postgres AndroidSensor study setting. This controls
which already-modeled raw hardware sensors the mobile app collects. It does not
derive screen/unlock sessions and does not collect notification content.

Options:
  --study-id UUID               study UUID
  --sensors CSV                 sensors to enable, e.g. accelerometer,light
  --sampling-rate-hz N          optional sampling rate override
  --duty-active-seconds N       optional active collection window override
  --duty-period-seconds N       optional duty-cycle period override
  --show                        show current setting and latest availability only
  -h, --help                    show help

Allowed sensors:
  accelerometer, gyroscope, magnetometer, gravity, linearAcceleration,
  rotationVector, stepCounter, light, proximity, significantMotion,
  tiltDetector, screenOrientation, samsungGripWifi, samsungMotion
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --study-id) STUDY_ID="${2:?missing --study-id value}"; shift 2 ;;
    --sensors) SENSORS="${2:?missing --sensors value}"; shift 2 ;;
    --sampling-rate-hz) SAMPLING_RATE_HZ="${2:?missing --sampling-rate-hz value}"; shift 2 ;;
    --duty-active-seconds) DUTY_ACTIVE_SECONDS="${2:?missing --duty-active-seconds value}"; shift 2 ;;
    --duty-period-seconds) DUTY_PERIOD_SECONDS="${2:?missing --duty-period-seconds value}"; shift 2 ;;
    --show) SHOW_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -f "$ROOT_DIR/docker/.env" ]]; then
  [[ -n "$POSTGRES_USER" ]] || POSTGRES_USER="$(awk -F= '/^POSTGRES_USER=/{print substr($0,index($0,"=")+1)}' "$ROOT_DIR/docker/.env")"
  [[ -n "$POSTGRES_DB" ]] || POSTGRES_DB="$(awk -F= '/^POSTGRES_DB=/{print substr($0,index($0,"=")+1)}' "$ROOT_DIR/docker/.env")"
  [[ -n "$POSTGRES_PASSWORD" ]] || POSTGRES_PASSWORD="$(awk -F= '/^POSTGRES_PASSWORD=/{print substr($0,index($0,"=")+1)}' "$ROOT_DIR/docker/.env")"
fi

[[ -n "$POSTGRES_USER" && -n "$POSTGRES_DB" && -n "$POSTGRES_PASSWORD" ]] || {
  echo "Missing Postgres credentials. Provide docker/.env or env vars." >&2
  exit 1
}

psql_cmd() {
  docker exec -i \
    -e "PGPASSWORD=$POSTGRES_PASSWORD" \
    "$POSTGRES_CONTAINER" \
    psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      -v ON_ERROR_STOP=1 \
      -v study_id="$STUDY_ID" \
      -P pager=off \
      "$@"
}

show_state() {
  psql_cmd <<'SQL'
\echo '== Current AndroidSensor Setting =='
SELECT jsonb_pretty(settings -> 'AndroidSensor') AS android_sensor_setting
FROM studies
WHERE study_id = :'study_id'::uuid;

\echo '== Latest Reported Sensor Availability =='
SELECT
  participant_id,
  reported_at,
  available_sensors,
  unavailable_sensors
FROM android_device_sensor_availability
WHERE study_id = :'study_id'::uuid
ORDER BY reported_at DESC
LIMIT 20;
SQL
}

if [[ "$SHOW_ONLY" == "1" ]]; then
  show_state
  exit 0
fi

[[ -n "$SENSORS" ]] || {
  echo "Missing --sensors. Use --show to inspect current state." >&2
  exit 1
}

setting_json="$(
  python3 - "$SENSORS" "$SAMPLING_RATE_HZ" "$DUTY_ACTIVE_SECONDS" "$DUTY_PERIOD_SECONDS" <<'PY'
import json
import sys

allowed = {
    "accelerometer",
    "gyroscope",
    "magnetometer",
    "gravity",
    "linearAcceleration",
    "rotationVector",
    "stepCounter",
    "light",
    "proximity",
    "significantMotion",
    "tiltDetector",
    "screenOrientation",
    "samsungGripWifi",
    "samsungMotion",
}

sensors = [s.strip() for s in sys.argv[1].split(",") if s.strip()]
invalid = [s for s in sensors if s not in allowed]
if invalid:
    raise SystemExit(f"Invalid sensors: {', '.join(invalid)}")

def int_or_default(value, default):
    return int(value) if value else default

print(json.dumps({
    "@class": "com.openlattice.chronicle.android.AndroidSensorSetting",
    "sensors": sensors,
    "samplingRateHz": int_or_default(sys.argv[2], 1),
    "dutyCycleActiveSeconds": int_or_default(sys.argv[3], 10),
    "dutyCyclePeriodSeconds": int_or_default(sys.argv[4], 120),
}, separators=(",", ":")))
PY
)"

echo "Updating AndroidSensor setting for study $STUDY_ID"
echo "$setting_json"

docker exec -i \
  -e "PGPASSWORD=$POSTGRES_PASSWORD" \
  "$POSTGRES_CONTAINER" \
  psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 \
    -v study_id="$STUDY_ID" \
    -v setting_json="$setting_json" <<'SQL'
UPDATE studies
SET settings = jsonb_set(coalesce(settings, '{}'::jsonb), '{AndroidSensor}', :'setting_json'::jsonb, true),
    updated_at = now()
WHERE study_id = :'study_id'::uuid;
SQL

show_state
