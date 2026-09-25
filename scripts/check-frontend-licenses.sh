#!/usr/bin/env bash
# check-frontend-licenses.sh — Verify frontend dependency licenses are allowed (GPL-3.0-or-later project).
# Runs via: bash scripts/check-frontend-licenses.sh (from repo root, expects bun in PATH)
set -euo pipefail

cd "$(dirname "$0")/../chronicle-web"

# SPDX identifiers considered compatible with Apache-2.0
ALLOWED='MIT;ISC;BSD-2-Clause;BSD-3-Clause;0BSD;Apache-2.0;CC0-1.0;Unlicense;CC-BY-3.0;CC-BY-4.0;BlueOak-1.0.0;Python-2.0;OFL-1.1'

echo "=== Frontend license compliance check ==="

# The package.json license field must name the license in LICENSE (GPL v3; upstream headers
# say "or any later version").
PROJECT_LICENSE=$(bun -e 'console.log(require("./package.json").license)')
PROJECT_ID=$(bun -e 'const p = require("./package.json"); console.log(`${p.name}@${p.version}`)')
if grep -q 'GNU GENERAL PUBLIC LICENSE' LICENSE && [ "${PROJECT_LICENSE}" != "GPL-3.0-or-later" ]; then
    echo "ERROR: package.json license is '${PROJECT_LICENSE}' but LICENSE is GPL v3 (expected GPL-3.0-or-later)."
    exit 1
fi
echo "Allowed licenses: ${ALLOWED}"
echo ""

# license-checker works with node_modules; bun install populates node_modules.
# --production ignores devDependencies (test tooling, linters, etc.).
# --excludePrivatePackages skips repo-owned workspace packages; their package.json
# metadata is still explicit, but this gate is for third-party dependency intake.
# --bun forces the Bun runtime (license-checker's shebang is `env node`; without
# the flag bunx would re-introduce a Node dependency).
OUTPUT=$(bunx --bun license-checker@25.0.1 --production --excludePrivatePackages --excludePackages "${PROJECT_ID}" --onlyAllow "${ALLOWED}" --summary 2>&1) && STATUS=0 || STATUS=$?

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
