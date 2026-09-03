#!/usr/bin/env python3
"""Local tests for the private monitoring assets and Viewer API client."""

from __future__ import annotations

import json
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[2]
USERS: dict[str, dict] = {}
NEXT_ID = 1


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

    alert_text = json.dumps(alerts)
    assert "chronicle_tde_expected * (1 - chronicle_tde_healthy)" in alert_text
    assert "database-connection-pressure" in alert_text

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
