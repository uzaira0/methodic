#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# HMAC Phase 2 Enforcement Validation
# =============================================================================
# Tests Chronicle's MobileApiSignatureFilter behavior under Phase 1 (accept
# unsigned) and Phase 2 (reject unsigned) configurations.
#
# Usage:
#   BASE_URL=http://10.23.4.137 TEST_STUDY_ID=<uuid> ./test-hmac-enforcement.sh
#   MOBILE_SIGNING_SECRET=<secret> ./test-hmac-enforcement.sh
# =============================================================================

BASE_URL="${BASE_URL:-http://10.23.4.137}"
HOST_HEADER="${HOST_HEADER:-}"
TEST_STUDY_ID="${TEST_STUDY_ID:-00000000-0000-0000-0000-000000000000}"
TEST_PARTICIPANT_ID="${TEST_PARTICIPANT_ID:-hmac-smoke-participant}"
TEST_DEVICE_ID="${TEST_DEVICE_ID:-hmac-smoke-device}"
STRICT="${HMAC_STRICT:-0}"
MOBILE_PATH="/chronicle/v4/study/${TEST_STUDY_ID}/participant/${TEST_PARTICIPANT_ID}/enroll"
MOBILE_BODY='{}'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT=1
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# -- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

pass_count=0
fail_count=0
info_count=0
phase_detected=""

log_pass()  { echo -e "  ${GREEN}[PASS]${RESET} $1"; pass_count=$((pass_count + 1)); }
log_fail()  { echo -e "  ${RED}[FAIL]${RESET} $1"; fail_count=$((fail_count + 1)); }
log_info()  { echo -e "  ${CYAN}[INFO]${RESET} $1"; info_count=$((info_count + 1)); }
log_header(){ echo -e "\n${BOLD}$1${RESET}"; }

curl_host_args=()
if [[ -n "$HOST_HEADER" ]]; then
  curl_host_args=(-H "Host: ${HOST_HEADER}")
fi

# =============================================================================
# Test 1: Unsigned Request Detection
# =============================================================================
log_header "Test 1: Unsigned Request Detection"
echo -e "  Sending request to ${YELLOW}${BASE_URL}${MOBILE_PATH}${RESET} without HMAC headers..."

http_code=$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST \
  "${BASE_URL}${MOBILE_PATH}" \
  "${curl_host_args[@]}" \
  -H "Content-Type: application/json" \
  -H "X-Chronicle-Device-Id: ${TEST_DEVICE_ID}" \
  --data "${MOBILE_BODY}" \
  2>/dev/null || echo "000")

if [[ "$http_code" == "000" ]]; then
  log_fail "Could not connect to ${BASE_URL} (is the server running?)"
  phase_detected="unknown"
elif [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
  log_pass "Unsigned request rejected with HTTP ${http_code}"
  log_info "Phase 2 (signing-required: true) is ACTIVE -- unsigned requests are blocked"
  phase_detected="phase2"
elif [[ "$http_code" == "200" || "$http_code" == "400" || "$http_code" == "409" || "$http_code" == "500" ]]; then
  log_pass "Unsigned request reached application code with HTTP ${http_code}"
  log_info "Phase 1 (signing-required: false) is active -- unsigned requests are allowed"
  phase_detected="phase1"
else
  log_info "Unexpected HTTP ${http_code} -- endpoint may require authentication independent of HMAC"
  phase_detected="unknown"
fi

# =============================================================================
# Test 2: Properly Signed Request (Informational / Documentation)
# =============================================================================
log_header "Test 2: HMAC Signing Algorithm (Informational)"

log_info "Chronicle signs METHOD|PATH|TIMESTAMP|NONCE|SHA256(BODY) with HMAC-SHA256 and Base64 encodes the result."

if [[ -n "${MOBILE_SIGNING_SECRET:-}" ]]; then
  TIMESTAMP=$(date +%s)
  NONCE="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
  BODY_HASH="$(printf '%s' "${MOBILE_BODY}" | sha256sum | awk '{print $1}')"
  STRING_TO_SIGN="POST|${MOBILE_PATH}|${TIMESTAMP}|${NONCE}|${BODY_HASH}"
  SIGNATURE="$(printf '%s' "${STRING_TO_SIGN}" | openssl dgst -sha256 -hmac "${MOBILE_SIGNING_SECRET}" -binary | openssl base64 -A)"

  signed_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST \
    "${BASE_URL}${MOBILE_PATH}" \
    "${curl_host_args[@]}" \
    -H "Content-Type: application/json" \
    -H "X-Chronicle-Device-Id: ${TEST_DEVICE_ID}" \
    -H "X-Chronicle-Signature: ${SIGNATURE}" \
    -H "X-Chronicle-Timestamp: ${TIMESTAMP}" \
    -H "X-Chronicle-Nonce: ${NONCE}" \
    --data "${MOBILE_BODY}" \
    2>/dev/null || echo "000")

  if [[ "$signed_code" == "401" || "$signed_code" == "403" ]]; then
    log_fail "Signed mobile request was rejected with HTTP ${signed_code}"
  elif [[ "$signed_code" == "000" ]]; then
    log_fail "Signed mobile request could not connect"
  else
    log_pass "Signed request passed HMAC validation and reached application code with HTTP ${signed_code}"
  fi
else
  log_info "MOBILE_SIGNING_SECRET not set -- skipping signed live request"
fi

# =============================================================================
# Test 3: Replay Protection Check
# =============================================================================
log_header "Test 3: Replay Protection (Nonce Reuse)"

if [[ "$phase_detected" == "phase2" && -n "${MOBILE_SIGNING_SECRET:-}" ]]; then
  TIMESTAMP=$(date +%s)
  NONCE="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
  BODY_HASH="$(printf '%s' "${MOBILE_BODY}" | sha256sum | awk '{print $1}')"
  SIGNATURE="$(printf '%s' "POST|${MOBILE_PATH}|${TIMESTAMP}|${NONCE}|${BODY_HASH}" | openssl dgst -sha256 -hmac "${MOBILE_SIGNING_SECRET}" -binary | openssl base64 -A)"

  echo -e "  Sending first request with nonce ${YELLOW}${NONCE}${RESET}..."
  first_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST \
    "${BASE_URL}${MOBILE_PATH}" \
    "${curl_host_args[@]}" \
    -H "Content-Type: application/json" \
    -H "X-Chronicle-Device-Id: ${TEST_DEVICE_ID}" \
    -H "X-Chronicle-Signature: ${SIGNATURE}" \
    -H "X-Chronicle-Timestamp: ${TIMESTAMP}" \
    -H "X-Chronicle-Nonce: ${NONCE}" \
    --data "${MOBILE_BODY}" \
    2>/dev/null || echo "000")
  log_info "First request returned HTTP ${first_code}"

  echo -e "  Sending second request with same nonce..."
  second_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST \
    "${BASE_URL}${MOBILE_PATH}" \
    "${curl_host_args[@]}" \
    -H "Content-Type: application/json" \
    -H "X-Chronicle-Device-Id: ${TEST_DEVICE_ID}" \
    -H "X-Chronicle-Signature: ${SIGNATURE}" \
    -H "X-Chronicle-Timestamp: ${TIMESTAMP}" \
    -H "X-Chronicle-Nonce: ${NONCE}" \
    --data "${MOBILE_BODY}" \
    2>/dev/null || echo "000")

  if [[ "$second_code" == "401" || "$second_code" == "403" ]]; then
    log_pass "Replayed nonce rejected with HTTP ${second_code} -- replay protection is active"
  else
    log_fail "Replayed nonce was not rejected (HTTP ${second_code}) -- replay protection may be missing"
  fi
elif [[ "$phase_detected" == "phase1" ]]; then
  log_info "Phase 1 active -- replay protection is not enforced when signing is optional"
  log_info "Expected Phase 2 behavior: second request with the same nonce should return 401/403"
elif [[ -z "${MOBILE_SIGNING_SECRET:-}" ]]; then
  log_info "MOBILE_SIGNING_SECRET not set -- replay protection cannot be verified with a valid signature"
else
  log_info "Phase detection inconclusive -- skipping replay test"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BOLD}=============================================${RESET}"
echo -e "${BOLD}  HMAC Enforcement Validation Summary${RESET}"
echo -e "${BOLD}=============================================${RESET}"
echo ""

case "$phase_detected" in
  phase1)
    echo -e "  Detected mode: ${YELLOW}Phase 1 (signing-required: false)${RESET}"
    echo -e "  HMAC headers are accepted but not required."
    echo -e "  To enforce Phase 2, set ${CYAN}signing-required: true${RESET} in the filter config."
    ;;
  phase2)
    echo -e "  Detected mode: ${GREEN}Phase 2 (signing-required: true)${RESET}"
    echo -e "  Unsigned requests are rejected. HMAC enforcement is active."
    ;;
  *)
    echo -e "  Detected mode: ${RED}Unknown${RESET}"
    echo -e "  Could not determine HMAC phase. Check server connectivity and endpoint availability."
    ;;
esac

echo ""
echo -e "  ${GREEN}Passed: ${pass_count}${RESET}  ${RED}Failed: ${fail_count}${RESET}  ${CYAN}Info: ${info_count}${RESET}"
echo ""

if [[ "$STRICT" == "1" ]]; then
  if [[ "$phase_detected" != "phase2" ]]; then
    echo "Strict mode requires Phase 2 HMAC enforcement." >&2
    exit 1
  fi
  if [[ "$fail_count" -gt 0 ]]; then
    echo "Strict mode failed: ${fail_count} HMAC check(s) failed." >&2
    exit 1
  fi
fi

# Default mode is a readiness check, not a gate.
exit 0
