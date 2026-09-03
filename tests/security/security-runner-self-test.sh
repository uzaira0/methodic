#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/security/security-runner-lib.sh
source "$script_dir/security-runner-lib.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

pass_step() {
  echo "pass"
}

finding_step() {
  echo "finding"
  return 1
}

error_step() {
  echo "error"
  return 2
}

later_step() {
  echo "later"
  : >"$work_dir/later-ran"
}

security_runner_init "self-test" "$work_dir"
run_security_step "self.pass" "Self-test pass" "guardrail" "pass.log" "" -- pass_step
run_security_step "self.finding" "Self-test finding" "guardrail" "finding.log" "" -- finding_step
run_security_step "self.error" "Self-test error" "guardrail" "error.log" "" -- error_step
record_security_blocked "self.blocked" "Self-test blocked" "synthetic prerequisite is unavailable"
run_security_step "self.later" "Self-test later step" "guardrail" "later.log" "" -- later_step
security_runner_finalize 0

[ "$SECURITY_RUNNER_EXIT_CODE" -eq 2 ]
[ -f "$work_dir/later-ran" ]

python3 - "$work_dir/security-manifest-self-test.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

assert manifest["schemaVersion"] == "chronicle-security-manifest/v1"
assert manifest["overallStatus"] == "ERROR"
assert manifest["exitCode"] == 2
assert manifest["summary"] == {
    "total": 5,
    "pass": 2,
    "finding": 1,
    "blocked": 1,
    "error": 1,
}
assert [step["id"] for step in manifest["steps"]] == [
    "self.pass",
    "self.finding",
    "self.error",
    "self.blocked",
    "self.later",
]
PY

set +e
(
  set -euo pipefail
  security_runner_init "unhandled" "$work_dir/unhandled"
  trap 'security_runner_exit_trap $?' EXIT
  run_security_step \
    "unhandled.before" "Step before unhandled exit" "guardrail" \
    "before.log" "" -- pass_step
  false
)
unhandled_status=$?
set -e

[ "$unhandled_status" -eq 2 ]
python3 - "$work_dir/unhandled/security-manifest-unhandled.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

assert manifest["overallStatus"] == "ERROR"
assert manifest["exitCode"] == 2
assert manifest["summary"] == {
    "total": 2,
    "pass": 1,
    "finding": 0,
    "blocked": 0,
    "error": 1,
}
assert [step["id"] for step in manifest["steps"]] == [
    "unhandled.before",
    "runner.unhandled-exit",
]
PY

echo "Security runner capture-all self-test passed"
