#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
OPERATOR_CLI="${ROOT_DIR}/selfhost/chronicle"

fail() {
  echo "self-host monitoring timeout test failed: $*" >&2
  exit 1
}

bash -n "$OPERATOR_CLI"

# Load only the two functions under test. Sourcing the whole operator command would
# execute its command dispatcher and couple this focused test to Docker.
eval "$(awk '
  /^terminate_host_process_tree\(\)/ { copying = 1 }
  /^write_operation_receipt\(\)/ { exit }
  copying { print }
' "$OPERATOR_CLI")"

warn() { printf 'warning: %s\n' "$1" >&2; }
export COMPOSE_FILE=overlays/monitoring.yml

# Speed up the watchdog without changing the command it supervises. The fake Compose
# operation is deliberately long-lived and must be terminated with its child process.
sleep() { /bin/sleep 0.1; }
# Loaded record_operation resolves this fixture dynamically.
# shellcheck disable=SC2329
dc() {
  if [[ "${1:-}" == ps ]]; then
    printf '%s\n' operational-probe
  else
    /bin/sleep 60013
  fi
}

timeout_output="$(record_operation restore success none 2>&1)"
[[ "$timeout_output" == *'could not be recorded within 15 seconds'* ]] ||
  fail "a stuck monitoring writer did not produce the bounded warning"
if pgrep -f '^/bin/sleep 60013$' >/dev/null 2>&1; then
  fail "the bounded monitoring writer left its child process running"
fi

# A healthy writer must return immediately without waiting for the watchdog.
# shellcheck disable=SC2329
dc() {
  if [[ "${1:-}" == ps ]]; then
    printf '%s\n' operational-probe
  else
    return 0
  fi
}
normal_output="$(record_operation restore success none 2>&1)"
[[ -z "$normal_output" ]] || fail "a successful monitoring writer emitted a warning"

echo "self-host monitoring timeout test passed"
