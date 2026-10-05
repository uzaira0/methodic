#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
WORK_DIR=/home/opt/chronicle_work/launch-audit-1003/sol/webselfhost-logs
RUN_DIR=$(mktemp -d "${WORK_DIR}/W23.XXXXXX")
trap 'rm -rf -- "$RUN_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$RUN_DIR/bin" "$RUN_DIR/selfhost"
cp "$ROOT_DIR/selfhost/chronicle" "$RUN_DIR/selfhost/chronicle"
cat >"$RUN_DIR/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == info ]]; then exit 0; fi
[[ "${1:-}" == compose ]] || exit 0
shift
while (($#)); do
  case "$1" in
    -p|--project-name) shift 2 ;;
    *) break ;;
  esac
done
case "${1:-}" in
  config) exit 0 ;;
  ps)
    printf '%s\n' postgres backend web victoriametrics victorialogs fluent-bit grafana operational-probe
    ;;
  exec)
    [[ "$*" == *api/v1/targets* ]] && printf '{"health":"up"}\n'
    exit 0
    ;;
  run) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$RUN_DIR/bin/docker"

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
