#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
WORK_DIR=/home/opt/chronicle_work/launch-audit-1003/sol/webselfhost-logs
RUN_DIR="$(mktemp -d "${WORK_DIR}/W24.XXXXXX")"
trap 'rm -rf -- "$RUN_DIR"' EXIT
CHRONICLE_SCRIPT="${ROOT_DIR}/selfhost/chronicle"

fail() {
  echo "self-host upgrade receipt regression failed: $*" >&2
  exit 1
}

run_case() {
  local name="$1" child_exit="$2" expected_outcome="$3"
  local case_dir="${RUN_DIR}/${name}" old_dir new_dir command_dir receipt_dir receipt_count status
  old_dir="${case_dir}/old/selfhost"
  new_dir="${case_dir}/new/selfhost"
  command_dir="${case_dir}/commands"
  receipt_dir="${old_dir}/operator-receipts/operations"
  mkdir -p "$old_dir/overlays" "$new_dir" "$command_dir"
  cp "$CHRONICLE_SCRIPT" "${new_dir}/chronicle"
  chmod 0755 "${new_dir}/chronicle"
  cat >"${old_dir}/.env" <<'EOF'
COMPOSE_PROJECT_NAME=chronicle-operator-w24
CHRONICLE_STATE_DIR=.
COMPOSE_FILE=docker-compose.yml:overlays/mode-behind-proxy-internal.yml:overlays/monitoring.yml
MOBILE_SIGNING_ENABLED=false
MOBILE_SIGNING_REQUIRED=false
MOBILE_SIGNING_SECRET=
MOBILE_SIGNING_SECRET_PREVIOUS=
RELEASE_VERSION=2026.10.2
EOF
  chmod 0600 "${old_dir}/.env"
  touch "${old_dir}/docker-compose.yml" \
    "${old_dir}/overlays/mode-behind-proxy-internal.yml" \
    "${old_dir}/overlays/monitoring.yml"
  cat >"${new_dir}/upgrade.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --from && "$2" == "$UPGRADE_TEST_OLD_DIR" ]] || exit 93
if [[ "$UPGRADE_TEST_CHILD_EXIT" -ne 0 ]]; then
  exit "$UPGRADE_TEST_CHILD_EXIT"
fi
sed "s|^CHRONICLE_STATE_DIR=.*$|CHRONICLE_STATE_DIR=$UPGRADE_TEST_OLD_DIR|" \
  "$UPGRADE_TEST_OLD_DIR/.env" >.env
chmod 0600 .env
SH
  chmod 0755 "${new_dir}/upgrade.sh"
  cat >"${command_dir}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *' ps --status running --services '* ]]; then
  printf '%s\n' operational-probe
  exit 0
fi
if [[ " $* " == *' run --rm --no-deps --entrypoint /monitoring/record-operation.sh operational-probe '* ]]; then
  printf 'metric:%s\n' "$*" >>"$UPGRADE_TEST_METRIC_LOG"
fi
SH
  chmod 0755 "${command_dir}/docker"

  if (
    cd "$new_dir"
    env \
      "PATH=${command_dir}:${PATH}" \
      "UPGRADE_TEST_OLD_DIR=${old_dir}" \
      "UPGRADE_TEST_CHILD_EXIT=${child_exit}" \
      "UPGRADE_TEST_METRIC_LOG=${case_dir}/metrics.log" \
      ./chronicle upgrade --from "$old_dir"
  ) >"${case_dir}/output.log" 2>&1; then
    status=0
  else
    status=$?
  fi
  if [[ "$expected_outcome" == failure ]]; then
    [[ "$status" -ne 0 ]] || fail "$name unexpectedly succeeded"
  else
    [[ "$status" -eq 0 ]] || {
      cat "${case_dir}/output.log" >&2
      fail "$name failed with status $status"
    }
  fi

  [[ -d "$receipt_dir" ]] || fail "$name wrote no operator operation receipt"
  receipt_count="$(find "$receipt_dir" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d '[:space:]')"
  [[ "$receipt_count" == 1 ]] || fail "$name wrote $receipt_count operation receipts instead of one"
  python3 - "$receipt_dir" "$expected_outcome" <<'PY'
import json
from pathlib import Path
import sys

files = list(Path(sys.argv[1]).glob("*.json"))
assert len(files) == 1, files
payload = json.loads(files[0].read_text(encoding="utf-8"))
assert payload["operation"] == "upgrade", payload
assert payload["outcome"] == sys.argv[2], payload
assert payload["failureCategory"] == ("upgrade_failed" if sys.argv[2] == "failure" else "none"), payload
PY
  [[ -f "${case_dir}/metrics.log" ]] || fail "$name recorded no monitoring event"
  [[ "$(grep -c '^metric:' "${case_dir}/metrics.log")" == 1 ]] ||
    fail "$name recorded more than one monitoring event"
  grep -Fq "metric:compose -p chronicle-operator-w24 run --rm --no-deps --entrypoint /monitoring/record-operation.sh operational-probe upgrade ${expected_outcome}" \
    "${case_dir}/metrics.log" || fail "$name recorded the wrong monitoring outcome"
}

run_case upgrade-failure 41 failure
run_case upgrade-success 0 success
echo 'PASS: failed and successful upgrades each write one matching receipt and metric'
