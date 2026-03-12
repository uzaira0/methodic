#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB="$ROOT/chronicle-web"

echo "Chronicle web bootstrap smoke"
echo "web: $WEB"

cd "$WEB"
bun run check
bun test \
  src/bun-legacy/exchangeBootstrapToken.test.js \
  src/bun-legacy/resolveLegacyBootstrapToken.test.js \
  src/bun-legacy/storeAuthInfo.test.js \
  src/bun-legacy/clearAuthInfo.test.js \
  src/bun-legacy/logoutCookieSession.test.js \
  src/bun-legacy/shellRouting.test.js
CI=1 bunx playwright test e2e/modern-shell.spec.ts --grep "deep link directly"
