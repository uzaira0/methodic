#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fail() { echo "FAIL W34: $*" >&2; exit 1; }

(cd "$ROOT_DIR/tests/selfhost-py" && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  test_verify.VerifyCredentialsTests.test_real_verify_keeps_credentials_in_stdin_and_proves_session) ||
  fail 'printed backend health or frontend instructions do not match the responses'
echo 'PASS W34: printed backend health instructions expect 204 and frontend instructions retain 200'
