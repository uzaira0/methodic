#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CLI="${ROOT_DIR}/selfhost/chronicle"
fail() { echo "FAIL W34: $*" >&2; exit 1; }

grep -Fq 'http://%s:%s/health   # expect 204' "$CLI" ||
  fail 'proxy-to-backend health instructions do not reflect the backend 204 response'
grep -Fq '%s/health   # expect 204' "$CLI" ||
  fail 'external backend health instructions do not reflect the backend 204 response'
grep -Fq '%s/chronicle/   # expect 200 and a page' "$CLI" ||
  fail 'frontend instructions no longer require a nonempty 200 response'
echo 'PASS W34: printed backend health instructions expect 204 and frontend instructions retain 200'
