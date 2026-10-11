#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
README="${ROOT_DIR}/selfhost/README.md"
fail() { echo "FAIL W81: $*" >&2; exit 1; }

grep -Fq 'PUBLIC_HTTP_ENABLED=true' "$README" ||
  fail 'behind-proxy instructions omit the external HTTP opt-in'
grep -Fq 'canonical HTTPS origin' "$README" ||
  fail 'behind-proxy instructions omit the redirect requirement for external HTTP'
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${ROOT_DIR}/selfhost:${ROOT_DIR}/tests/selfhost-py" \
  python3 -m unittest test_verify.RedirectTests
echo 'PASS W81: docs require owner proxy redirect; bounded verify accepts exact HTTPS Location and rejects controlled failures'
