#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RUN_DIR=$(mktemp -d /tmp/chronicle-gitleaks-history.XXXXXX)
trap 'rm -rf -- "$RUN_DIR"' EXIT
gitleaks git --no-banner --redact \
  --gitleaks-ignore-path "$ROOT_DIR/tests/security/gitleaks-ignore/methodic-root.gitleaksignore" \
  --report-format json --report-path "$RUN_DIR/history.json" "$ROOT_DIR" >"$RUN_DIR/history.log" 2>&1 || { cat "$RUN_DIR/history.log" >&2; exit 1; }
mkdir "$RUN_DIR/fixture"
python3 - "$RUN_DIR/fixture/credential.conf" <<'PY'
from pathlib import Path
import secrets
import sys
Path(sys.argv[1]).write_text('api_key = "' + secrets.token_hex(20) + '"\n')
PY
status=0
gitleaks dir --no-banner --redact --report-format json --report-path "$RUN_DIR/injected.json" \
  "$RUN_DIR/fixture" >"$RUN_DIR/injected.log" 2>&1 || status=$?
[[ "$status" == 1 ]] || { echo 'FAIL: injected credential did not fail secret detection' >&2; exit 1; }
echo 'PASS: redacted history passes exact ignores; injected credential still fails'
