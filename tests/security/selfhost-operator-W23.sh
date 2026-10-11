#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
WORK_DIR="${SELFHOST_OPERATOR_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-operator-W23}"
mkdir -p "$WORK_DIR"
RUN_DIR=$(mktemp -d "${WORK_DIR}/W23.XXXXXX")
trap 'rm -rf -- "$RUN_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$RUN_DIR/bin" "$RUN_DIR/selfhost"
cp "$ROOT_DIR/selfhost/chronicle" "$RUN_DIR/selfhost/chronicle"
/bin/cp -R "${ROOT_DIR}/selfhost/chronicle_ops" "$RUN_DIR/selfhost/"
export CHRONICLE_FIXTURE_OPS="$ROOT_DIR/selfhost"
cat >"$RUN_DIR/bin/docker" <<'SH'
#!/usr/bin/env python3
import json
import os
import sys
from datetime import datetime, timezone
sys.path.insert(0, os.environ["CHRONICLE_FIXTURE_OPS"])
from chronicle_ops.verify import MONITORING_JOBS
args = sys.argv[1:]
if args[0] == "inspect":
    print("healthy")
elif "ps" in args:
    if "-q" in args:
        print("fixture-container")
    else:
        print("postgres\nbackend\nweb\nvictoriametrics\nvictorialogs\nfluent-bit\ngrafana\noperational-probe")
elif "exec" in args:
    command = " ".join(args)
    if "pg_database_size" in command:
        print("Filesystem 1024-blocks Used Available Capacity Mounted on")
        print("fixture 100000000 1000000 99000000 1% /data")
        print(json.dumps({"database_bytes": 1024, "wal_bytes": 0, "max_wal_bytes": 1024}))
    elif "api/v1/targets" in command:
        print(json.dumps({"data": {"activeTargets": [{"labels": {"job": job}, "health": "up",
            "lastScrape": datetime.now(timezone.utc).isoformat()} for job in MONITORING_JOBS]}}))
    elif "failure_category%3A" in command:
        print(args[-1].split("failure_category%3A")[1])
    elif "has_table_privilege" in command:
        print("t")
SH
cat >"$RUN_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${!#}" in
  https://chronicle.example.org/health) printf 204 ;;
  https://chronicle.example.org/chronicle/) printf 200 ;;
  *) exit 99 ;;
esac
SH
chmod +x "$RUN_DIR/bin/curl"
chmod +x "$RUN_DIR/bin/docker"
cat >"$RUN_DIR/bin/df" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' \
  'fixture 100000000 1000000 99000000 1% /'
SH
chmod +x "$RUN_DIR/bin/df"

write_env() {
  local webhook="$1"
  cat >"$RUN_DIR/selfhost/.env" <<EOF
COMPOSE_PROJECT_NAME=operator-w23
COMPOSE_FILE=docker-compose.yml:overlays/monitoring.yml
DOMAIN=chronicle.example.org
HTTP_BIND=127.0.0.1
HTTP_PORT=8080
INTERNAL_BIND=127.0.0.1
INTERNAL_PORT=8081
MOBILE_SIGNING_ENABLED=false
MOBILE_SIGNING_REQUIRED=false
CHRONICLE_ALERT_WEBHOOK_URL=${webhook}
EOF
  chmod 600 "$RUN_DIR/selfhost/.env"
}

write_env ''
status=0
PATH="$RUN_DIR/bin:$PATH" bash "$RUN_DIR/selfhost/chronicle" doctor --json >"$RUN_DIR/empty.json" || status=$?
[[ $status -eq 0 ]] || { cat "$RUN_DIR/empty.json" >&2; fail "doctor exited $status with the synthetic stack healthy"; }
python3 - "$RUN_DIR/empty.json" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
row = next(item for item in payload["checks"] if item["check"] == "alert-route")
assert row["status"] == "warn", row
assert "CHRONICLE_ALERT_WEBHOOK_URL" in row["recoveryCommand"], row
assert "webhook" not in row["likelyCause"].lower() or "unset" in row["likelyCause"].lower(), row
PY

write_env 'https://alerts.invalid/fixture'
status=0
PATH="$RUN_DIR/bin:$PATH" bash "$RUN_DIR/selfhost/chronicle" doctor --json >"$RUN_DIR/configured.json" || status=$?
[[ $status -eq 0 ]] || { cat "$RUN_DIR/configured.json" >&2; fail "configured doctor exited $status with the synthetic stack healthy"; }
python3 - "$RUN_DIR/configured.json" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
row = next(item for item in payload["checks"] if item["check"] == "alert-route")
assert row["status"] == "ok", row
assert "alerts.invalid" not in json.dumps(payload), "doctor exposed the configured webhook URL"
PY

grep -Fq 'Alert delivery is not configured' "$ROOT_DIR/selfhost/chronicle" ||
  fail 'setup does not warn that the default alert route is local only'
grep -Fq 'reports `alert-route`' "$ROOT_DIR/selfhost/docs/MONITORING-RUNBOOK.md" ||
  fail 'monitoring runbook does not explain the alert-route doctor check'
echo 'PASS: selfhost operator alert destination readiness'
