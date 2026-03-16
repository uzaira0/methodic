#!/usr/bin/env bash
# Autoresearch benchmark runner for Chronicle security tests
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Security Benchmark ==="

# Run full security scan, strip ANSI codes for accurate counting
OUT=$(DOMAIN=cnrc-deni-p001.cnrc.bcm.edu timeout 600 bash tests/security/run-all-security.sh 2>&1 | sed 's/\x1b\[[0-9;]*m//g')

# Count all check results (after stripping ANSI)
PASS_COUNT=$(echo "$OUT" | grep -c '\[PASS\]' || true)
FAIL_COUNT=$(echo "$OUT" | grep -c '\[FAIL\]' || true)
SKIP_COUNT=$(echo "$OUT" | grep -c '\[SKIP\]' || true)

echo ""
echo "  Individual checks: ${PASS_COUNT} pass, ${FAIL_COUNT} fail, ${SKIP_COUNT} skip"
echo ""
echo "METRIC total_pass=${PASS_COUNT}"
echo "METRIC total_fail=${FAIL_COUNT}"
echo "METRIC total_skip=${SKIP_COUNT}"
