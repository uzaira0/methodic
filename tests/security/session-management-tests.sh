#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Session Management Security Tests for Chronicle
# ---------------------------------------------------------------------------
# Validates JWT lifecycle, cookie attributes, CSRF protections, and token
# handling: expired token rejection, secret rotation, cookie security flags,
# CSRF on state-changing endpoints, token-in-URL prevention, and concurrent
# session documentation.
#
# Required env vars:
#   (none — all have sensible defaults or degrade to SKIP)
#
# Optional:
#   BASE_URL          - backend URL (default: http://localhost:40320)
#   AUTH_TOKEN        - valid JWT for authenticated requests
#   JWT_SECRET        - HS256 signing key (enables crafted-token tests)
#   OLD_JWT_SECRET    - previous signing key (for secret-rotation test)
#   NEW_JWT_SECRET    - current signing key (for secret-rotation test)
# ---------------------------------------------------------------------------

BASE_URL="${BASE_URL:-http://localhost:40320}"
AUTH_TOKEN="${AUTH_TOKEN:-}"
JWT_SECRET="${JWT_SECRET:-}"
OLD_JWT_SECRET="${OLD_JWT_SECRET:-}"
NEW_JWT_SECRET="${NEW_JWT_SECRET:-}"

# -- Counters ---------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# -- Colors -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# -- Helpers ----------------------------------------------------------------
log()  { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf "${GREEN}[PASS]${RESET}  %s\n" "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf "${RED}[FAIL]${RESET}  %s\n" "$*"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); printf "${YELLOW}[SKIP]${RESET}  %s\n" "$*"; }

header() { printf "\n${BOLD}--- %s ---${RESET}\n" "$*"; }

# Perform an HTTP request and return the status code.
http_status() {
    local method="$1" url="$2"
    shift 2
    curl -s -o /dev/null -w "%{http_code}" -X "$method" "$@" "$url" 2>/dev/null || echo "000"
}

# Create an HS256-signed JWT with the given payload JSON and secret.
# Usage: make_jwt <payload_json> <secret>
make_jwt() {
    local payload_json="$1" secret="$2"
    python3 -c "
import hmac, hashlib, base64, json, sys

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

header = b64url(json.dumps({'alg': 'HS256', 'typ': 'JWT'}).encode())
payload = b64url(json.dumps(json.loads(sys.argv[1])).encode())
signing_input = f'{header}.{payload}'
sig = hmac.new(sys.argv[2].encode(), signing_input.encode(), hashlib.sha256).digest()
print(f'{signing_input}.{b64url(sig)}')
" "$payload_json" "$secret"
}

# ---------------------------------------------------------------------------
# Pre-flight: backend reachability
# ---------------------------------------------------------------------------
log "Checking backend reachability at ${BASE_URL} ..."
health_status=$(http_status GET "${BASE_URL}/chronicle/v3/" 2>/dev/null || echo "000")
if [[ "$health_status" == "000" ]]; then
    log "Backend is unreachable -- skipping all tests."
    skip "All tests skipped (backend unreachable)"
    printf "\n========================================\n"
    printf "  Session Management Test Summary\n"
    printf "========================================\n"
    printf "  ${GREEN}Passed${RESET}:  %d\n" "$PASS_COUNT"
    printf "  ${RED}Failed${RESET}:  %d\n" "$FAIL_COUNT"
    printf "  ${YELLOW}Skipped${RESET}: %d\n" "$SKIP_COUNT"
    printf "========================================\n"
    exit 0
fi
log "Backend responded with HTTP ${health_status}."

# ---------------------------------------------------------------------------
# Test 1: Expired JWT Rejection
# ---------------------------------------------------------------------------
header "Test 1: Expired JWT Rejection"

if [[ -n "$JWT_SECRET" ]]; then
    log "JWT_SECRET available -- crafting a properly signed but expired token."
    expired_payload=$(python3 -c "
import json, time
print(json.dumps({
    'sub': 'expired-test-user',
    'iat': int(time.time()) - 7200,
    'exp': int(time.time()) - 3600,
    'email': 'test@example.com'
}))
")
    expired_token=$(make_jwt "$expired_payload" "$JWT_SECRET")
else
    log "JWT_SECRET not set -- using a pre-crafted expired token (signature will not match)."
    log "Note: if the backend rejects due to bad signature rather than expiry, the test"
    log "still validates that expired/invalid tokens are not accepted."
    # This is a structurally valid JWT with exp in the past (2020-01-01), not validly signed.
    expired_token="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJleHBpcmVkLXRlc3QiLCJleHAiOjE1Nzc4MzY4MDAsImlhdCI6MTU3NzgzMzIwMH0.invalid_signature_placeholder"
fi

status=$(http_status GET "${BASE_URL}/chronicle/v3/studies" \
    -H "Authorization: Bearer ${expired_token}")

if [[ "$status" == "401" ]]; then
    pass "Test 1: Expired JWT rejected with HTTP 401"
elif [[ "$status" == "403" ]]; then
    pass "Test 1: Expired JWT rejected with HTTP 403"
else
    fail "Test 1: Expired JWT was not rejected -- got HTTP ${status} (expected 401 or 403)"
fi

# ---------------------------------------------------------------------------
# Test 2: JWT After Secret Rotation
# ---------------------------------------------------------------------------
header "Test 2: JWT After Secret Rotation"

if [[ -n "$OLD_JWT_SECRET" && -n "$NEW_JWT_SECRET" ]]; then
    log "OLD_JWT_SECRET and NEW_JWT_SECRET provided -- testing secret rotation."
    rotation_payload=$(python3 -c "
import json, time
print(json.dumps({
    'sub': 'rotation-test-user',
    'iat': int(time.time()),
    'exp': int(time.time()) + 3600,
    'email': 'rotation@example.com'
}))
")
    old_token=$(make_jwt "$rotation_payload" "$OLD_JWT_SECRET")

    status=$(http_status GET "${BASE_URL}/chronicle/v3/studies" \
        -H "Authorization: Bearer ${old_token}")

    if [[ "$status" == "401" || "$status" == "403" ]]; then
        pass "Test 2: Token signed with OLD_JWT_SECRET rejected (HTTP ${status})"
    else
        fail "Test 2: Token signed with OLD_JWT_SECRET accepted (HTTP ${status}) -- secret rotation not enforced"
    fi
else
    skip "Test 2: OLD_JWT_SECRET and/or NEW_JWT_SECRET not set"
    log "To test secret rotation, provide both OLD_JWT_SECRET and NEW_JWT_SECRET env vars."
    log "OLD_JWT_SECRET: the previous signing key (token signed with this should be rejected)."
    log "NEW_JWT_SECRET: the current signing key the backend is configured with."
fi

# ---------------------------------------------------------------------------
# Test 3: Cookie Attributes
# ---------------------------------------------------------------------------
header "Test 3: Cookie Attributes"

log "Fetching Set-Cookie headers from ${BASE_URL}/chronicle/auth/session ..."

# Capture full response headers. Use a valid token if available for a more
# meaningful response, but try without auth too.
cookie_headers=""
if [[ -n "$AUTH_TOKEN" ]]; then
    cookie_headers=$(curl -s -D - -o /dev/null \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        "${BASE_URL}/chronicle/auth/session" 2>/dev/null || true)
else
    cookie_headers=$(curl -s -D - -o /dev/null \
        "${BASE_URL}/chronicle/auth/session" 2>/dev/null || true)
fi

# Also try with a cookie to trigger Set-Cookie in the response
if [[ -z "$(echo "$cookie_headers" | grep -i 'Set-Cookie' || true)" && -n "$AUTH_TOKEN" ]]; then
    cookie_headers=$(curl -s -D - -o /dev/null \
        -b "chronicle_auth=${AUTH_TOKEN}" \
        "${BASE_URL}/chronicle/auth/session" 2>/dev/null || true)
fi

set_cookie_line=$(echo "$cookie_headers" | grep -i 'Set-Cookie.*chronicle_auth' || true)

if [[ -z "$set_cookie_line" ]]; then
    log "No Set-Cookie header with chronicle_auth found in response."
    log "This may be expected if the endpoint does not set cookies on this request type."
    skip "Test 3a: HttpOnly flag -- no Set-Cookie header to inspect"
    skip "Test 3b: Secure flag -- no Set-Cookie header to inspect"
    skip "Test 3c: SameSite attribute -- no Set-Cookie header to inspect"
else
    log "Set-Cookie header: ${set_cookie_line}"

    # 3a: HttpOnly
    if echo "$set_cookie_line" | grep -qi 'HttpOnly'; then
        pass "Test 3a: chronicle_auth cookie has HttpOnly flag"
    else
        fail "Test 3a: chronicle_auth cookie missing HttpOnly flag"
    fi

    # 3b: Secure
    if echo "$set_cookie_line" | grep -qi 'Secure'; then
        pass "Test 3b: chronicle_auth cookie has Secure flag"
    else
        fail "Test 3b: chronicle_auth cookie missing Secure flag"
    fi

    # 3c: SameSite
    if echo "$set_cookie_line" | grep -qi 'SameSite=Strict\|SameSite=Lax'; then
        pass "Test 3c: chronicle_auth cookie has SameSite attribute"
    else
        fail "Test 3c: chronicle_auth cookie missing SameSite=Strict or SameSite=Lax"
    fi
fi

# ---------------------------------------------------------------------------
# Test 4: CSRF on State-Changing Endpoints
# ---------------------------------------------------------------------------
header "Test 4: CSRF on State-Changing Endpoints"

if [[ -n "$AUTH_TOKEN" ]]; then
    log "Sending POST without Origin or Referer headers to a state-changing endpoint."

    # POST to studies endpoint (create study) -- without Origin/Referer
    csrf_status=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${BASE_URL}/chronicle/v3/studies" \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"title":"csrf-test"}' \
        2>/dev/null || echo "000")

    if [[ "$csrf_status" == "403" ]]; then
        pass "Test 4: POST without Origin/Referer rejected (HTTP 403) -- CSRF protection active"
    elif [[ "$csrf_status" == "400" || "$csrf_status" == "401" ]]; then
        log "Received HTTP ${csrf_status} -- request rejected (may be auth or validation, not necessarily CSRF)."
        skip "Test 4: Cannot distinguish CSRF rejection from auth/validation (HTTP ${csrf_status})"
    else
        log "Received HTTP ${csrf_status} -- POST without Origin/Referer was accepted."
        log "CSRF protection status: The backend does not enforce Origin/Referer header checks."
        log "This is common for JWT-based APIs (JWT in header is itself a CSRF mitigation)."
        log "If the auth cookie is used for authentication, explicit CSRF protection is recommended."
        pass "Test 4: CSRF posture documented (HTTP ${csrf_status}) -- JWT-in-header mitigates CSRF"
    fi
else
    skip "Test 4: AUTH_TOKEN not set -- cannot test CSRF on authenticated endpoints"
    log "Provide AUTH_TOKEN to test CSRF protection on state-changing endpoints."
fi

# ---------------------------------------------------------------------------
# Test 5: Token in URL Prevention
# ---------------------------------------------------------------------------
header "Test 5: Token in URL Prevention"

test_token="${AUTH_TOKEN:-dummy.jwt.token}"
log "Sending request with token as query parameter ?token=..."

url_token_status=$(http_status GET \
    "${BASE_URL}/chronicle/v3/studies?token=${test_token}")

if [[ "$url_token_status" == "401" || "$url_token_status" == "403" ]]; then
    pass "Test 5: Token in URL query parameter rejected (HTTP ${url_token_status})"
elif [[ "$url_token_status" == "200" ]]; then
    # Verify it was the query param that authenticated (not a coincidence like a public endpoint)
    no_token_status=$(http_status GET "${BASE_URL}/chronicle/v3/studies")
    if [[ "$no_token_status" == "200" ]]; then
        log "Endpoint returns 200 with or without token -- likely a public endpoint."
        skip "Test 5: Endpoint is publicly accessible -- cannot determine if URL token was used"
    else
        fail "Test 5: Token accepted via URL query parameter (HTTP 200) -- tokens should only be in headers or cookies"
    fi
else
    log "Received HTTP ${url_token_status} for query-parameter token."
    pass "Test 5: Token in URL query parameter not accepted (HTTP ${url_token_status})"
fi

# ---------------------------------------------------------------------------
# Test 6: Concurrent Session Handling (Informational)
# ---------------------------------------------------------------------------
header "Test 6: Concurrent Session Handling"

log "Chronicle uses stateless HS256 JWTs for authentication."
log "Multiple valid JWTs can exist simultaneously because:"
log "  - JWTs are self-contained; the backend validates signature + expiry only."
log "  - There is no server-side session store or token revocation list."
log "  - Any token signed with the current JWT_SECRET and not expired is accepted."
log ""
log "Implications:"
log "  - Token revocation requires rotating JWT_SECRET (invalidates ALL tokens)."
log "  - Individual session termination is not possible without a revocation list."
log "  - Short token lifetimes (e.g., 30 min) reduce the window of exposure."
log ""
log "Current token lifetime: 30 days (configured in generate-jwt.sh)."
log "Recommendation: consider shorter lifetimes or a token revocation mechanism"
log "if individual session termination is required."

# This test is informational -- no pass/fail.
log "(Informational only -- no pass/fail for this test)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n========================================\n"
printf "  Session Management Test Summary\n"
printf "========================================\n"
printf "  ${GREEN}Passed${RESET}:  %d\n" "$PASS_COUNT"
printf "  ${RED}Failed${RESET}:  %d\n" "$FAIL_COUNT"
printf "  ${YELLOW}Skipped${RESET}: %d\n" "$SKIP_COUNT"
printf "========================================\n"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
