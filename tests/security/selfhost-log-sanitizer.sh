#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RUN_ROOT="${SELFHOST_LOG_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-log-sanitizer}"
IMAGE='fluent/fluent-bit:4.2.1@sha256:d0ba6ceea4ed1a7cecb15a9184c29cc23159240d8d19b32885268b62dd54155b'

fail() { printf 'self-host log sanitizer test failed: %s\n' "$*" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 ||
  fail "timeout or gtimeout is required"
TIMEOUT=timeout
command -v timeout >/dev/null 2>&1 || TIMEOUT=gtimeout
[[ "$RUN_ROOT" == /* ]] || fail "test root must be absolute"
case "$RUN_ROOT" in /tmp|/tmp/*|/private/tmp|/private/tmp/*) fail "test root must not use a system temporary directory" ;; esac
/bin/mkdir -p "$RUN_ROOT"
output="${RUN_ROOT}/latest.log"
container="chronicle-log-sanitizer-$$"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT HUP INT TERM

"$TIMEOUT" 30 docker run -d --name "$container" --network none \
  -v "${ROOT_DIR}/selfhost/monitoring/sanitize.lua:/sanitize.lua:ro" \
  -v "${ROOT_DIR}/selfhost/monitoring/parsers.conf:/parsers.conf:ro" \
  "$IMAGE" /fluent-bit/bin/fluent-bit -f 1 -R /parsers.conf \
  -i dummy -p tag=chronicle.web \
    -p 'dummy={"ts":1786580000.5,"level":"error","request":{"method":"GET","uri":"/chronicle/v3/study/123e4567-e89b-12d3-a456-426614174000?token=TOPSECRET_9","headers":{"Authorization":["Bearer TOPSECRET_9"]}},"status":500,"duration":0.125,"message":"participant=p-123 TOPSECRET_9"}' \
  -i dummy -p tag=chronicle.backend \
    -p 'dummy={"log":"{\"timestamp\":\"2026-08-13T00:00:00Z\",\"severity\":\"WARN\",\"request_id\":\"request-safe-1\",\"method\":\"POST\",\"route\":\"/chronicle/v3/participant/private-name?secret=TOPSECRET_9\",\"message\":\"TOPSECRET_9\"}"}' \
  -i dummy -p tag=chronicle.postgres \
    -p 'dummy={"log":"chronicle_pg timestamp_ms=1786580000500 sqlstate=23505 ERROR: statement SELECT TOPSECRET_9"}' \
  -F parser -m 'chronicle.*' -p key_name=log -p parser=chronicle_json -p reserve_data=true -p preserve_key=false \
  -F parser -m chronicle.postgres -p key_name=log -p parser=chronicle_postgres -p reserve_data=true -p preserve_key=false \
  -F lua -m 'chronicle.*' -p script=/sanitize.lua -p call=sanitize \
  -o stdout -m 'chronicle.*' -p format=json_lines >/dev/null

ready=false
for _ in {1..30}; do
  docker logs "$container" >"$output" 2>&1 || true
  if grep -q '"service":"web"' "$output" &&
     grep -q '"service":"backend"' "$output" &&
     grep -q '"service":"postgres"' "$output"; then
    ready=true
    break
  fi
  sleep 0.5
done
[[ "$ready" == true ]] || { cat "$output" >&2; fail "Fluent Bit fixture did not emit every source within 15 seconds"; }

python3 - "$output" <<'PY'
import json
import sys

rows = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if not line.startswith("{"):
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    if row.get("service") in {"web", "backend", "postgres"}:
        rows.append(row)

by_service = {}
for row in rows:
    by_service.setdefault(row["service"], row)
assert set(by_service) == {"web", "backend", "postgres"}, by_service.keys()
assert by_service["web"]["route"] == "/chronicle/v3/study/{id}"
assert by_service["web"]["status"] == "500"
assert by_service["web"]["duration_ms"] == 125
assert by_service["backend"]["route"] == "/chronicle/v3/participant/{id}"
assert by_service["backend"]["request_id"] == "request-safe-1"
assert by_service["postgres"]["sqlstate"] == "23505"

allowed = {
    "date", "timestamp", "service", "stream", "severity", "request_id", "error_id",
    "operation", "result", "failure_category", "release_version", "status", "method",
    "route", "duration_ms", "sqlstate", "exception_class", "message",
}
for row in by_service.values():
    assert set(row) <= allowed, set(row) - allowed
serialized = json.dumps(by_service, sort_keys=True)
for forbidden in (
    "TOPSECRET_9", "p-123", "123e4567-e89b-12d3-a456-426614174000",
    "Authorization", "SELECT", "private-name", "token=",
):
    assert forbidden not in serialized, forbidden
print("self-host structured log sanitizer test passed")
PY
