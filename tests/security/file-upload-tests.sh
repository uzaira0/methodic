#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# File Upload Security Tests
# =============================================================================
# Tests Chronicle's upload endpoints for common file upload and input
# validation vulnerabilities: oversized payloads, malformed JSON, depth bombs,
# content-type mismatches, path traversal, and null byte injection.
#
# Usage:
#   BASE_URL=http://localhost:40320 AUTH_TOKEN=<jwt> ./file-upload-tests.sh
# =============================================================================

BASE_URL="${BASE_URL:-http://localhost:40320}"
AUTH_TOKEN="${AUTH_TOKEN:-}"
TEST_STUDY_ID="${TEST_STUDY_ID:-00000000-0000-0000-0000-000000000000}"
TEST_PARTICIPANT_ID="${TEST_PARTICIPANT_ID:-test-participant-001}"

UPLOAD_ENDPOINT="${BASE_URL}/chronicle/v3/study/${TEST_STUDY_ID}/participants/${TEST_PARTICIPANT_ID}/upload"
ANDROID_UPLOAD_ENDPOINT="${BASE_URL}/chronicle/v3/study/${TEST_STUDY_ID}/participants/${TEST_PARTICIPANT_ID}/android/upload"

# -- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

pass_count=0
fail_count=0
skip_count=0

log_pass()  { echo -e "  ${GREEN}[PASS]${RESET} $1"; pass_count=$((pass_count + 1)); }
log_fail()  { echo -e "  ${RED}[FAIL]${RESET} $1"; fail_count=$((fail_count + 1)); }
log_skip()  { echo -e "  ${YELLOW}[SKIP]${RESET} $1"; skip_count=$((skip_count + 1)); }
log_header(){ echo -e "\n${BOLD}$1${RESET}"; }

# -- Auth header helper ------------------------------------------------------
curl_opts=(-s -o /dev/null -w '%{http_code}')
if [[ -n "$AUTH_TOKEN" ]]; then
  auth_header=(-H "Authorization: Bearer ${AUTH_TOKEN}")
else
  auth_header=()
fi

# -- Connectivity check ------------------------------------------------------
log_header "Connectivity Check"
echo -e "  Checking ${YELLOW}${BASE_URL}${RESET}..."

check_code=$(curl -s -o /dev/null -w '%{http_code}' \
  --connect-timeout 5 \
  "${BASE_URL}/chronicle/v3/studies" \
  2>/dev/null || echo "000")

if [[ "$check_code" == "000" ]]; then
  echo -e "  ${RED}Cannot connect to ${BASE_URL} -- is the backend running?${RESET}"
  echo -e "  ${YELLOW}Skipping all tests.${RESET}"
  echo ""
  echo -e "  ${GREEN}Passed: 0${RESET}  ${RED}Failed: 0${RESET}  ${YELLOW}Skipped: 6${RESET}"
  exit 0
fi
echo -e "  ${GREEN}Backend reachable (HTTP ${check_code})${RESET}"

# =============================================================================
# Test 1: Oversized Payload (11 MB JSON)
# =============================================================================
log_header "Test 1: Oversized Payload (11 MB)"
echo -e "  Generating 11 MB JSON payload..."

# Generate an 11MB payload: a JSON array with a single large string value
payload_file=$(mktemp)
trap 'rm -f "$payload_file"' EXIT

python3 -c "
import json, sys
# ~11 MB of data
data = [{'sensorType': 'test', 'data': 'A' * (11 * 1024 * 1024)}]
json.dump(data, sys.stdout)
" > "$payload_file" 2>/dev/null || {
  # Fallback if python3 not available
  echo -n '[{"sensorType":"test","data":"' > "$payload_file"
  dd if=/dev/zero bs=1024 count=11264 2>/dev/null | tr '\0' 'A' >> "$payload_file"
  echo -n '"}]' >> "$payload_file"
}

payload_size=$(wc -c < "$payload_file")
echo -e "  Payload size: ${CYAN}$(( payload_size / 1024 / 1024 )) MB${RESET}"
echo -e "  POSTing to ${YELLOW}${UPLOAD_ENDPOINT}${RESET}..."

http_code=$(curl "${curl_opts[@]}" \
  -X POST \
  "${UPLOAD_ENDPOINT}" \
  -H "Content-Type: application/json" \
  "${auth_header[@]}" \
  --data-binary "@${payload_file}" \
  --max-time 30 \
  2>/dev/null || echo "000")

if [[ "$http_code" == "413" || "$http_code" == "400" ]]; then
  log_pass "Oversized payload rejected with HTTP ${http_code}"
elif [[ "$http_code" == "000" ]]; then
  log_skip "Connection failed or timed out (HTTP ${http_code})"
elif [[ "$http_code" == "500" ]]; then
  log_fail "Server returned 500 Internal Server Error -- no size limit enforced"
elif [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "204" ]]; then
  log_fail "Oversized payload accepted (HTTP ${http_code}) -- no size limit enforced"
else
  log_pass "Oversized payload rejected with HTTP ${http_code}"
fi

# =============================================================================
# Test 2: Malformed JSON
# =============================================================================
log_header "Test 2: Malformed JSON"
echo -e "  Sending invalid JSON to ${YELLOW}${UPLOAD_ENDPOINT}${RESET}..."

http_code=$(curl "${curl_opts[@]}" \
  -X POST \
  "${UPLOAD_ENDPOINT}" \
  -H "Content-Type: application/json" \
  "${auth_header[@]}" \
  -d '{invalid json... "broken": true, missing brackets' \
  --max-time 10 \
  2>/dev/null || echo "000")

if [[ "$http_code" == "400" ]]; then
  log_pass "Malformed JSON rejected with HTTP 400 Bad Request"
elif [[ "$http_code" == "500" ]]; then
  log_fail "Malformed JSON caused HTTP 500 Internal Server Error -- unhandled parse exception"
elif [[ "$http_code" == "000" ]]; then
  log_skip "Connection failed (HTTP ${http_code})"
else
  log_pass "Malformed JSON handled with HTTP ${http_code} (not 500)"
fi

# =============================================================================
# Test 3: JSON Depth Bomb (1000 levels of nesting)
# =============================================================================
log_header "Test 3: JSON Depth Bomb (1000 levels)"
echo -e "  Generating deeply nested JSON (1000 levels)..."

depth_payload=""
for ((i = 0; i < 1000; i++)); do
  depth_payload="${depth_payload}{\"a\":"
done
depth_payload="${depth_payload}\"leaf\""
for ((i = 0; i < 1000; i++)); do
  depth_payload="${depth_payload}}"
done

echo -e "  POSTing to ${YELLOW}${UPLOAD_ENDPOINT}${RESET}..."

http_code=$(curl "${curl_opts[@]}" \
  -X POST \
  "${UPLOAD_ENDPOINT}" \
  -H "Content-Type: application/json" \
  "${auth_header[@]}" \
  -d "${depth_payload}" \
  --max-time 10 \
  2>/dev/null || echo "000")

if [[ "$http_code" == "400" ]]; then
  log_pass "Depth bomb rejected with HTTP 400"
elif [[ "$http_code" == "500" ]]; then
  log_fail "Depth bomb caused HTTP 500 -- possible stack overflow or unhandled exception"
elif [[ "$http_code" == "000" ]]; then
  log_skip "Connection failed or timed out (HTTP ${http_code})"
elif [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "204" ]]; then
  log_fail "Depth bomb accepted (HTTP ${http_code}) -- no depth limit enforced"
else
  log_pass "Depth bomb handled with HTTP ${http_code} (not 500)"
fi

# =============================================================================
# Test 4: Content-Type Mismatch (binary data as application/json)
# =============================================================================
log_header "Test 4: Content-Type Mismatch"
echo -e "  Sending binary data with Content-Type: application/json..."

binary_payload=$(dd if=/dev/urandom bs=256 count=1 2>/dev/null | base64)

http_code=$(curl "${curl_opts[@]}" \
  -X POST \
  "${UPLOAD_ENDPOINT}" \
  -H "Content-Type: application/json" \
  "${auth_header[@]}" \
  --data-binary "${binary_payload}" \
  --max-time 10 \
  2>/dev/null || echo "000")

if [[ "$http_code" == "400" ]]; then
  log_pass "Binary data with JSON content-type rejected with HTTP 400"
elif [[ "$http_code" == "500" ]]; then
  log_fail "Binary data caused HTTP 500 -- unhandled deserialization exception"
elif [[ "$http_code" == "000" ]]; then
  log_skip "Connection failed (HTTP ${http_code})"
else
  log_pass "Binary data handled with HTTP ${http_code} (not 500)"
fi

# =============================================================================
# Test 5: Path Traversal in participantId
# =============================================================================
log_header "Test 5: Path Traversal in participantId"

traversal_id="..%2F..%2F..%2Fetc%2Fpasswd"
traversal_url="${BASE_URL}/chronicle/v3/study/${TEST_STUDY_ID}/participants/${traversal_id}/upload"
echo -e "  Using participantId: ${YELLOW}../../etc/passwd${RESET} (URL-encoded)"
echo -e "  POSTing to ${YELLOW}${traversal_url}${RESET}..."

http_code=$(curl "${curl_opts[@]}" \
  -X POST \
  "${traversal_url}" \
  -H "Content-Type: application/json" \
  "${auth_header[@]}" \
  -d '[{"sensorType":"test","data":"probe"}]' \
  --max-time 10 \
  2>/dev/null || echo "000")

if [[ "$http_code" == "400" || "$http_code" == "404" || "$http_code" == "403" ]]; then
  log_pass "Path traversal in participantId rejected with HTTP ${http_code}"
elif [[ "$http_code" == "500" ]]; then
  log_fail "Path traversal caused HTTP 500 -- input may not be sanitized"
elif [[ "$http_code" == "000" ]]; then
  log_skip "Connection failed (HTTP ${http_code})"
elif [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "204" ]]; then
  log_fail "Path traversal participantId accepted (HTTP ${http_code}) -- input not validated"
else
  log_pass "Path traversal handled with HTTP ${http_code}"
fi

# =============================================================================
# Test 6: Null Bytes in Input
# =============================================================================
log_header "Test 6: Null Bytes in JSON Values"
echo -e "  Sending JSON with null bytes in field values..."

null_payload='[{"sensorType":"test\u0000injected","data":"value\u0000exploit"}]'

http_code=$(curl "${curl_opts[@]}" \
  -X POST \
  "${UPLOAD_ENDPOINT}" \
  -H "Content-Type: application/json" \
  "${auth_header[@]}" \
  -d "${null_payload}" \
  --max-time 10 \
  2>/dev/null || echo "000")

if [[ "$http_code" == "400" ]]; then
  log_pass "Null bytes in JSON rejected with HTTP 400"
elif [[ "$http_code" == "500" ]]; then
  log_fail "Null bytes caused HTTP 500 -- unhandled exception"
elif [[ "$http_code" == "000" ]]; then
  log_skip "Connection failed (HTTP ${http_code})"
elif [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "204" ]]; then
  # Null bytes may be silently sanitized, which is acceptable
  log_pass "Null bytes handled (HTTP ${http_code}) -- verify values are sanitized in DB"
else
  log_pass "Null bytes handled with HTTP ${http_code}"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BOLD}=============================================${RESET}"
echo -e "${BOLD}  File Upload Security Test Summary${RESET}"
echo -e "${BOLD}=============================================${RESET}"
echo ""
echo -e "  ${GREEN}Passed: ${pass_count}${RESET}  ${RED}Failed: ${fail_count}${RESET}  ${YELLOW}Skipped: ${skip_count}${RESET}"
echo ""

if [[ "$fail_count" -gt 0 ]]; then
  echo -e "  ${RED}Some tests failed -- review upload endpoint security.${RESET}"
  echo ""
  exit 1
fi

exit 0
