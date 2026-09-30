#!/usr/bin/env python3
"""Local tests for the private monitoring assets and Viewer API client."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[2]
USERS: dict[str, dict] = {}
NEXT_ID = 1


def probe_certificate_check() -> None:
    scratch_parent = Path(os.environ.get(
        "SELFHOST_MONITORING_TEST_ROOT",
        ROOT / "build/operator-test-runs/selfhost-monitoring",
    ))
    scratch_parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    run_root = Path(tempfile.mkdtemp(prefix="probe-certificates.", dir=scratch_parent))
    try:
        bin_dir = run_root / "bin"
        tls_dir = run_root / "tls-fixture"
        metrics_dir = run_root / "metrics-fixture"
        bin_dir.mkdir()
        tls_dir.mkdir()
        metrics_dir.mkdir()
        (tls_dir / "internal-cert.fixture").write_text("fixture certificate", encoding="utf-8")
        external_log = run_root / "external-check.log"
        external_args = run_root / "external-openssl-args.log"

        probe_source = (ROOT / "selfhost/monitoring/probe.sh").read_text(encoding="utf-8")
        probe_source = probe_source.replace("/tls/internal-cert.pem", str(tls_dir / "internal-cert.fixture"))
        probe_source = probe_source.replace("/metrics", str(metrics_dir))
        probe = run_root / "probe.sh"
        probe.write_text(probe_source, encoding="utf-8")
        probe.chmod(0o700)

        stubs = {
            "date": """#!/usr/bin/env bash
if [[ ${1:-} == +%s ]]; then printf '1800000000'; exit 0; fi
if [[ ${1:-} == -d ]]; then
  case ${2:-} in
    PUBLIC_EXPIRY) printf '1900000000' ;;
    INTERNAL_EXPIRY) printf '2000000000' ;;
    *) exit 1 ;;
  esac
  exit 0
fi
exit 1
""",
            "pg_isready": "#!/usr/bin/env bash\nexit 1\n",
            "curl": "#!/usr/bin/env bash\nexit 0\n",
            "wget": "#!/usr/bin/env bash\nexit 0\n",
            "timeout": """#!/usr/bin/env bash
shift
printf 'checked\\n' >>"$PROBE_TEST_EXTERNAL_LOG"
exec "$@"
""",
            "openssl": """#!/usr/bin/env bash
if [[ ${1:-} == s_client ]]; then
  printf '%s\\n' "$*" >>"$PROBE_TEST_OPENSSL_ARGS"
  printf 'served-public\\n'
  exit 0
fi
if [[ ${1:-} == x509 ]]; then
  cert_path=''
  while (($#)); do
    if [[ $1 == -in ]]; then cert_path=$2; shift 2; else shift; fi
  done
  if [[ -n $cert_path ]]; then printf 'notAfter=INTERNAL_EXPIRY\\n'; else
    read -r marker
    [[ $marker == served-public ]] || exit 1
    printf 'notAfter=PUBLIC_EXPIRY\\n'
  fi
  exit 0
fi
exit 1
""",
        }
        for name, contents in stubs.items():
            path = bin_dir / name
            path.write_text(contents, encoding="utf-8")
            path.chmod(0o700)

        env = os.environ.copy()
        env.update({
            "PATH": f"{bin_dir}:/usr/bin:/bin",
            "PROBE_TEST_EXTERNAL_LOG": str(external_log),
            "PROBE_TEST_OPENSSL_ARGS": str(external_args),
            "PROBE_INTERVAL_SECONDS": "300",
            "POSTGRES_PASSWORD": "fixture-postgres-password",
            "DOMAIN": "private-configured-domain.test",
            "PUBLIC_TLS_URL": "https://public-origin.example.test:8443/study",
            "INTERNAL_HEALTH_URL": "https://web:8081/health",
            "LOGS_HEALTH_URL": "http://victorialogs:9428/health",
        })
        process = subprocess.Popen(
            ["/bin/bash", str(probe)], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            deadline = time.monotonic() + 10
            output = metrics_dir / "operational.prom"
            while time.monotonic() < deadline and not output.exists():
                if process.poll() is not None:
                    raise AssertionError("probe exited before writing its metrics")
                time.sleep(0.05)
            assert output.exists(), "probe did not write operational metrics"
            metrics = output.read_text(encoding="utf-8")
            assert "chronicle_certificate_expiry_timestamp_seconds 1900000000" in metrics
            assert "chronicle_internal_certificate_expiry_timestamp_seconds 2000000000" in metrics
            assert external_log.read_text(encoding="utf-8") == "checked\n"
            assert "-connect public-origin.example.test:8443 -servername public-origin.example.test" in external_args.read_text(encoding="utf-8")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    finally:
        shutil.rmtree(run_root)


class GrafanaStub(BaseHTTPRequestHandler):
    def log_message(self, *_args) -> None:
        pass

    def reply(self, status: int, payload: dict | None = None) -> None:
        body = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self) -> dict:
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")

    def do_GET(self) -> None:
        login = parse_qs(urlparse(self.path).query).get("loginOrEmail", [""])[0]
        user = USERS.get(login)
        self.reply(200, user) if user else self.reply(404, {"message": "not found"})

    def do_POST(self) -> None:
        global NEXT_ID
        payload = self.body()
        assert self.path == "/api/admin/users"
        user = {"id": NEXT_ID, "login": payload["login"], "password": payload["password"], "role": "Viewer"}
        NEXT_ID += 1
        USERS[user["login"]] = user
        self.reply(200, {"id": user["id"]})

    def do_PATCH(self) -> None:
        payload = self.body()
        user = next(user for user in USERS.values() if user["id"] == int(self.path.rsplit("/", 1)[1]))
        user["role"] = payload["role"]
        self.reply(200, {"message": "updated"})

    def do_PUT(self) -> None:
        payload = self.body()
        user_id = int(self.path.split("/")[4])
        user = next(user for user in USERS.values() if user["id"] == user_id)
        user["password"] = payload["password"]
        self.reply(200, {"message": "updated"})

    def do_DELETE(self) -> None:
        user_id = int(self.path.rsplit("/", 1)[1])
        login = next(login for login, user in USERS.items() if user["id"] == user_id)
        del USERS[login]
        self.reply(200, {"message": "deleted"})


def viewer_call(base: str, operation: str, password: str) -> str:
    fields = [base, "test-admin-password", operation, "observer", password]
    result = subprocess.run(
        ["python3", str(ROOT / "selfhost/monitoring/grafana-user.py")],
        input=b"\0".join(field.encode() for field in fields) + b"\0",
        check=True,
        capture_output=True,
    )
    output = (result.stdout + result.stderr).decode()
    assert "test-admin-password" not in output
    assert not password or password not in output
    return output


def main() -> None:
    probe_certificate_check()
    server = ThreadingHTTPServer(("127.0.0.1", 0), GrafanaStub)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        viewer_call(base, "add", "first-viewer-password")
        assert USERS["observer"]["role"] == "Viewer"
        viewer_call(base, "reset", "second-viewer-password")
        assert USERS["observer"]["password"] == "second-viewer-password"
        viewer_call(base, "remove", "")
        assert "observer" not in USERS
    finally:
        server.shutdown()
        server.server_close()
        thread.join()

    alerts = json.loads((ROOT / "selfhost/monitoring/grafana-alerting/rules.yml").read_text())
    runbooks = (ROOT / "selfhost/monitoring/runbooks.html").read_text()
    for group in alerts["groups"]:
        for rule in group["rules"]:
            anchor = rule["annotations"]["runbook_url"].rsplit("#", 1)[1]
            assert f'id="{anchor}"' in runbooks, f"missing runbook anchor: {anchor}"

    rules = {rule["uid"]: rule for group in alerts["groups"] for rule in group["rules"]}
    # Failed erasure/retention deletion and failed restore/upgrade are data-integrity failures.
    for uid in ("deletion-failures", "operation-failed"):
        assert rules[uid]["labels"]["severity"] == "critical", f"{uid} must be critical"
    login_expr = rules["failed-login-spike"]["data"][0]["model"]["expr"]
    for needle in ("chronicle_api_errors_total", "dashboard-login", "401"):
        assert needle in login_expr, f"failed-login-spike expr lacks {needle}"
    permission_expr = rules["permission-change"]["data"][0]["model"]["expr"]
    for needle in ("/v3/permissions", 'method="PATCH"', "(roles|permissions)", "POST|DELETE"):
        assert needle in permission_expr, f"permission-change expr lacks {needle}"

    policies_text = (ROOT / "selfhost/monitoring/grafana-alerting/notification-policies.yml").read_text()
    json.loads(policies_text)
    assert "mute_time_intervals" not in policies_text and "muteTimes" not in policies_text, \
        "notification routing must not be muted; an attached channel has to receive alerts"
    contact_points = json.loads((ROOT / "selfhost/monitoring/grafana-alerting/contactpoints.yml").read_text())
    receiver = contact_points["contactPoints"][0]["receivers"][0]
    assert receiver["settings"]["url"] == "$CHRONICLE_ALERT_WEBHOOK_URL"
    overlay = (ROOT / "selfhost/overlays/monitoring.yml").read_text()
    assert "CHRONICLE_ALERT_WEBHOOK_URL: ${CHRONICLE_ALERT_WEBHOOK_URL:-" in overlay
    assert "CHRONICLE_ALERT_WEBHOOK_URL=" in (ROOT / "selfhost/.env.example").read_text()
    runbook_md = (ROOT / "selfhost/docs/MONITORING-RUNBOOK.md").read_text()
    assert "## Attach a notification channel" in runbook_md
    assert "permanently muted" not in runbook_md

    alert_text = json.dumps(alerts)
    assert "chronicle_tde_expected * (1 - chronicle_tde_healthy)" in alert_text
    assert "database-connection-pressure" in alert_text
    assert "chronicle_certificate_expiry_timestamp_seconds" in alert_text
    assert "chronicle_internal_certificate_expiry_timestamp_seconds" in alert_text

    dashboard = json.loads((ROOT / "selfhost/monitoring/grafana-dashboards/system-overview.json").read_text())
    certificate_panels = {panel["title"]: panel for panel in dashboard["panels"] if "certificate" in panel["title"].casefold()}
    assert "Public certificate days remaining" in certificate_panels
    assert "Internal certificate days remaining" in certificate_panels
    assert "chronicle_certificate_expiry_timestamp_seconds" in certificate_panels["Public certificate days remaining"]["targets"][0]["expr"]
    assert "chronicle_internal_certificate_expiry_timestamp_seconds" in certificate_panels["Internal certificate days remaining"]["targets"][0]["expr"]

    sanitizer = (ROOT / "selfhost/monitoring/sanitize.lua").read_text()
    assert 'source["message"]' not in sanitizer
    assert 'source["stack"]' not in sanitizer
    assert 'record["log"]' in sanitizer  # accepted as input, never emitted verbatim
    fluent = (ROOT / "selfhost/monitoring/fluent-bit.conf").read_text()
    for source in ("chronicle.audit", "chronicle.operator", "chronicle.*", "chronicle.postgres"):
        assert source in fluent
    compose = (ROOT / "selfhost/docker-compose.yml").read_text()
    assert "LOG_FORMAT: json" in compose
    assert "log_line_prefix=chronicle_pg" in compose
    release_smoke = (ROOT / "tests/smoke/selfhost-release-smoke.sh").read_text()
    assert "cadvisor_version_info" not in release_smoke
    assert '.labels.job == "chronicle-containers"' in release_smoke
    assert "up%7Bjob%3D%22chronicle-containers%22%7D%20%3D%3D%201" in release_smoke
    assert "monitoring_deadline=$((SECONDS + 60))" in release_smoke
    caddy_access_log = (ROOT / "selfhost/caddy/snippets.caddy").read_text()
    for source_redaction in (
        "format filter {",
        "request>headers delete",
        "request>uri delete",
        "request>remote_ip ip_mask 16 32",
        "request>client_ip ip_mask 16 32",
        "wrap json",
    ):
        assert source_redaction in caddy_access_log
    assert "password" not in (ROOT / "selfhost/monitoring/record-operation.sh").read_text().casefold()
    operator = (ROOT / "selfhost/chronicle").read_text()
    receipt_start = operator.index("write_operation_receipt()")
    receipt_end = operator.index("\noperation_exit()", receipt_start)
    receipt_writer = operator[receipt_start:receipt_end]
    for field in ("operation", "timestamp", "releaseVersion", "outcome", "failureCategory"):
        assert f'"{field}"' in receipt_writer
    for forbidden in ("PASSWORD", "SECRET", "TOKEN", "viewer"):
        assert forbidden not in receipt_writer
    print("self-host monitoring tests passed")


if __name__ == "__main__":
    main()
