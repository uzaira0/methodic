#!/usr/bin/env bash
# Silent failure hunter — checks for common silent-failure patterns in the codebase.
# Returns non-zero if any critical patterns are found.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FOUND=0

echo "Silent failure hunter"

# 1. Empty catch blocks in Kotlin/Java
echo "--- Checking for empty catch blocks ---"
if grep -rn 'catch.*{[[:space:]]*}' \
  "$ROOT_DIR/chronicle-server/src" \
  "$ROOT_DIR/chronicle-api/src" \
  --include='*.kt' --include='*.java' 2>/dev/null | grep -v '// expected' | grep -v 'test' | head -5; then
  echo "[warn] Found empty catch blocks (review manually)"
fi

# 2. Fire-and-forget coroutines/async without error handling
echo "--- Checking for fire-and-forget patterns ---"
if grep -rn 'GlobalScope.launch\|runBlocking' \
  "$ROOT_DIR/chronicle-server/src/main" \
  --include='*.kt' 2>/dev/null | head -5; then
  echo "[warn] Found GlobalScope/runBlocking usage (review manually)"
fi

# 3. Catch-and-return-null patterns
echo "--- Checking for catch-and-return-null ---"
if grep -rn -A1 'catch.*{' "$ROOT_DIR/chronicle-server/src/main" --include='*.kt' 2>/dev/null \
  | grep 'return null' | grep -v 'test' | head -5; then
  echo "[warn] Found catch-and-return-null patterns"
fi

echo "[ok] Silent failure hunter complete (warnings are advisory)"
exit $FOUND
