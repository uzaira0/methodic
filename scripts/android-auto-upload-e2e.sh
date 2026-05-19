#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB_BIN="${ADB:-adb}"
SERIAL="${ANDROID_SERIAL:-}"
PACKAGE="${CHRONICLE_ANDROID_PACKAGE:-com.openlattice.chronicle.bcmtest.debug}"
MAIN_ACTIVITY="${CHRONICLE_ANDROID_MAIN_ACTIVITY:-com.openlattice.chronicle.MainActivity}"
STUDY_ID="${CHRONICLE_STUDY_ID:-54a6a4ea-ae90-483f-bbdb-0d9113fe40ca}"
PARTICIPANT_ID="${CHRONICLE_PARTICIPANT_ID:-}"
POSTGRES_CONTAINER="${CHRONICLE_POSTGRES_CONTAINER:-chronicle-postgres}"
POSTGRES_USER="${POSTGRES_USER:-}"
POSTGRES_DB="${POSTGRES_DB:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
TIMEOUT_SECONDS="${CHRONICLE_AUTO_UPLOAD_TIMEOUT_SECONDS:-2700}"
POLL_SECONDS="${CHRONICLE_AUTO_UPLOAD_POLL_SECONDS:-30}"
APP_SECONDS="${CHRONICLE_AUTO_UPLOAD_APP_SECONDS:-8}"
REQUIRE_FINAL_STORAGE=1
LOG_DIR="${CHRONICLE_AUTO_UPLOAD_LOG_DIR:-/tmp}"
EXTRA_APPS="${CHRONICLE_AUTO_UPLOAD_APPS:-}"

usage() {
  cat <<'EOF'
Usage: scripts/android-auto-upload-e2e.sh [options]

Drives a connected Android tablet through a few apps, then waits for Chronicle's
periodic automatic upload to happen. This script does not press Upload Now.

Options:
  --serial SERIAL              adb device serial, e.g. 10.51.179.137:38748
  --package PACKAGE            Android app id (default: com.openlattice.chronicle.bcmtest.debug)
  --study-id UUID              Chronicle study UUID
  --participant-id ID          enrolled participant id to verify in Postgres
  --timeout SECONDS            max wait for auto upload (default: 2700)
  --poll SECONDS               DB polling interval (default: 30)
  --app-seconds SECONDS        foreground time per app (default: 8)
  --apps CSV                   additional app packages to try via monkey
  --accept-buffer              pass when backend upload_buffer grows, even before final mover
  --log-dir DIR                directory for logcat/UI artifacts (default: /tmp)
  -h, --help                   show this help

Environment overrides use the same names shown in the script constants, for
example CHRONICLE_PARTICIPANT_ID or CHRONICLE_AUTO_UPLOAD_TIMEOUT_SECONDS.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      SERIAL="${2:?missing --serial value}"
      shift 2
      ;;
    --package)
      PACKAGE="${2:?missing --package value}"
      shift 2
      ;;
    --study-id)
      STUDY_ID="${2:?missing --study-id value}"
      shift 2
      ;;
    --participant-id)
      PARTICIPANT_ID="${2:?missing --participant-id value}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:?missing --timeout value}"
      shift 2
      ;;
    --poll)
      POLL_SECONDS="${2:?missing --poll value}"
      shift 2
      ;;
    --app-seconds)
      APP_SECONDS="${2:?missing --app-seconds value}"
      shift 2
      ;;
    --apps)
      EXTRA_APPS="${2:?missing --apps value}"
      shift 2
      ;;
    --accept-buffer)
      REQUIRE_FINAL_STORAGE=0
      shift
      ;;
    --log-dir)
      LOG_DIR="${2:?missing --log-dir value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -f "$ROOT_DIR/docker/.env" ]]; then
  if [[ -z "$POSTGRES_USER" ]]; then
    POSTGRES_USER="$(awk -F= '/^POSTGRES_USER=/{print substr($0,index($0,"=")+1)}' "$ROOT_DIR/docker/.env")"
  fi
  if [[ -z "$POSTGRES_DB" ]]; then
    POSTGRES_DB="$(awk -F= '/^POSTGRES_DB=/{print substr($0,index($0,"=")+1)}' "$ROOT_DIR/docker/.env")"
  fi
  if [[ -z "$POSTGRES_PASSWORD" ]]; then
    POSTGRES_PASSWORD="$(awk -F= '/^POSTGRES_PASSWORD=/{print substr($0,index($0,"=")+1)}' "$ROOT_DIR/docker/.env")"
  fi
fi

if [[ -z "$PARTICIPANT_ID" && -f /tmp/chronicle-tablet-upload-test-ids.txt ]]; then
  PARTICIPANT_ID="$(sed -n '1p' /tmp/chronicle-tablet-upload-test-ids.txt)"
fi

if [[ -z "$SERIAL" ]]; then
  SERIAL="$("$ADB_BIN" devices | awk 'NR > 1 && $2 == "device" {print $1; exit}')"
fi

if [[ -z "$SERIAL" ]]; then
  echo "No adb device found. Pass --serial or connect a tablet." >&2
  exit 1
fi

if [[ -z "$PARTICIPANT_ID" ]]; then
  echo "Missing participant id. Pass --participant-id or set CHRONICLE_PARTICIPANT_ID." >&2
  exit 1
fi

if [[ -z "$POSTGRES_USER" || -z "$POSTGRES_DB" || -z "$POSTGRES_PASSWORD" ]]; then
  echo "Missing Postgres credentials. Provide docker/.env or POSTGRES_USER/POSTGRES_DB/POSTGRES_PASSWORD." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOGCAT_FILE="$LOG_DIR/chronicle-auto-upload-$RUN_ID-logcat.txt"
UI_FILE="$LOG_DIR/chronicle-auto-upload-$RUN_ID-ui.xml"

adb_shell() {
  "$ADB_BIN" -s "$SERIAL" shell "$@"
}

psql_scalar() {
  local sql="$1"
  docker exec \
    -e "PGPASSWORD=$POSTGRES_PASSWORD" \
    "$POSTGRES_CONTAINER" \
    psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "$sql"
}

usage_events_count() {
  psql_scalar "select count(*) from chronicle_usage_events where study_id='$STUDY_ID' and participant_id='$PARTICIPANT_ID';"
}

buffer_count() {
  psql_scalar "select count(*) from upload_buffer where study_id='$STUDY_ID' and participant_id='$PARTICIPANT_ID';"
}

package_installed() {
  local package_name="$1"
  adb_shell pm list packages "$package_name" | grep -qx "package:$package_name"
}

launch_package_if_present() {
  local package_name="$1"
  if package_installed "$package_name"; then
    echo "Launching $package_name"
    if ! adb_shell monkey -p "$package_name" -c android.intent.category.LAUNCHER 1 >/dev/null; then
      echo "Warning: failed to launch $package_name; continuing." >&2
      return 0
    fi
    sleep "$APP_SECONDS"
    adb_shell input keyevent 3 || true
    sleep 2
  else
    echo "Skipping missing package $package_name"
  fi
}

launch_action() {
  local label="$1"
  local action="$2"
  echo "Launching $label"
  if ! adb_shell am start -W -a "$action" >/dev/null; then
    echo "Warning: failed to launch $label via $action; continuing." >&2
    return 0
  fi
  sleep "$APP_SECONDS"
  adb_shell input keyevent 3 || true
  sleep 2
}

echo "Chronicle Android auto-upload E2E"
echo "serial=$SERIAL"
echo "package=$PACKAGE"
echo "study_id=$STUDY_ID"
echo "participant_id=$PARTICIPANT_ID"
echo "timeout_seconds=$TIMEOUT_SECONDS poll_seconds=$POLL_SECONDS"
echo "logcat=$LOGCAT_FILE"

"$ADB_BIN" -s "$SERIAL" get-state >/dev/null

if ! package_installed "$PACKAGE"; then
  echo "Package $PACKAGE is not installed on $SERIAL." >&2
  exit 1
fi

device_rows="$(psql_scalar "select count(*) from devices where study_id='$STUDY_ID' and participant_id='$PARTICIPANT_ID';")"
api_key_rows="$(psql_scalar "select count(*) from api_keys where study_id='$STUDY_ID' and participant_id='$PARTICIPANT_ID' and not revoked;")"
if [[ "$device_rows" == "0" || "$api_key_rows" == "0" ]]; then
  echo "Participant is not fully enrolled in backend: devices=$device_rows active_api_keys=$api_key_rows" >&2
  exit 1
fi

echo "Granting usage-stats app-op if shell is permitted."
adb_shell appops set "$PACKAGE" GET_USAGE_STATS allow || true
adb_shell appops get "$PACKAGE" GET_USAGE_STATS || true

before_events="$(usage_events_count)"
before_buffer="$(buffer_count)"
echo "Before: final_events=$before_events upload_buffer_rows=$before_buffer"

"$ADB_BIN" -s "$SERIAL" logcat -c

echo "Launching Chronicle once to ensure periodic WorkManager jobs are scheduled."
if ! adb_shell am start -W -n "$PACKAGE/$MAIN_ACTIVITY" >/dev/null; then
  echo "Warning: failed to launch Chronicle; continuing with app-usage generation." >&2
fi
sleep "$APP_SECONDS"

echo "Generating foreground usage events."
launch_action "Android Settings" "android.settings.SETTINGS"
launch_package_if_present "com.android.chrome"
launch_package_if_present "com.sec.android.gallery3d"
launch_package_if_present "com.google.android.youtube"
launch_package_if_present "com.android.vending"

if [[ -n "$EXTRA_APPS" ]]; then
  IFS=',' read -r -a extra_apps_array <<< "$EXTRA_APPS"
  for app_package in "${extra_apps_array[@]}"; do
    app_package="${app_package//[[:space:]]/}"
    if [[ -n "$app_package" ]]; then
      launch_package_if_present "$app_package"
    fi
  done
fi

echo "Returning to Chronicle, then waiting for automatic periodic upload."
if ! adb_shell am start -W -n "$PACKAGE/$MAIN_ACTIVITY" >/dev/null; then
  echo "Warning: failed to return to Chronicle before wait; continuing." >&2
fi
sleep 3

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
observed_buffer=0
while (( $(date +%s) <= deadline )); do
  current_events="$(usage_events_count)"
  current_buffer="$(buffer_count)"
  now="$(date -Is)"
  echo "[$now] final_events=$current_events upload_buffer_rows=$current_buffer"

  if (( current_events > before_events )); then
    echo "PASS: automatic upload reached final storage."
    "$ADB_BIN" -s "$SERIAL" logcat -d > "$LOGCAT_FILE"
    "$ADB_BIN" -s "$SERIAL" exec-out uiautomator dump /dev/tty > "$UI_FILE" || true
    echo "Artifacts: $LOGCAT_FILE $UI_FILE"
    exit 0
  fi

  if (( current_buffer > before_buffer )); then
    observed_buffer=1
    if (( REQUIRE_FINAL_STORAGE == 0 )); then
      echo "PASS: automatic upload reached backend upload_buffer."
      "$ADB_BIN" -s "$SERIAL" logcat -d > "$LOGCAT_FILE"
      "$ADB_BIN" -s "$SERIAL" exec-out uiautomator dump /dev/tty > "$UI_FILE" || true
      echo "Artifacts: $LOGCAT_FILE $UI_FILE"
      exit 0
    fi
  fi

  sleep "$POLL_SECONDS"
done

"$ADB_BIN" -s "$SERIAL" logcat -d > "$LOGCAT_FILE"
"$ADB_BIN" -s "$SERIAL" exec-out uiautomator dump /dev/tty > "$UI_FILE" || true

if (( observed_buffer == 1 )); then
  echo "FAIL: automatic upload reached upload_buffer, but did not reach final storage before timeout." >&2
else
  echo "FAIL: no automatic upload observed before timeout." >&2
fi
echo "Artifacts: $LOGCAT_FILE $UI_FILE" >&2
exit 1
