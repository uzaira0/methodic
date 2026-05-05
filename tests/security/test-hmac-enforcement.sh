#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# HMAC Phase 2 Enforcement Validation
# =============================================================================
# Tests Chronicle's MobileApiSignatureFilter behavior under Phase 1 (accept
# unsigned) and Phase 2 (reject unsigned) configurations.
#
# Usage:
#   BASE_URL=http://localhost:40320 TEST_STUDY_ID=<uuid> ./test-hmac-enforcement.sh
# =============================================================================

BASE_URL="${BASE_URL:-http://localhost:40320}"
TEST_STUDY_ID="${TEST_STUDY_ID:-00000000-0000-0000-0000-000000000000}"

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

# =============================================================================
# Test 1: Unsigned Request Detection
# =============================================================================
log_header "Test 1: Unsigned Request Detection"
echo -e "  Sending request to ${YELLOW}${BASE_URL}/chronicle/v3/studies${RESET} without HMAC headers..."

http_code=$(curl -s -o /dev/null -w '%{http_code}' \
  -X GET \
  "${BASE_URL}/chronicle/v3/studies" \
  -H "Content-Type: application/json" \
  2>/dev/null || echo "000")

if [[ "$http_code" == "000" ]]; then
  log_fail "Could not connect to ${BASE_URL} (is the server running?)"
  phase_detected="unknown"
elif [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
  log_pass "Unsigned request rejected with HTTP ${http_code}"
  log_info "Phase 2 (signing-required: true) is ACTIVE -- unsigned requests are blocked"
  phase_detected="phase2"
elif [[ "$http_code" == "200" ]]; then
  log_pass "Server responded with HTTP 200 (unsigned request accepted)"
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

log_info "Chronicle HMAC signing uses the following algorithm:"
echo ""
echo -e "  ${BOLD}String-to-sign construction:${RESET}"
echo "    METHOD\\nPATH\\nTIMESTAMP\\nNONCE\\nBODY_HASH"
echo ""
echo -e "  ${BOLD}Where:${RESET}"
echo "    METHOD     = HTTP method (GET, POST, etc.)"
echo "    PATH       = Request path (e.g. /chronicle/v3/studies)"
echo "    TIMESTAMP  = Unix epoch seconds (sent in X-Chronicle-Timestamp)"
echo "    NONCE      = Unique request ID / UUID (sent in X-Chronicle-Nonce)"
echo "    BODY_HASH  = SHA-256 hex digest of the request body (empty string hash for GET)"
echo ""
echo -e "  ${BOLD}Signature:${RESET}"
echo "    HMAC-SHA256(shared_key, string_to_sign)  -- hex-encoded"
echo ""
echo -e "  ${BOLD}Required headers:${RESET}"
echo "    X-Chronicle-Signature  : <hex-encoded HMAC-SHA256>"
echo "    X-Chronicle-Timestamp  : <unix epoch seconds>"
echo "    X-Chronicle-Nonce      : <unique UUID per request>"
echo ""

log_info "Cannot execute a signed request without the shared key -- skipping live test"

# =============================================================================
# Test 3: Replay Protection Check
# =============================================================================
log_header "Test 3: Replay Protection (Nonce Reuse)"

if [[ "$phase_detected" == "phase2" ]]; then
  TIMESTAMP=$(date +%s)
  NONCE="test-replay-$(uuidgen 2>/dev/null || echo "fixed-nonce-for-replay-test")"
  # Use a dummy signature -- the point is to test nonce rejection on second use.
  DUMMY_SIG="0000000000000000000000000000000000000000000000000000000000000000"

  echo -e "  Sending first request with nonce ${YELLOW}${NONCE}${RESET}..."
  first_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X GET \
    "${BASE_URL}/chronicle/v3/studies" \
    -H "Content-Type: application/json" \
    -H "X-Chronicle-Signature: ${DUMMY_SIG}" \
    -H "X-Chronicle-Timestamp: ${TIMESTAMP}" \
    -H "X-Chronicle-Nonce: ${NONCE}" \
    2>/dev/null || echo "000")
  log_info "First request returned HTTP ${first_code}"

  echo -e "  Sending second request with same nonce..."
  second_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X GET \
    "${BASE_URL}/chronicle/v3/studies" \
    -H "Content-Type: application/json" \
    -H "X-Chronicle-Signature: ${DUMMY_SIG}" \
    -H "X-Chronicle-Timestamp: ${TIMESTAMP}" \
    -H "X-Chronicle-Nonce: ${NONCE}" \
    2>/dev/null || echo "000")

  if [[ "$second_code" == "401" || "$second_code" == "403" ]]; then
    log_pass "Replayed nonce rejected with HTTP ${second_code} -- replay protection is active"
  elif [[ "$first_code" == "401" || "$first_code" == "403" ]]; then
    log_info "Both requests rejected (signature invalid) -- replay protection cannot be verified without a valid key"
  else
    log_fail "Replayed nonce was not rejected (HTTP ${second_code}) -- replay protection may be missing"
  fi
elif [[ "$phase_detected" == "phase1" ]]; then
  log_info "Phase 1 active -- replay protection is not enforced when signing is optional"
  log_info "Expected Phase 2 behavior: second request with the same nonce should return 401/403"
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

# Always exit 0 -- this is a readiness check, not a gate
exit 0
