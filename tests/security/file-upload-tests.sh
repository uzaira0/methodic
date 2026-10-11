#!/usr/bin/env bash
set -euo pipefail

# File Upload Security Tests
# Use a disposable, enrolled fixture with sensor collection enabled.
# Supply BASE_URL, API_KEY, TEST_STUDY_ID, TEST_PARTICIPANT_ID and TEST_DEVICE_ID.
# The shipped self-host signing defaults apply; authentication failures fail the control.
BASE_URL="${BASE_URL:-http://localhost:40320}"
: "${API_KEY:?Set API_KEY to the enrollment-issued fixture API key}"
: "${TEST_STUDY_ID:?Set TEST_STUDY_ID to the enrolled fixture study}"
: "${TEST_PARTICIPANT_ID:?Set TEST_PARTICIPANT_ID to the enrolled fixture participant}"
: "${TEST_DEVICE_ID:?Set TEST_DEVICE_ID to the enrolled fixture device}"

UPLOAD_BASE="${BASE_URL%/}/chronicle/v4/study/${TEST_STUDY_ID}/participant"
UPLOAD_ENDPOINT="${UPLOAD_BASE}/${TEST_PARTICIPANT_ID}/android/sensors"
bad_request=400
payload_too_large=413
forbidden=403
transport_error='transport-error'
pass_count=0
fail_count=0

log_pass() { printf '  [PASS] %s\n' "$1"; pass_count=$((pass_count + 1)); }
log_fail() { printf '  [FAIL] %s\n' "$1"; fail_count=$((fail_count + 1)); }
log_header() { printf '\n%s\n' "$1"; }

# All probes use the same enrolled-device authentication and bounded transport.
post_upload() {
  local url="$1"
  shift
  local transport=()
  [[ -z "${UPLOAD_CONNECT_TO:-}" ]] || transport+=(--connect-to "$UPLOAD_CONNECT_TO")
  curl "${transport[@]}" -sS -o /dev/null -w '%{http_code}' --path-as-is \
    --connect-timeout 5 --max-time 30 -X POST "$url" \
    -H 'Content-Type: application/json' \
    -H "X-Api-Key: ${API_KEY}" -H "X-Chronicle-Device-Id: ${TEST_DEVICE_ID}" "$@"
}

expect_rejection() {
  local label="$1" code="$2" expected
  shift 2
  for expected in "$@"; do
    if [[ "$code" == "$expected" ]]; then
      log_pass "$label rejected with HTTP $code"
      return
    fi
  done
  log_fail "$label returned unexpected HTTP $code"
}

log_header "Valid Upload Control"
# An empty batch passes through the real handler and its enrolled-device gate.
control_code=$(post_upload "$UPLOAD_ENDPOINT" --data-binary '[]') || {
  log_fail "Valid upload control could not connect"
  exit 1
}
if [[ "$control_code" != 200 ]]; then
  log_fail "Valid upload control returned HTTP $control_code; verify route, enrollment and credentials"
  exit 1
fi
log_pass "Valid upload control reached the sensor upload handler"

payload_file=$(mktemp)
trap 'rm -f "$payload_file"' EXIT

# Test 1: Oversized Payload (11 MB JSON)
log_header "Test 1: Oversized Payload (11 MB)"
# Valid JSON padding isolates the size limit from schema validation.
python3 -c 'import sys; sys.stdout.write("[" + " " * (11 * 1024 * 1024) + "]")' >"$payload_file"
http_code=$(post_upload "$UPLOAD_ENDPOINT" --data-binary "@${payload_file}") || http_code=$transport_error
expect_rejection "Oversized payload" "$http_code" "$payload_too_large"

# Test 2: Malformed JSON
log_header "Test 2: Malformed JSON"
http_code=$(post_upload "$UPLOAD_ENDPOINT" --data-binary '{invalid json... "broken": true, missing brackets') || http_code=$transport_error
expect_rejection "Malformed JSON" "$http_code" "$bad_request"

# Test 3: JSON Depth Bomb (1000 levels of nesting)
log_header "Test 3: JSON Depth Bomb (1000 levels)"
python3 -c 'import sys; sys.stdout.write("{\"a\":" * 1000 + "\"leaf\"" + "}" * 1000)' >"$payload_file"
http_code=$(post_upload "$UPLOAD_ENDPOINT" --data-binary "@${payload_file}") || http_code=$transport_error
expect_rejection "Depth bomb" "$http_code" "$bad_request"

# Test 4: Content-Type Mismatch (binary data as application/json)
log_header "Test 4: Content-Type Mismatch"
dd if=/dev/urandom bs=256 count=1 >"$payload_file" 2>/dev/null
http_code=$(post_upload "$UPLOAD_ENDPOINT" --data-binary "@${payload_file}") || http_code=$transport_error
expect_rejection "Binary data with JSON content-type" "$http_code" "$bad_request"

# Test 5: Path Traversal in participantId
log_header "Test 5: Path Traversal in participantId"
traversal_id="..%2F..%2F..%2Fetc%2Fpasswd"
http_code=$(post_upload "${UPLOAD_BASE}/${traversal_id}/android/sensors" --data-binary '[]') || http_code=$transport_error
expect_rejection "Path traversal in participantId" "$http_code" "$bad_request" "$forbidden"

# Test 6: Null Bytes in Input
log_header "Test 6: Null Bytes in JSON Values"
null_payload='[{"id":"00000000-0000-0000-0000-000000000001","timestamp":"2026-10-07T00:00:00Z","timezone":"UTC","sensor":"accelerometer\u0000injected","x":1.0}]'
http_code=$(post_upload "$UPLOAD_ENDPOINT" --data-binary "$null_payload") || http_code=$transport_error
expect_rejection "Null bytes in sensor type" "$http_code" "$bad_request"

log_header "File Upload Security Test Summary"
printf '  Passed: %s  Failed: %s\n' "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
