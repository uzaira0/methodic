#!/usr/bin/env bash
# Collection modularization guardrail — design §4 catalog rule #10.
#
# Backend upload endpoints must keep their batch-size validation (design §1D.1,
# decision #8: public upload endpoints remain stable). This is a positive
# presence check: every Android/sensor upload service must still contain its
# `require(... .size <= <limit>)` batch guard. Semgrep's `pattern-not` form is
# brittle here (a minor signature refactor silently disables the rule), so the
# guard is asserted by a deterministic grep instead.
#
# Usage: collection-upload-validation-guardrail.sh <report-dir>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_DIR="${1:-$ROOT_DIR/tests/security/reports}"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/collection-upload-validation.txt"
: > "$REPORT"

UPLOAD_DIR="$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/services/upload"

fail() {
  echo "FAIL: $*" | tee -a "$REPORT" >&2
  exit 1
}
pass() {
  echo "PASS: $*" | tee -a "$REPORT"
}

echo "=== Collection upload batch-validation guardrail (catalog #10) ===" | tee -a "$REPORT"

# Each upload service and the literal batch-size guard it must retain.
# Pattern: `require(<collection>.size <= <int-literal>)`.
declare -A SERVICES=(
  ["AppDataUploadService.kt"]='require\([A-Za-z_]+\.size <= [0-9_]+\)'
  ["AndroidSensorDataUploadService.kt"]='require\([A-Za-z_]+\.size <= [0-9_]+\)'
  ["SensorDataUploadService.kt"]='require\([A-Za-z_]+\.size <= [0-9_]+\)'
)

for svc in "${!SERVICES[@]}"; do
  file="$UPLOAD_DIR/$svc"
  [[ -f "$file" ]] || fail "Upload service missing: $file"
  if ! grep -Eq "${SERVICES[$svc]}" "$file"; then
    fail "$svc lost its upload-batch size guard (require(...size <= <limit>)). Design §1D.1 requires upload endpoints keep batch validation."
  fi
  pass "$svc keeps its upload-batch size validation"
done

echo "Collection upload batch-validation guardrail complete. Report: $REPORT" | tee -a "$REPORT"
