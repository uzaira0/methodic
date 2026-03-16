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
# =============================================================================

# Clear CrowdSec bans on the test runner's IP before tests.
# CrowdSec rate-limits rapid sequential requests; clearing bans on the test
# runner's IP prevents 429/401 responses that mask real test results.
setup_crowdsec_whitelist() {
    # Only proceed if CrowdSec container is running
    if ! docker ps --filter name=chronicle-crowdsec --format '{{.Names}}' 2>/dev/null | grep -q chronicle-crowdsec; then
        echo "[INFO] CrowdSec not running — skipping whitelist setup"
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

    # Clear bans on test runner IP only (not --all, which would remove legitimate bans)
    if ! docker exec chronicle-crowdsec cscli decisions delete --ip "$my_ip" 2>/dev/null; then
        echo "[WARN] Failed to clear CrowdSec decisions for $my_ip — tests may get 429s" >&2
    fi

    echo "[INFO] Cleared CrowdSec decisions for test runner IP: $my_ip"
}
