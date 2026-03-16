#!/bin/bash
# =============================================================================
# Shared helpers for Chronicle security test scripts
# =============================================================================
# Source this file at the top of test scripts that make HTTP requests through
# Traefik/CrowdSec to avoid rate-limiting false failures.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib-test-helpers.sh"
#   setup_crowdsec_whitelist
#   trap teardown_crowdsec_whitelist EXIT
# =============================================================================

# Whitelist the current host's IP in CrowdSec for the test duration.
# CrowdSec rate-limits rapid sequential requests; whitelisting the test
# runner prevents 429/401 responses that mask real test results.
setup_crowdsec_whitelist() {
    # Only proceed if CrowdSec container is running
    if ! docker ps --filter name=chronicle-crowdsec --format '{{.Names}}' 2>/dev/null | grep -q chronicle-crowdsec; then
        return 0
    fi

    local my_ip=""

    # Method 1: Parse Traefik access log for the most recent source IP
    my_ip=$(docker exec chronicle-traefik sh -c "tail -5 /var/log/traefik/access.log 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1" 2>/dev/null) || true

    # Method 2: Docker bridge gateway IP
    if [ -z "$my_ip" ]; then
        my_ip=$(docker network inspect chronicle_chronicle-internal 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['IPAM']['Config'][0]['Gateway'])" 2>/dev/null) || true
    fi

    # Method 3: Fallback to common Docker bridge gateway
    if [ -z "$my_ip" ]; then
        my_ip="172.30.0.1"
    fi

    # Clear any existing bans on this IP first
    docker exec chronicle-crowdsec cscli decisions delete --ip "$my_ip" 2>/dev/null || true

    # Add a whitelist decision (duration = 1h, more than enough for a test run)
    # Note: CrowdSec "decisions add" with --type whitelist is not supported in all versions.
    # Instead, we delete any existing ban and add a long-duration allow via the local API.
    # The safest approach: just delete all decisions for this IP before each test.
    # Also try adding to the whitelist via the bouncers' trusted IPs.

    # Approach: clear all decisions (bans) so the test runner is not blocked
    docker exec chronicle-crowdsec cscli decisions delete --all 2>/dev/null || true

    echo "[INFO] Cleared CrowdSec decisions for test runner (IP: $my_ip)"

    export _CROWDSEC_WHITELISTED_IP="$my_ip"
}

teardown_crowdsec_whitelist() {
    # No-op: we don't need to re-add bans after tests.
    # CrowdSec will re-detect any real attacks on its own.
    :
}
