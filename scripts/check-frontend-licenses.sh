#!/usr/bin/env bash
# check-frontend-licenses.sh — Verify frontend dependency licenses are Apache-2.0 compatible.
# Runs via: bash scripts/check-frontend-licenses.sh (from repo root, expects bun in PATH)
set -euo pipefail

cd "$(dirname "$0")/../chronicle-web"

# SPDX identifiers considered compatible with Apache-2.0
ALLOWED='MIT;ISC;BSD-2-Clause;BSD-3-Clause;0BSD;Apache-2.0;CC0-1.0;Unlicense;CC-BY-3.0;CC-BY-4.0;BlueOak-1.0.0;Python-2.0'

echo "=== Frontend license compliance check ==="
echo "Allowed licenses: ${ALLOWED}"
echo ""

# license-checker works with node_modules; bun install populates node_modules.
# --production ignores devDependencies (test tooling, linters, etc.).
OUTPUT=$(npx license-checker --production --onlyAllow "${ALLOWED}" --summary 2>&1) && STATUS=0 || STATUS=$?

echo "${OUTPUT}"

if [ "${STATUS}" -ne 0 ]; then
    echo ""
    echo "ERROR: One or more production dependencies use a license not in the allowlist."
    echo "Review the output above. If a license is acceptable, add its SPDX ID to ALLOWED in this script"
    echo "and to config/allowed-licenses.json for backend parity."
    exit 1
fi

echo ""
echo "All production frontend dependencies use allowed licenses."
