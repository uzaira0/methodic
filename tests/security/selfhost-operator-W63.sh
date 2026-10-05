#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
WORK_DIR=/home/opt/chronicle_work/launch-audit-1003/sol/webselfhost-logs
RUN_DIR=$(mktemp -d "${WORK_DIR}/W63.XXXXXX")
trap 'rm -rf -- "$RUN_DIR"' EXIT
SMOKE="$ROOT_DIR/tests/smoke/selfhost-release-smoke.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

sed -n '/^bounded_curl() {/,/^}/p; /^cleanup() {/,/^}/p' "$SMOKE" >"$RUN_DIR/functions.sh"
grep -q '^bounded_curl() {' "$RUN_DIR/functions.sh" || fail 'release smoke has no bounded curl helper'
grep -q '^cleanup() {' "$RUN_DIR/functions.sh" || fail 'release smoke has no evidence cleanup function'
[[ $(grep -Ec '^[[:space:]]*curl[[:space:]]' "$SMOKE") -eq 1 ]] ||
  fail 'a smoke curl call bypasses the deadline helper'
while IFS= read -r line; do
  [[ "$line" == *'wget -T 10 '* ]] || fail "unbounded smoke wget call: $line"
done < <(grep -E 'docker compose exec .* wget ' "$SMOKE")

mkdir -p "$RUN_DIR/bin" "$RUN_DIR/evidence"
FUNCTIONS_FILE="$RUN_DIR/functions.sh"
EVIDENCE_DIR="$RUN_DIR/evidence"
cat >"$RUN_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$CURL_ARGS_FILE"
if [[ "$*" == *'--connect-timeout 5'* && "$*" == *'--max-time 15'* ]]; then
  echo 'curl: (28) Operation timed out' >&2
  exit 28
fi
sleep 30
SH
chmod +x "$RUN_DIR/bin/curl"

status=0
env "PATH=$RUN_DIR/bin:$PATH" "CURL_ARGS_FILE=$RUN_DIR/curl-args" \
  "RUN_DIR=$EVIDENCE_DIR" "BUNDLE=" "OLD_BUNDLE=" "NEW_BUNDLE=" "PROJECT=" \
  "SMOKE_PASSED=false" "UPDATE_SERVER_PID=" \
  timeout 2 bash -c 'set -Eeuo pipefail; source "$1"; trap cleanup EXIT; bounded_curl -fsS http://fixture.invalid/hung' \
  _ "$FUNCTIONS_FILE" >"$RUN_DIR/timeout.out" 2>&1 || status=$?
[[ $status -eq 28 ]] || fail "a stalled synthetic endpoint did not end with curl timeout 28 (got $status)"
grep -Fq -- '--connect-timeout 5 --max-time 15' "$RUN_DIR/curl-args" ||
  fail 'bounded curl did not pass both absolute deadlines'
grep -Fxq 'status=failed' "$RUN_DIR/evidence/result.txt" ||
  fail 'smoke cleanup did not preserve a failed evidence receipt'
echo 'PASS: smoke HTTP deadlines and timeout evidence'
