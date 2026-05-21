#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_DIR="${1:-$ROOT_DIR/tests/security/reports}"
mkdir -p "$REPORT_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

scripts=(
  "$ROOT_DIR/scripts/android-auto-upload-e2e.sh"
  "$ROOT_DIR/scripts/android-battery-drain-harness.sh"
  "$ROOT_DIR/scripts/android-debug-bundle.sh"
  "$ROOT_DIR/scripts/chronicle-dogfood-report.sh"
  "$ROOT_DIR/scripts/chronicle-long-run-dogfood.sh"
  "$ROOT_DIR/scripts/chronicle-set-android-sensors.sh"
)

for script in "${scripts[@]}"; do
  [[ -f "$script" ]] || fail "Missing dogfood script: $script"
  bash -n "$script"
  pass "$(basename "$script") parses"
done

DOGFOOD_REPORT="$ROOT_DIR/scripts/chronicle-dogfood-report.sh"
BATTERY_HARNESS="$ROOT_DIR/scripts/android-battery-drain-harness.sh"
LONG_RUN="$ROOT_DIR/scripts/chronicle-long-run-dogfood.sh"
DEBUG_BUNDLE="$ROOT_DIR/scripts/android-debug-bundle.sh"

# --- Debug bundle: must redact app secrets ----------------------------------
# The debug bundle must not dump app shared preferences, datastore, or any
# mobile API secret. The only allowed secret-adjacent token is the Postgres
# password as an environment-variable reference, never an echoed literal.
if grep -REn "shared_prefs|datastore|app_prefs|apiKey|api_key|MOBILE_SIGNING_SECRET|POSTGRES_PASSWORD" \
  "$DEBUG_BUNDLE" \
  | grep -v "POSTGRES_PASSWORD" >/dev/null; then
  fail "debug bundle must not dump app prefs/datastore or mobile API secrets"
fi
pass "debug bundle avoids known app secret sources"

# --- Dogfood report: ActivityClass coverage ---------------------------------
grep -q "activity_class" "$DOGFOOD_REPORT" \
  || fail "dogfood report must include ActivityClass coverage"
grep -q "Top Missing-ActivityClass Packages" "$DOGFOOD_REPORT" \
  || fail "dogfood report must report top missing-activityClass packages"
pass "dogfood report includes ActivityClass coverage and missing-class packages"

# --- Dogfood report: full sensor inventory ----------------------------------
# The report must cover the full modeled-sensor inventory, not just observed
# sensor types. The matrix cross-joins every AndroidSensorType against the
# latest reported availability.
grep -q "Sensor Availability Matrix" "$DOGFOOD_REPORT" \
  || fail "dogfood report must include the modeled sensor availability matrix"
for modeled_sensor in accelerometer gyroscope magnetometer stepCounter \
  light proximity significantMotion tiltDetector samsungGripWifi samsungMotion; do
  grep -q "$modeled_sensor" "$DOGFOOD_REPORT" \
    || fail "dogfood report sensor matrix is missing modeled sensor: $modeled_sensor"
done
pass "dogfood report includes the full modeled sensor inventory"

# --- Dogfood report: lifecycle coverage -------------------------------------
grep -q "Device Lifecycle Events" "$DOGFOOD_REPORT" \
  || fail "dogfood report must include device lifecycle event counts"
grep -q "shutdown_startup" "$DOGFOOD_REPORT" \
  || fail "dogfood report must categorize shutdown/startup lifecycle events"
pass "dogfood report includes device lifecycle coverage"

# --- Dogfood report: duplicate/replay not_tracked marker --------------------
grep -q "duplicate_upload_count_not_tracked=true" "$DOGFOOD_REPORT" \
  || fail "dogfood report must emit a not_tracked marker for duplicate/replay counts"
pass "dogfood report emits duplicate/replay not_tracked marker"

# --- Dogfood report: clock skew ---------------------------------------------
grep -q "future_skew_rows" "$DOGFOOD_REPORT" \
  || fail "dogfood report must include clock skew checks"
pass "dogfood report includes clock skew checks"

# --- Dogfood report: must not print API keys or signing secret --------------
# No line may echo an API key or the mobile signing secret. The Postgres
# password is permitted only as a PGPASSWORD env-var reference passed to
# docker exec, never as an echoed value.
if grep -REn "echo.*(apiKey|api_key|MOBILE_SIGNING_SECRET)" "$DOGFOOD_REPORT" >/dev/null; then
  fail "dogfood report must not print API keys or the mobile signing secret"
fi
if grep -REn '\becho\b[^|]*\$POSTGRES_PASSWORD' "$DOGFOOD_REPORT" >/dev/null; then
  fail "dogfood report must not print the Postgres password"
fi
pass "dogfood report does not print API keys or secrets"

# --- Battery harness: reject charging tests by default ----------------------
grep -q "Device is charging" "$BATTERY_HARNESS" \
  || fail "battery harness must fail plugged-in drain tests by default"
pass "battery harness blocks invalid charging drain tests"

# --- Battery harness: wake-lock / sensor / service stats --------------------
grep -q "dumpsys power" "$BATTERY_HARNESS" \
  || fail "battery harness must capture wake-lock state (dumpsys power)"
grep -q "dumpsys sensorservice" "$BATTERY_HARNESS" \
  || fail "battery harness must capture sensor state (dumpsys sensorservice)"
grep -q "dumpsys activity services" "$BATTERY_HARNESS" \
  || fail "battery harness must capture foreground-service state"
grep -q "process_uptime" "$BATTERY_HARNESS" \
  || fail "battery harness must capture app process uptime"
pass "battery harness captures wake-lock, sensor, service and uptime stats"

# --- Long-run script: final upload counts -----------------------------------
grep -q "upload-counts-final.txt" "$LONG_RUN" \
  || fail "long-run script must write a final upload-counts artifact"
grep -q "report-final.txt" "$LONG_RUN" \
  || fail "long-run script must collect a final dogfood report"
pass "long-run script collects final upload counts"

# --- Long-run script: run profiles ------------------------------------------
for profile in 2h 8h 24h offline reconnect power-save low-battery; do
  grep -q "$profile)" "$LONG_RUN" \
    || fail "long-run script is missing the '$profile' run profile"
done
pass "long-run script defines all required run profiles"

# --- Long-run script: restores device state on exit -------------------------
grep -q "trap restore_device_state EXIT" "$LONG_RUN" \
  || fail "long-run script must restore device state on exit"
pass "long-run script restores device state on exit"

grep -q "pm\\.isPowerSaveMode" "$ROOT_DIR/chronicle/app/src/main/java/com/openlattice/chronicle/services/sensors/HardwareSensorService.kt" \
  || fail "hardware sensor collection must keep original Methodic Battery Saver degraded mode"
if grep -q "BATTERY_DEGRADED_THRESHOLD" "$ROOT_DIR/chronicle/app/src/main/java/com/openlattice/chronicle/services/sensors/HardwareSensorService.kt"; then
  fail "hardware sensor collection must not add a separate low-battery degraded threshold"
fi
pass "hardware sensor collection stays close to original Methodic degraded-mode behavior"

grep -q "AndroidSensorType\\.values()" "$ROOT_DIR/chronicle/app/src/main/java/com/openlattice/chronicle/services/sensors/SensorAvailabilityReporter.kt" \
  || fail "sensor availability reporter must report full Chronicle-modeled sensor inventory"
pass "sensor availability reporter records full modeled inventory"

grep -q "Allowed sensors" "$ROOT_DIR/scripts/chronicle-set-android-sensors.sh" \
  || fail "sensor settings script must document allowed sensors"
grep -q "samsungGripWifi" "$ROOT_DIR/scripts/chronicle-set-android-sensors.sh" \
  || fail "sensor settings script must include explicitly modeled Samsung/private sensors"
pass "sensor settings script documents selective enablement"

echo "Dogfood tooling guardrails complete. Reports directory: $REPORT_DIR"
