#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ANDROID_DIR="$ROOT_DIR/chronicle"
APP_DIR="$ANDROID_DIR/app"
REPORT_DIR="${1:-$ROOT_DIR/tests/security/reports}"
REQUIRE_SIGNING_SECRET="${CHRONICLE_REQUIRE_MOBILE_SIGNING_SECRET:-1}"

mkdir -p "$REPORT_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

require_file_contains() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if ! grep -Eq "$pattern" "$file"; then
    fail "$description"
  fi
  pass "$description"
}

echo "=== Chronicle mobile upload guardrails ==="

if find "$APP_DIR/libs" -type f -name '*.jar' 2>/dev/null | grep -q .; then
  find "$APP_DIR/libs" -type f -name '*.jar' >&2
  fail "Android app/libs must not contain local jars; they can shadow local chronicle-models changes"
fi
pass "No Android app/libs jar shadowing"

if grep -Eq "implementation[[:space:]]+fileTree\\([^)]*libs" "$APP_DIR/build.gradle"; then
  fail "Android build must not use implementation fileTree(dir: 'libs')"
fi
pass "Android build does not depend on app/libs fileTree"

require_file_contains "$APP_DIR/build.gradle" "readDockerEnvValue\\('MOBILE_SIGNING_SECRET'\\)" \
  "Debug builds can read MOBILE_SIGNING_SECRET from docker/.env"
require_file_contains "$APP_DIR/build.gradle" "com\\.openlattice:chronicle-models:0\\.1\\.0-SNAPSHOT" \
  "Android app uses local chronicle-models snapshot"

secret_available=0
if [[ -n "${MOBILE_SIGNING_SECRET:-}" ]]; then
  secret_available=1
elif [[ -f "$ROOT_DIR/docker/.env" ]] && grep -Eq '^MOBILE_SIGNING_SECRET=.{16,}' "$ROOT_DIR/docker/.env"; then
  secret_available=1
fi

if [[ "$REQUIRE_SIGNING_SECRET" == "1" && "$secret_available" != "1" ]]; then
  fail "MOBILE_SIGNING_SECRET is required for BCM debug/dogfood builds"
fi

if [[ "${CHRONICLE_SKIP_ANDROID_BUILD:-0}" != "1" ]]; then
  (
    cd "$ANDROID_DIR"
    ./gradlew :app:generateDebugBuildConfig --quiet
  )

  build_config="$(find "$APP_DIR/build/generated" -path '*/com/openlattice/chronicle/BuildConfig.*' -type f | head -n 1)"
  [[ -n "$build_config" ]] || fail "Generated BuildConfig was not found"

  if [[ "$REQUIRE_SIGNING_SECRET" == "1" ]]; then
    if grep -Eq 'MOBILE_SIGNING_SECRET = ""' "$build_config"; then
      fail "Generated BuildConfig has an empty MOBILE_SIGNING_SECRET"
    fi
    pass "Generated BuildConfig has non-empty MOBILE_SIGNING_SECRET"
  fi
fi

# Phase 10 split the usage collector into the :collection-usage Gradle module.
require_file_contains "$ANDROID_DIR/collection-usage/src/main/java/com/openlattice/chronicle/sensors/UsageEventsChronicleSensor.kt" \
  "activityClass[[:space:]]*=[[:space:]]*it\\.className" \
  "UsageEvents collector preserves Android activity class"
require_file_contains "$APP_DIR/src/main/java/com/openlattice/chronicle/services/upload/UploadExecutor.kt" \
  "datum\\.activityClass" \
  "Upload mapper forwards activity class to ChronicleUsageEvent"
require_file_contains "$ROOT_DIR/chronicle-models/src/main/kotlin/com/openlattice/chronicle/android/ChronicleUsageEvent.kt" \
  "activityClass" \
  "Shared ChronicleUsageEvent DTO contains activityClass"
require_file_contains "$ROOT_DIR/chronicle-server/src/main/resources/db/migration/V22__add_usage_event_activity_class.sql" \
  "activity_class" \
  "Postgres migration adds activity_class"

bash -n "$ROOT_DIR/scripts/android-auto-upload-e2e.sh"
pass "Android auto-upload E2E script parses"

echo "Mobile upload guardrails complete. Reports directory: $REPORT_DIR"
