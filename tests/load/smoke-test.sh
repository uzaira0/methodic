#!/usr/bin/env bash
set -euo pipefail

# Chronicle Load Smoke Test
#
# Quick curl-based test to verify endpoints work before running the full k6 suite.
#
# Required env vars:
#   BASE_URL   - Chronicle server URL (default: http://127.0.0.1:40320)
#   JWT_TOKEN  - Valid JWT token
#   STUDY_ID   - UUID of an existing study

BASE_URL="${BASE_URL:-http://127.0.0.1:40320}"
JWT_TOKEN="${JWT_TOKEN:?JWT_TOKEN env var is required}"
STUDY_ID="${STUDY_ID:?STUDY_ID env var is required}"

PARTICIPANT_ID="smoke-test-$(date +%s)"
SOURCE_DEVICE_ID="smoke-device-$(date +%s)"

CHRONICLE_V4="${BASE_URL}/chronicle/v4/study/${STUDY_ID}"

pass=0
fail=0

check() {
  local label="$1"
  local expected_status="$2"
  local actual_status="$3"

  if [ "$actual_status" -ge "$expected_status" ] && [ "$actual_status" -lt $((expected_status + 100)) ]; then
    echo "  PASS  ${label} (HTTP ${actual_status})"
    ((pass++))
  else
    echo "  FAIL  ${label} (expected ${expected_status}xx, got HTTP ${actual_status})"
    ((fail++))
  fi
}

echo "=== Chronicle Smoke Test ==="
echo "  Base URL:       ${BASE_URL}"
echo "  Study ID:       ${STUDY_ID}"
echo "  Participant ID: ${PARTICIPANT_ID}"
echo ""

# ---- 1. Verify study exists ----
echo "[1/4] Checking study exists..."
status=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  "${BASE_URL}/chronicle/v3/study/${STUDY_ID}")
check "GET study" 200 "$status"

# ---- 2. Enroll participant ----
echo "[2/4] Enrolling participant..."
DEVICE_JSON=$(cat <<EOJSON
{
  "deviceId": "${SOURCE_DEVICE_ID}",
  "model": "Pixel 7",
  "brand": "Google",
  "device": "panther",
  "product": "panther",
  "osVersion": "14",
  "sdkVersion": "34",
  "fcmRegistrationToken": "smoke-test-token"
}
EOJSON
)

enroll_start=$(date +%s%N)
status=$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${DEVICE_JSON}" \
  "${CHRONICLE_V4}/participant/${PARTICIPANT_ID}/enroll")
enroll_end=$(date +%s%N)
enroll_ms=$(( (enroll_end - enroll_start) / 1000000 ))
check "POST enroll (${enroll_ms}ms)" 200 "$status"

# ---- 3. Upload usage events ----
echo "[3/4] Uploading usage events (batch of 10)..."
EVENTS_JSON=$(cat <<'EOJSON'
[
  {"appPackageName":"com.android.chrome","interactionType":"Foreground","eventType":1,"timestamp":"2026-04-05T10:00:00.000Z","timezone":"America/New_York","user":"user0","applicationLabel":"Chrome"},
  {"appPackageName":"com.whatsapp","interactionType":"Background","eventType":2,"timestamp":"2026-04-05T10:01:00.000Z","timezone":"America/New_York","user":"user0","applicationLabel":"WhatsApp"},
  {"appPackageName":"com.instagram.android","interactionType":"Foreground","eventType":1,"timestamp":"2026-04-05T10:02:00.000Z","timezone":"America/New_York","user":"user0","applicationLabel":"Instagram"},
  {"appPackageName":"com.twitter.android","interactionType":"Foreground","eventType":1,"timestamp":"2026-04-05T10:03:00.000Z","timezone":"America/New_York","user":"user0","applicationLabel":"Twitter"},
  {"appPackageName":"com.spotify.music","interactionType":"Background","eventType":2,"timestamp":"2026-04-05T10:04:00.000Z","timezone":"America/New_York","user":"user0","applicationLabel":"Spotify"},
  {"appPackageName":"com.android.chrome","interactionType":"Foreground","eventType":1,"timestamp":"2026-04-05T10:05:00.000Z","timezone":"America/New_York","user":"user0","applicationLabel":"Chrome"},
  {"appPackageName":"com.whatsapp","interactionType":"Foreground","eventType":1,"timestamp":"2026-04-05T10:06:00.000Z","timezone":"America/New_York","user":"user0","applicationLabel":"WhatsApp"},
  {"appPackageName":"com.google.android.youtube","interactionType":"Foreground","eventType":1,"timestamp":"2026-04-05T10:07:00.000Z","timezone":"America/New_York","user":"user0","applicationLabel":"YouTube"},
  {"appPackageName":"com.snapchat.android","interactionType":"Background","eventType":2,"timestamp":"2026-04-05T10:08:00.000Z","timezone":"America/New_York","user":"user0","applicationLabel":"Snapchat"},
  {"appPackageName":"com.facebook.katana","interactionType":"Foreground","eventType":1,"timestamp":"2026-04-05T10:09:00.000Z","timezone":"America/New_York","user":"user0","applicationLabel":"Facebook"}
]
EOJSON
)

upload_start=$(date +%s%N)
status=$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${EVENTS_JSON}" \
  "${CHRONICLE_V4}/participant/${PARTICIPANT_ID}/android")
upload_end=$(date +%s%N)
upload_ms=$(( (upload_end - upload_start) / 1000000 ))
check "POST usage events (${upload_ms}ms)" 200 "$status"

# ---- 4. Upload sensor data ----
echo "[4/4] Uploading sensor data (batch of 5 samples)..."

# Generate a small sensor batch
SENSOR_JSON='['
for i in $(seq 1 5); do
  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")
  [ $i -gt 1 ] && SENSOR_JSON+=','
  SENSOR_JSON+=$(cat <<EOJSON
{
  "id": "${uuid}",
  "sensor": "ACCELEROMETER",
  "timestamp": "2026-04-05T10:00:0${i}.000Z",
  "timezone": "America/New_York",
  "x": ${i}.${i}23,
  "y": -${i}.456,
  "z": 9.81,
  "w": null,
  "accuracy": 3
}
EOJSON
)
done
SENSOR_JSON+=']'

sensor_start=$(date +%s%N)
status=$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${SENSOR_JSON}" \
  "${CHRONICLE_V4}/participant/${PARTICIPANT_ID}/android/sensors")
sensor_end=$(date +%s%N)
sensor_ms=$(( (sensor_end - sensor_start) / 1000000 ))
check "POST sensor data (${sensor_ms}ms)" 200 "$status"

# ---- Summary ----
echo ""
echo "=== Results ==="
echo "  Passed: ${pass}"
echo "  Failed: ${fail}"
echo ""

if [ "$fail" -gt 0 ]; then
  echo "SMOKE TEST FAILED - fix endpoint issues before running the full load test."
  exit 1
else
  echo "SMOKE TEST PASSED - safe to run: k6 run tests/load/chronicle-load-test.js"
  exit 0
fi
