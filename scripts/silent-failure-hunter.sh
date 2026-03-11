#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT=0

if [[ "${1:-}" == "--strict" ]]; then
  STRICT=1
fi

echo "Silent failure hunter"
echo "root: $ROOT_DIR"

declare -a PATTERNS=(
  "catch \\(.*\\) \\{\\s*\\}"
  "\\.catch\\(\\s*\\(\\)\\s*=>\\s*\\{?\\s*\\}?\\s*\\)"
  "Promise<.*>\\s*=\\s*fetch\\("
  "queueMicrotask\\("
  "console\\.error\\("
)

hits=0
for pattern in "${PATTERNS[@]}"; do
  echo
  echo "pattern: $pattern"
  if rg -n "$pattern" "$ROOT_DIR/chronicle-web/src" "$ROOT_DIR/chronicle-server/src" "$ROOT_DIR/chronicle-api/src" \
    --glob '!**/build/**' --glob '!**/node_modules/**'; then
    hits=$((hits + 1))
  else
    echo "no matches"
  fi
done

echo
echo "summary: suspicious-pattern-groups=$hits"

if (( STRICT == 1 && hits > 0 )); then
  exit 1
fi
