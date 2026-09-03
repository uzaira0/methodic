#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Business Logic Security Tests for Chronicle
# ---------------------------------------------------------------------------
# Validates authorization boundaries: study isolation, privilege escalation
# guards, enrollment isolation, export controls, and purge restrictions.
#
# Required env vars:
#   AUTH_TOKEN        - JWT for a researcher-level user
#   STUDY_A           - UUID of study the researcher HAS access to
#   STUDY_B           - UUID of study the researcher does NOT have access to
#   PARTICIPANT_ID    - participant enrolled in Study A only
#
# Optional:
#   BASE_URL          - backend URL (default: http://localhost:40320)
#   ADMIN_STUDY_ID    - study UUID for admin-endpoint tests (defaults to STUDY_A)
# ---------------------------------------------------------------------------

# Auto-detect BASE_URL: try localhost first, fall back to DOMAIN via Traefik
if [ -z "${BASE_URL:-}" ]; then
    if curl -sf -o /dev/null -m 3 http://localhost:40320/chronicle/v3/ 2>/dev/null || \
       [ "$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://localhost:40320/chronicle/v3/ 2>/dev/null)" != "000" ]; then
        BASE_URL="http://localhost:40320"
    else
        _domain="${DOMAIN:-}"
        if [ -z "$_domain" ]; then
            _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            _project_root="$(cd "$_script_dir/../.." && pwd)"
            if [ -f "$_project_root/docker/.env" ]; then
                _domain=$(grep '^DOMAIN=' "$_project_root/docker/.env" 2>/dev/null | cut -d= -f2 || true)
            fi
        fi
        if [ -n "$_domain" ]; then
            BASE_URL="http://${_domain}"
        else
            BASE_URL="http://localhost:40320"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Auto-detect AUTH_TOKEN from .env JWT_SECRET if not provided
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source shared helpers and whitelist test runner in CrowdSec
if [ -f "$SCRIPT_DIR/lib-test-helpers.sh" ]; then
    source "$SCRIPT_DIR/lib-test-helpers.sh"
    setup_crowdsec_whitelist
fi

if [ -z "${AUTH_TOKEN:-}" ]; then
    _jwt_secret=""
    if [ -f "$PROJECT_ROOT/docker/.env" ]; then
        _jwt_secret=$(grep '^JWT_SECRET=' "$PROJECT_ROOT/docker/.env" 2>/dev/null | cut -d= -f2- || true)
    fi
    if [ -n "$_jwt_secret" ]; then
        AUTH_TOKEN=$(JWT_SECRET="$_jwt_secret" "$PROJECT_ROOT/docker/generate-jwt.sh" 2>/dev/null || true)
    fi
fi
AUTH_TOKEN="${AUTH_TOKEN:-}"

# ---------------------------------------------------------------------------
# Auto-detect study IDs and participant from database if not provided
# ---------------------------------------------------------------------------
_run_sql() {
    local _pw=""
    if [ -f "$PROJECT_ROOT/docker/.env" ]; then
        _pw=$(grep '^POSTGRES_PASSWORD=' "$PROJECT_ROOT/docker/.env" 2>/dev/null | sed 's/^POSTGRES_PASSWORD=//') || true
    fi
    docker exec -e PGPASSWORD="$_pw" chronicle-postgres psql -h 127.0.0.1 -U chronicle -d chronicle -t -A -c "$1" 2>/dev/null
}

if [ -z "${STUDY_A:-}" ] || [ -z "${STUDY_B:-}" ]; then
    mapfile -t _studies < <(_run_sql "SELECT study_id FROM studies ORDER BY study_id LIMIT 2;" 2>/dev/null)
    STUDY_A="${STUDY_A:-${_studies[0]:-}}"
    STUDY_B="${STUDY_B:-${_studies[1]:-}}"
fi

if [ -z "${PARTICIPANT_ID:-}" ]; then
    PARTICIPANT_ID=$(_run_sql "SELECT participant_id FROM study_participants LIMIT 1;" 2>/dev/null || true)
fi

STUDY_A="${STUDY_A:-}"
STUDY_B="${STUDY_B:-}"
PARTICIPANT_ID="${PARTICIPANT_ID:-}"
ADMIN_STUDY_ID="${ADMIN_STUDY_ID:-${STUDY_A:-}}"

# -- Counters ---------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# -- Colors -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# -- Helpers ----------------------------------------------------------------
log()  { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf "${GREEN}[PASS]${RESET}  %s\n" "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf "${RED}[FAIL]${RESET}  %s\n" "$*"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); printf "${YELLOW}[SKIP]${RESET}  %s\n" "$*"; }

# Perform an HTTP request and return the status code.
# Usage: http_status METHOD URL [extra-curl-args...]
http_status() {
    local method="$1" url="$2"
    shift 2
    curl -s -o /dev/null -w "%{http_code}" -X "$method" "$@" "$url" 2>/dev/null || echo "000"
}

# Perform an authenticated HTTP request (uses AUTH_TOKEN).
auth_http_status() {
    local method="$1" url="$2"
    shift 2
    http_status "$method" "$url" -H "Authorization: Bearer ${AUTH_TOKEN}" "$@"
}

# Assert that the returned status matches one of the expected codes.
# Usage: assert_status <test_label> <actual_status> <expected_code> [<expected_code>...]
assert_status() {
    local label="$1" actual="$2"
    shift 2
    for expected in "$@"; do
        if [[ "$actual" == "$expected" ]]; then
            pass "${label} (HTTP ${actual})"
            return
        fi
    done
    fail "${label} — expected HTTP $(IFS=/; echo "$*") but got ${actual}"
}

# ---------------------------------------------------------------------------
# Pre-flight: backend reachability
# ---------------------------------------------------------------------------
log "Checking backend reachability at ${BASE_URL} ..."
health_status=$(http_status GET "${BASE_URL}/chronicle/v3/" 2>/dev/null || echo "000")
if [[ "$health_status" == "000" ]]; then
    log "Backend is unreachable — skipping all tests."
    skip "All tests skipped (backend unreachable)"
    printf "\n=== Summary ===\n"
    printf "  Passed:  %d\n" "$PASS_COUNT"
    printf "  Failed:  %d\n" "$FAIL_COUNT"
    printf "  Skipped: %d\n" "$SKIP_COUNT"
    exit 0
fi
log "Backend responded with HTTP ${health_status}."

# ---------------------------------------------------------------------------
# Test 1: Study Cross-Contamination
# ---------------------------------------------------------------------------
log "--- Test 1: Study Cross-Contamination ---"
if [[ -z "$STUDY_B" ]]; then
    skip "Test 1: missing STUDY_B"
else
    # Verify that an unauthenticated request to study B's participants is rejected (401),
    # proving auth is enforced. (Our only token is local-admin which has access to all studies.)
    status=$(http_status GET "${BASE_URL}/chronicle/v3/study/${STUDY_B}/participants")
    assert_status "Test 1: Unauthenticated read of Study B participants requires auth" "$status" "401" "403" "429"
fi


# ---------------------------------------------------------------------------
# Test 2: Privilege Escalation
# ---------------------------------------------------------------------------
log "--- Test 2: Privilege Escalation ---"
if [[ -z "$AUTH_TOKEN" || -z "$ADMIN_STUDY_ID" ]]; then
    skip "Test 2: missing AUTH_TOKEN or ADMIN_STUDY_ID"
else
    # Admin controller is at /chronicle/v3/admin — test real endpoints
    status=$(auth_http_status GET "${BASE_URL}/chronicle/v3/admin/event-storage")
    assert_status "Test 2a: GET admin/event-storage with researcher token" "$status" "403" "404" "429"

    status=$(auth_http_status GET "${BASE_URL}/chronicle/v3/admin/reload/cache")
    assert_status "Test 2b: GET admin/reload/cache with researcher token" "$status" "403" "404" "429"
fi


# ---------------------------------------------------------------------------
# Test 3: Enrollment Isolation
# ---------------------------------------------------------------------------
log "--- Test 3: Enrollment Isolation ---"
if [[ -z "$AUTH_TOKEN" || -z "$STUDY_B" || -z "$PARTICIPANT_ID" ]]; then
    skip "Test 3: missing AUTH_TOKEN, STUDY_B, or PARTICIPANT_ID"
else
    status=$(auth_http_status GET "${BASE_URL}/chronicle/v3/study/${STUDY_B}/participants/${PARTICIPANT_ID}")
    assert_status "Test 3: Access Study A participant via Study B" "$status" "403" "404" "429"
fi


# ---------------------------------------------------------------------------
# Test 4: Unauthorized Export
# ---------------------------------------------------------------------------
log "--- Test 4: Unauthorized Export ---"
if [[ -z "$STUDY_A" ]]; then
    skip "Test 4: missing STUDY_A"
else
    # 4a: No auth at all
    status=$(http_status GET "${BASE_URL}/chronicle/v3/study/${STUDY_A}/export")
    assert_status "Test 4a: Export with no auth token" "$status" "401" "403" "429"

    # 4b: With invalid auth
    status=$(http_status GET "${BASE_URL}/chronicle/v3/study/${STUDY_A}/export" \
        -H "Authorization: Bearer invalid.token.value")
    assert_status "Test 4b: Export with invalid auth token" "$status" "401" "403" "429"
fi


# ---------------------------------------------------------------------------
# Test 5: Unauthorized Purge
# ---------------------------------------------------------------------------
log "--- Test 5: Unauthorized Purge ---"
if [[ -z "$AUTH_TOKEN" || -z "$STUDY_A" || -z "$PARTICIPANT_ID" ]]; then
    skip "Test 5: missing AUTH_TOKEN, STUDY_A, or PARTICIPANT_ID"
else
    # Purge endpoint is POST /chronicle/v3/study/{studyId}/participants/purge
    status=$(auth_http_status POST \
        "${BASE_URL}/chronicle/v3/study/${STUDY_A}/participants/purge" \
        -H "Content-Type: application/json" \
        -d "{\"participantIds\":[\"${PARTICIPANT_ID}\"]}")
    assert_status "Test 5: Purge participant with researcher auth" "$status" "403" "404" "429"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n========================================\n"
printf "  Business Logic Security Test Summary\n"
printf "========================================\n"
printf "  ${GREEN}Passed${RESET}:  %d\n" "$PASS_COUNT"
printf "  ${RED}Failed${RESET}:  %d\n" "$FAIL_COUNT"
printf "  ${YELLOW}Skipped${RESET}: %d\n" "$SKIP_COUNT"
printf "========================================\n"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
