#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB_BIN="${ADB:-}"
SERIAL="${ANDROID_SERIAL:-}"
PACKAGE="${CHRONICLE_ANDROID_PACKAGE:-com.openlattice.chronicle.bcmtest.debug}"
STUDY_ID="${CHRONICLE_STUDY_ID:-54a6a4ea-ae90-483f-bbdb-0d9113fe40ca}"
PARTICIPANT_ID="${CHRONICLE_PARTICIPANT_ID:-}"
DURATION_SECONDS="${CHRONICLE_LONG_RUN_SECONDS:-28800}"
CYCLE_SECONDS="${CHRONICLE_LONG_RUN_CYCLE_SECONDS:-1800}"
OUTPUT_DIR="${CHRONICLE_LONG_RUN_OUTPUT_DIR:-/tmp}"
ALLOW_CHARGING=0

usage() {
  cat <<'EOF'
Usage: scripts/chronicle-long-run-dogfood.sh [options]

Runs a long unattended dogfood cycle. Each cycle generates foreground app usage,
waits for automatic upload, records server data-quality state, and samples
battery before and after the cycle.

Options:
  --serial SERIAL           adb device serial
  --package PACKAGE         Android app id
  --study-id UUID           study UUID
  --participant-id ID       participant ID
  --duration SECONDS        total run duration, default 28800
  --cycle SECONDS           per-cycle auto-upload timeout, default 1800
  --output-dir DIR          artifact directory, default /tmp
  --allow-charging          allow plugged-in diagnostic runs
  -h, --help                show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) SERIAL="${2:?missing --serial value}"; shift 2 ;;
    --package) PACKAGE="${2:?missing --package value}"; shift 2 ;;
    --study-id) STUDY_ID="${2:?missing --study-id value}"; shift 2 ;;
    --participant-id) PARTICIPANT_ID="${2:?missing --participant-id value}"; shift 2 ;;
    --duration) DURATION_SECONDS="${2:?missing --duration value}"; shift 2 ;;
    --cycle) CYCLE_SECONDS="${2:?missing --cycle value}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:?missing --output-dir value}"; shift 2 ;;
    --allow-charging) ALLOW_CHARGING=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$PARTICIPANT_ID" && -f /tmp/chronicle-tablet-upload-test-ids.txt ]]; then
  PARTICIPANT_ID="$(sed -n '1p' /tmp/chronicle-tablet-upload-test-ids.txt)"
fi
[[ -n "$PARTICIPANT_ID" ]] || { echo "Missing participant id." >&2; exit 1; }

if [[ -z "$ADB_BIN" ]]; then
  for candidate in "$HOME/.local/android-sdk/platform-tools/adb" \
    "${ANDROID_HOME:-}/platform-tools/adb" \
    "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
    adb; do
    [[ "$candidate" == "/platform-tools/adb" ]] && continue
    if command -v "$candidate" >/dev/null 2>&1; then
      ADB_BIN="$(command -v "$candidate")"
      break
    elif [[ -x "$candidate" ]]; then
      ADB_BIN="$candidate"
      break
    fi
  done
fi
[[ -n "$ADB_BIN" ]] || { echo "adb was not found. Set ADB=/path/to/adb." >&2; exit 1; }
if [[ -z "$SERIAL" ]]; then
  SERIAL="$("$ADB_BIN" devices | awk 'NR > 1 && $2 == "device" {print $1; exit}')"
fi
[[ -n "$SERIAL" ]] || { echo "No adb device found. Pass --serial." >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$OUTPUT_DIR/chronicle-long-run-$RUN_ID"
mkdir -p "$RUN_DIR"

echo "Chronicle long-run dogfood"
echo "serial=$SERIAL"
echo "package=$PACKAGE"
echo "study_id=$STUDY_ID"
echo "participant_id=$PARTICIPANT_ID"
echo "duration_seconds=$DURATION_SECONDS cycle_seconds=$CYCLE_SECONDS"
echo "artifacts=$RUN_DIR"

"$ROOT_DIR/scripts/android-battery-drain-harness.sh" \
  --serial "$SERIAL" \
  --package "$PACKAGE" \
  --duration 1 \
  --sample 1 \
  --output-dir "$RUN_DIR" \
  ${ALLOW_CHARGING:+--allow-charging} \
  > "$RUN_DIR/battery-preflight.txt"

"$ROOT_DIR/scripts/chronicle-dogfood-report.sh" \
  --study-id "$STUDY_ID" \
  --participant-id "$PARTICIPANT_ID" \
  > "$RUN_DIR/report-before.txt"

deadline=$(( $(date +%s) + DURATION_SECONDS ))
cycle=1
while (( $(date +%s) < deadline )); do
  cycle_dir="$RUN_DIR/cycle-$cycle"
  mkdir -p "$cycle_dir"
  echo "Starting cycle $cycle at $(date -Is)"

  "$ADB_BIN" -s "$SERIAL" shell dumpsys battery > "$cycle_dir/battery-before.txt" || true

  set +e
  "$ROOT_DIR/scripts/android-auto-upload-e2e.sh" \
    --serial "$SERIAL" \
    --package "$PACKAGE" \
    --study-id "$STUDY_ID" \
    --participant-id "$PARTICIPANT_ID" \
    --timeout "$CYCLE_SECONDS" \
    --log-dir "$cycle_dir" \
    > "$cycle_dir/auto-upload.txt" 2>&1
  auto_status=$?
  set -e
  echo "$auto_status" > "$cycle_dir/auto-upload-exit-code.txt"

  "$ADB_BIN" -s "$SERIAL" shell dumpsys battery > "$cycle_dir/battery-after.txt" || true
  "$ROOT_DIR/scripts/chronicle-dogfood-report.sh" \
    --study-id "$STUDY_ID" \
    --participant-id "$PARTICIPANT_ID" \
    > "$cycle_dir/report-after.txt" || true

  if [[ "$auto_status" != "0" ]]; then
    echo "Cycle $cycle failed; see $cycle_dir/auto-upload.txt" >&2
    exit "$auto_status"
  fi
  cycle=$((cycle + 1))
done

"$ROOT_DIR/scripts/android-debug-bundle.sh" \
  --serial "$SERIAL" \
  --package "$PACKAGE" \
  --study-id "$STUDY_ID" \
  --participant-id "$PARTICIPANT_ID" \
  --output-dir "$RUN_DIR" \
  > "$RUN_DIR/debug-bundle.txt" || true

echo "PASS: long-run dogfood completed. Artifacts: $RUN_DIR"
