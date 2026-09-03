#!/usr/bin/env bash
set -euo pipefail

echo "=== Chronicle Complexity Analysis ==="
echo ""

# Find TypeScript/TSX functions longer than 50 lines
echo "--- Frontend: Functions > 50 lines ---"
cd /opt/chronicle/chronicle-web
find src/modern -name "*.ts" -o -name "*.tsx" | grep -v test | grep -v node_modules | while read -r file; do
  awk '
    /^(export )?(async )?(function |const .* = )/ { start=NR; name=$0 }
    start && /^}/ {
      len = NR - start
      if (len > 50) printf "%s:%d (%d lines) %s\n", FILENAME, start, len, name
      start=0
    }
  ' "$file" 2>/dev/null
done

echo ""
echo "--- Backend: Methods > 50 lines ---"
cd /opt/chronicle/chronicle-server
find src/main -name "*.kt" | while read -r file; do
  awk '
    /fun [a-zA-Z]/ { start=NR; name=$0 }
    start && /^    }/ {
      len = NR - start
      if (len > 50) printf "%s:%d (%d lines) %s\n", FILENAME, start, len, name
      start=0
    }
  ' "$file" 2>/dev/null
done

echo ""
echo "Complexity analysis complete"
