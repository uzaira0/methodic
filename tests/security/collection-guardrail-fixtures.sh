#!/usr/bin/env bash
# Collection modularization guardrail fixture self-check (refactor Phase 12).
#
# Confirms every collection guardrail rule actually FIRES on a known-bad fixture
# (the negative direction). The `collection` layer separately confirms the rules
# do NOT fire on real code (the positive direction). Both directions are required:
# "0 findings on real code" alone cannot distinguish a working rule from a broken
# one.
#
#   - Semgrep rules: verified with `semgrep --test` against
#     tests/security/fixtures/collection/*.kt (// rule-id annotations).
#   - ast-grep rules: each rule's `files:`/`ignores:` path scope is stripped into a
#     temp copy, then run against its fixture under
#     tests/security/fixtures/collection/astgrep/ — a non-empty SARIF is required.
#
# Usage: collection-guardrail-fixtures.sh <report-dir>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_DIR="${1:-$ROOT_DIR/tests/security/reports}"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/collection-guardrail-fixtures.txt"
: > "$REPORT"

FIX_DIR="$ROOT_DIR/tests/security/fixtures/collection"
RULES_DIR="$ROOT_DIR/tests/security/collection-rules"
AST_DIR="$ROOT_DIR/tests/security/ast-grep"

fail() { echo "FAIL: $*" | tee -a "$REPORT" >&2; exit 1; }
pass() { echo "PASS: $*" | tee -a "$REPORT"; }

command -v semgrep  >/dev/null 2>&1 || fail "semgrep not installed (required for fixture self-check)"
command -v ast-grep >/dev/null 2>&1 || fail "ast-grep not installed (required for fixture self-check)"
command -v python3  >/dev/null 2>&1 || fail "python3 not installed (required for fixture self-check)"

echo "=== Collection guardrail fixture self-check ===" | tee -a "$REPORT"

# --- Semgrep: positive fixtures must pass `semgrep --test`. ---
if semgrep --test --config "$RULES_DIR/collection-modularization.yaml" \
     "$FIX_DIR/SemgrepPositiveFixtures.kt" >>"$REPORT" 2>&1; then
  pass "Semgrep collection-modularization rules fire on positive fixtures"
else
  fail "Semgrep collection-modularization rules did not match their positive fixtures"
fi

if semgrep --test --config "$RULES_DIR/collection-dto.yaml" \
     "$FIX_DIR/SecretDtoPositiveFixture.kt" >>"$REPORT" 2>&1; then
  pass "Semgrep collection-dto rule fires on its positive fixture"
else
  fail "Semgrep collection-dto rule did not match its positive fixture"
fi

# --- ast-grep: each rule, scope-stripped, must fire on its fixture. ---
TMP_RULES="$(mktemp -d)"
trap 'rm -rf "$TMP_RULES"' EXIT

# rule-id -> fixture file (relative to FIX_DIR)
ast_fixture() {
  case "$1" in
    collection-module-id-no-raw-string)             echo "astgrep/collection/other/RawModuleIdFixture.kt" ;;
    collection-queue-insert-only-in-sink)           echo "astgrep/collection/other/DirectQueueInsertFixture.kt" ;;
    collection-sensor-insert-only-in-sink)          echo "astgrep/collection/other/DirectSensorInsertFixture.kt" ;;
    collection-hardware-service-only-via-manager)   echo "astgrep/collection/other/DirectServiceStartFixture.kt" ;;
    collection-lifecycle-record-only-via-module)    echo "astgrep/collection/other/DirectRecordAsyncFixture.kt" ;;
    collection-worker-no-direct-sensor-instantiation) echo "astgrep/services/usage/NewUsageWorkerFixture.kt" ;;
    collection-settings-service-no-rls-context-call) echo "astgrep/services/settings/SettingsServiceFixture.kt" ;;
    *) echo "" ;;
  esac
}

for rule in collection-module-id-no-raw-string \
            collection-queue-insert-only-in-sink \
            collection-sensor-insert-only-in-sink \
            collection-hardware-service-only-via-manager \
            collection-lifecycle-record-only-via-module \
            collection-worker-no-direct-sensor-instantiation \
            collection-settings-service-no-rls-context-call; do
  fixture="$FIX_DIR/$(ast_fixture "$rule")"
  [[ -f "$fixture" ]] || fail "Missing ast-grep fixture for $rule"
  # Strip files:/ignores: path-scope blocks so the rule applies regardless of the
  # fixture's path (the fixture lives under tests/, not the production tree).
  python3 - "$AST_DIR/$rule.yml" "$TMP_RULES/$rule.yml" <<'PY'
import re, sys
src = open(sys.argv[1]).read().splitlines()
out, skip = [], False
for line in src:
    if re.match(r'^(files|ignores):', line):
        skip = True
        continue
    if skip and re.match(r'^\s*-', line):
        continue
    skip = False
    out.append(line)
open(sys.argv[2], 'w').write('\n'.join(out) + '\n')
PY
  # ast-grep exits non-zero when it finds an error-level match; with `set -o
  # pipefail` that would poison a pipeline, so capture SARIF to a file first.
  sarif_out="$TMP_RULES/$rule.fixture.sarif"
  ast-grep scan --rule "$TMP_RULES/$rule.yml" "$fixture" --format sarif \
    > "$sarif_out" 2>/dev/null || true
  count="$(python3 -c 'import sys,json; print(len(json.load(open(sys.argv[1]))["runs"][0]["results"]))' \
    "$sarif_out" 2>/dev/null || echo 0)"
  if [[ "$count" -ge 1 ]]; then
    pass "ast-grep $rule fires on its positive fixture ($count finding(s))"
  else
    fail "ast-grep $rule did NOT fire on its positive fixture — rule is broken"
  fi
done

echo "Collection guardrail fixture self-check complete. Report: $REPORT" | tee -a "$REPORT"
