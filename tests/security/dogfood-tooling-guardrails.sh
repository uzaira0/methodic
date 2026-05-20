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

if grep -REn "shared_prefs|apiKey|api_key|MOBILE_SIGNING_SECRET|POSTGRES_PASSWORD" \
  "$ROOT_DIR/scripts/android-debug-bundle.sh" \
  | grep -v "POSTGRES_PASSWORD" >/dev/null; then
  fail "debug bundle must not dump app prefs or mobile API secrets"
fi
pass "debug bundle avoids known app secret sources"

grep -q "activity_class" "$ROOT_DIR/scripts/chronicle-dogfood-report.sh" \
  || fail "dogfood report must include ActivityClass coverage"
pass "dogfood report includes ActivityClass coverage"

grep -q "future_skew_rows" "$ROOT_DIR/scripts/chronicle-dogfood-report.sh" \
  || fail "dogfood report must include clock skew checks"
pass "dogfood report includes clock skew checks"

grep -q "Device is charging" "$ROOT_DIR/scripts/android-battery-drain-harness.sh" \
  || fail "battery harness must fail plugged-in drain tests by default"
pass "battery harness blocks invalid charging drain tests"

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
