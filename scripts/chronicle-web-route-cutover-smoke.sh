#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB="$ROOT/chronicle-web"

cleanup() {
  git -C "$WEB" restore build/index.html build/static/js/index.js >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "Chronicle web route-cutover smoke"
echo "web: $WEB"

cd "$WEB"
bun run check
bun run build:dev
bun run test:legacy -- --runInBand --watch=false
CI=1 bun run e2e
