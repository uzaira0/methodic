#!/usr/bin/env bash
# Shared capture-all execution and manifest support for run-all-security.sh.
# This file is source-safe: sourcing it does not execute a security layer.

SECURITY_RUNNER_INITIALIZED=0
SECURITY_RUNNER_FINALIZED=0
SECURITY_RUNNER_EXIT_CODE=2

security_runner_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

security_runner_init() {
  local layer="$1"
  local report_dir="$2"

  mkdir -p "$report_dir"
  SECURITY_RUNNER_LAYER="$layer"
  SECURITY_RUNNER_REPORT_DIR="$(cd "$report_dir" && pwd)"
  SECURITY_RUNNER_EVENTS="$SECURITY_RUNNER_REPORT_DIR/.security-events-${layer}.jsonl"
  SECURITY_RUNNER_MANIFEST="$SECURITY_RUNNER_REPORT_DIR/security-manifest-${layer}.json"
  SECURITY_RUNNER_STARTED_AT="$(security_runner_now)"
  : >"$SECURITY_RUNNER_EVENTS"
  SECURITY_RUNNER_INITIALIZED=1
  SECURITY_RUNNER_FINALIZED=0
  SECURITY_RUNNER_EXIT_CODE=2
}

security_runner_record() {
  local step_id="$1"
  local label="$2"
  local status="$3"
  local exit_code="$4"
  local started_at="$5"
  local finished_at="$6"
  local duration_ms="$7"
  local log_path="$8"
  local artifacts="$9"
  local reason="${10:-}"

  python3 - \
    "$SECURITY_RUNNER_EVENTS" \
    "$step_id" \
    "$label" \
    "$status" \
    "$exit_code" \
    "$started_at" \
    "$finished_at" \
    "$duration_ms" \
    "$log_path" \
    "$artifacts" \
    "$reason" <<'PY'
import json
import sys

(
    event_path,
    step_id,
    label,
    status,
    exit_code,
    started_at,
    finished_at,
    duration_ms,
    log_path,
    artifacts,
    reason,
) = sys.argv[1:]

event = {
    "id": step_id,
    "label": label,
    "status": status,
    "exitCode": int(exit_code),
    "startedAt": started_at,
    "finishedAt": finished_at,
    "durationMs": int(duration_ms),
    "log": log_path or None,
    "artifacts": [item for item in artifacts.split("\x1f") if item],
    "reason": reason or None,
}
with open(event_path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(event, separators=(",", ":")) + "\n")
PY
}

security_runner_classify() {
  local policy="$1"
  local exit_code="$2"

  if [ "$exit_code" -eq 0 ]; then
    printf 'PASS'
    return
  fi
  if [ "$exit_code" -eq 126 ] || [ "$exit_code" -eq 127 ]; then
    printf 'BLOCKED'
    return
  fi
  if [ "$exit_code" -ge 128 ]; then
    printf 'ERROR'
    return
  fi
  case "$policy" in
    scanner|guardrail)
      if [ "$exit_code" -eq 1 ]; then
        printf 'FINDING'
      else
        printf 'ERROR'
      fi
      ;;
    build)
      printf 'ERROR'
      ;;
    *)
      printf 'ERROR'
      ;;
  esac
}

# Usage:
#   run_security_step ID LABEL POLICY LOG_RELATIVE ARTIFACTS_US_SEPARATOR -- command args...
#
# The wrapped command may fail; this function records the outcome and always
# returns zero so subsequent evidence-producing steps still run.
run_security_step() {
  local step_id="$1"
  local label="$2"
  local policy="$3"
  local log_relative="$4"
  local artifacts="$5"
  shift 5
  [ "${1:-}" = "--" ] || {
    echo "run_security_step requires -- before the command" >&2
    return 2
  }
  shift

  local log_path="$SECURITY_RUNNER_REPORT_DIR/$log_relative"
  local started_at finished_at start_ns end_ns duration_ms exit_code status
  mkdir -p "$(dirname "$log_path")"
  started_at="$(security_runner_now)"
  start_ns="$(python3 -c 'import time; print(time.time_ns())')"

  echo "=== $label ==="
  if "$@" >"$log_path" 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi
  cat "$log_path"

  finished_at="$(security_runner_now)"
  end_ns="$(python3 -c 'import time; print(time.time_ns())')"
  duration_ms=$(((end_ns - start_ns) / 1000000))
  status="$(security_runner_classify "$policy" "$exit_code")"
  security_runner_record \
    "$step_id" "$label" "$status" "$exit_code" \
    "$started_at" "$finished_at" "$duration_ms" \
    "$log_relative" "$artifacts" ""
  printf '[%s] %s (exit %s)\n' "$status" "$step_id" "$exit_code"
  return 0
}

record_security_blocked() {
  local step_id="$1"
  local label="$2"
  local reason="$3"
  local log_relative="${4:-}"
  local now
  now="$(security_runner_now)"
  security_runner_record \
    "$step_id" "$label" "BLOCKED" 127 \
    "$now" "$now" 0 "$log_relative" "" "$reason"
  printf '[BLOCKED] %s: %s\n' "$step_id" "$reason"
}

security_runner_finalize() {
  local original_exit="${1:-0}"
  if [ "$SECURITY_RUNNER_INITIALIZED" -ne 1 ]; then
    SECURITY_RUNNER_EXIT_CODE="$original_exit"
    return
  fi
  if [ "$SECURITY_RUNNER_FINALIZED" -eq 1 ]; then
    return
  fi

  local result
  result="$(python3 - \
    "$SECURITY_RUNNER_EVENTS" \
    "$SECURITY_RUNNER_MANIFEST" \
    "$SECURITY_RUNNER_LAYER" \
    "$SECURITY_RUNNER_STARTED_AT" \
    "$(security_runner_now)" \
    "$original_exit" <<'PY'
import json
import os
import sys
import tempfile

events_path, manifest_path, layer, started_at, finished_at, original_exit = sys.argv[1:]
original_exit = int(original_exit)
steps = []
if os.path.exists(events_path):
    with open(events_path, "r", encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, 1):
            if not raw.strip():
                continue
            try:
                event = json.loads(raw)
            except json.JSONDecodeError as exc:
                event = {
                    "id": f"runner.event-{line_number}",
                    "label": "Manifest event decoding",
                    "status": "ERROR",
                    "exitCode": 2,
                    "startedAt": finished_at,
                    "finishedAt": finished_at,
                    "durationMs": 0,
                    "log": None,
                    "artifacts": [],
                    "reason": f"Malformed internal event record: {exc.msg}",
                }
            steps.append(event)

if original_exit != 0:
    steps.append(
        {
            "id": "runner.unhandled-exit",
            "label": "Security runner completion",
            "status": "ERROR",
            "exitCode": original_exit,
            "startedAt": finished_at,
            "finishedAt": finished_at,
            "durationMs": 0,
            "log": None,
            "artifacts": [],
            "reason": "Runner terminated outside a captured step",
        }
    )

counts = {status.lower(): 0 for status in ("PASS", "FINDING", "BLOCKED", "ERROR")}
for step in steps:
    status = step.get("status", "ERROR")
    if status not in ("PASS", "FINDING", "BLOCKED", "ERROR"):
        status = "ERROR"
        step["status"] = status
        step["reason"] = "Runner emitted an unknown status"
    counts[status.lower()] += 1

if counts["error"]:
    overall = "ERROR"
    exit_code = 2
elif counts["blocked"]:
    overall = "BLOCKED"
    exit_code = 2
elif counts["finding"]:
    overall = "FINDING"
    exit_code = 1
else:
    overall = "PASS"
    exit_code = 0

manifest = {
    "schemaVersion": "chronicle-security-manifest/v1",
    "layer": layer,
    "startedAt": started_at,
    "finishedAt": finished_at,
    "overallStatus": overall,
    "exitCode": exit_code,
    "summary": {"total": len(steps), **counts},
    "steps": steps,
}

manifest_dir = os.path.dirname(manifest_path)
fd, temporary_path = tempfile.mkstemp(
    prefix=f".{os.path.basename(manifest_path)}.",
    dir=manifest_dir,
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    os.replace(temporary_path, manifest_path)
finally:
    if os.path.exists(temporary_path):
        os.unlink(temporary_path)

print(f"{exit_code}\t{overall}\t{len(steps)}")
PY
)"
  SECURITY_RUNNER_EXIT_CODE="${result%%	*}"
  SECURITY_RUNNER_FINALIZED=1
  printf 'Security manifest: %s (%s)\n' \
    "$SECURITY_RUNNER_MANIFEST" "${result#*	}"
}

security_runner_exit_trap() {
  local original_exit="$1"
  trap - EXIT
  security_runner_finalize "$original_exit"
  exit "$SECURITY_RUNNER_EXIT_CODE"
}
