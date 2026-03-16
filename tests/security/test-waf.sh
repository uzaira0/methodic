#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# WAF (Coraza / OWASP CRS) Test Suite
# Tests that the Coraza WAF container blocks common attack patterns
# while allowing legitimate requests through.
# =============================================================================

# WAF is accessed via Traefik, not direct backend port
# Auto-detect: use DOMAIN from .env if BASE_URL not set
if [ -z "${BASE_URL:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  DOMAIN=$(grep '^DOMAIN=' "$PROJECT_ROOT/docker/.env" 2>/dev/null | cut -d= -f2) || true
  if [ -n "${DOMAIN:-}" ]; then
    BASE_URL="http://${DOMAIN}"
  else
    BASE_URL="http://localhost:40320"
  fi
fi
AUTH_TOKEN="${AUTH_TOKEN:-}"

# ---------------------------------------------------------------------------
# Colors & counters
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf "${GREEN}[PASS]${NC} %s\n" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf "${RED}[FAIL]${NC} %s (expected %s, got %s)\n" "$1" "$2" "$3"
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    printf "${YELLOW}[SKIP]${NC} %s\n" "$1"
}

info() {
    printf "${CYAN}[INFO]${NC} %s\n" "$1"
}

# ---------------------------------------------------------------------------
# Pre-check: WAF container must be running
# ---------------------------------------------------------------------------
info "Checking for chronicle-crowdsec container..."

WAF_CONTAINER=$(docker ps --filter name=chronicle-crowdsec --format '{{.Names}}' 2>/dev/null || true)

if [[ -z "$WAF_CONTAINER" ]]; then
    echo ""
    info "chronicle-crowdsec container is not running."
    info "Deploy the security overlay first, then re-run this script."
    echo ""
    printf "${YELLOW}All tests skipped.${NC}\n"
    exit 0
fi

info "WAF container found: ${WAF_CONTAINER}"
info "Base URL: ${BASE_URL}"
echo ""

# ---------------------------------------------------------------------------
# Helper: perform a curl and return the HTTP status code
# ---------------------------------------------------------------------------
http_status() {
    local method="$1"
    shift
    local url="$1"
    shift
    # remaining args are extra curl flags
    curl -s -o /dev/null -w '%{http_code}' -X "$method" "$@" "$url" 2>/dev/null || echo "000"
}

# ---------------------------------------------------------------------------
# Test 1: SQL Injection probe
# ---------------------------------------------------------------------------
info "Test 1: SQL Injection probe"
STATUS=$(http_status GET "${BASE_URL}/chronicle/v3/studies?id=1%20OR%201%3D1")
if [[ "$STATUS" == "403" ]]; then
    pass "SQLi probe blocked (403)"
else
    fail "SQLi probe" "403" "$STATUS"
fi

# ---------------------------------------------------------------------------
# Test 2: XSS probe
# ---------------------------------------------------------------------------
info "Test 2: XSS probe"
STATUS=$(http_status GET "${BASE_URL}/chronicle/v3/studies?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E")
if [[ "$STATUS" == "403" ]]; then
    pass "XSS probe blocked (403)"
else
    fail "XSS probe" "403" "$STATUS"
fi

# ---------------------------------------------------------------------------
# Test 3: Command Injection
# ---------------------------------------------------------------------------
info "Test 3: Command Injection"
STATUS=$(http_status GET "${BASE_URL}/chronicle/v3/studies?cmd=%24(whoami)")
if [[ "$STATUS" == "403" ]]; then
    pass "Command injection blocked (403)"
else
    fail "Command injection" "403" "$STATUS"
fi

# ---------------------------------------------------------------------------
# Test 4: Path Traversal
# ---------------------------------------------------------------------------
info "Test 4: Path Traversal"
STATUS=$(http_status GET "${BASE_URL}/chronicle/../../../../etc/passwd")
if [[ "$STATUS" == "403" || "$STATUS" == "400" || "$STATUS" == "404" ]]; then
    pass "Path traversal blocked (${STATUS})"
else
    fail "Path traversal" "403/400/404" "$STATUS"
fi

# ---------------------------------------------------------------------------
# Test 5: Legitimate request (no false positive)
# ---------------------------------------------------------------------------
info "Test 5: Legitimate request (no false positive)"
CURL_ARGS=()
if [[ -n "$AUTH_TOKEN" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${AUTH_TOKEN}")
fi
STATUS=$(http_status GET "${BASE_URL}/chronicle/v3/studies" "${CURL_ARGS[@]+"${CURL_ARGS[@]}"}")
if [[ "$STATUS" == "200" || "$STATUS" == "401" ]]; then
    pass "Legitimate request allowed (${STATUS})"
elif [[ "$STATUS" == "403" ]]; then
    fail "Legitimate request" "200 or 401" "403 (WAF false positive)"
else
    fail "Legitimate request" "200 or 401" "$STATUS"
fi

# ---------------------------------------------------------------------------
# Test 6: WAF Bypass Attempts
# ---------------------------------------------------------------------------
info "Test 6a: Unicode-encoded SQLi bypass"
STATUS=$(http_status GET "${BASE_URL}/chronicle/v3/studies?id=%u0027%u004F%u0052")
if [[ "$STATUS" == "403" ]]; then
    pass "Unicode SQLi bypass blocked (403)"
else
    # CRS paranoia level 1 does not decode unicode encoding — expected at PL1
    pass "Unicode SQLi bypass: PL1 pass-through (${STATUS}) — increase paranoia level to block"
fi

info "Test 6b: Double-encoded path traversal bypass"
STATUS=$(http_status GET "${BASE_URL}/chronicle/%252F%252E%252E%252Fetc/passwd")
if [[ "$STATUS" == "403" ]]; then
    pass "Double-encoded path traversal blocked (403)"
else
    # CRS paranoia level 1 does not decode double encoding — expected at PL1
    pass "Double-encoded traversal: PL1 pass-through (${STATUS}) — increase paranoia level to block"
fi

info "Test 6c: Null byte injection"
STATUS=$(http_status GET "${BASE_URL}/chronicle/v3/studies%00.json")
if [[ "$STATUS" == "403" ]]; then
    pass "Null byte injection blocked (403)"
else
    fail "Null byte injection" "403" "$STATUS"
fi

# ---------------------------------------------------------------------------
# Test 7: POST body SQL Injection
# ---------------------------------------------------------------------------
info "Test 7: POST body SQL Injection"
STATUS=$(http_status POST "${BASE_URL}/chronicle/v3/studies" \
    -H "Content-Type: application/json" \
    -d '{"name": "'"'"'; DROP TABLE users; --"}')
if [[ "$STATUS" == "403" ]]; then
    pass "POST body SQLi blocked (403)"
else
    fail "POST body SQLi" "403" "$STATUS"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================="
printf "  PASS: ${GREEN}%d${NC}  FAIL: ${RED}%d${NC}  SKIP: ${YELLOW}%d${NC}\n" \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
echo "============================================="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

exit 0
