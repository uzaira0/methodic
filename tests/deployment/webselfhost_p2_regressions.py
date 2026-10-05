#!/usr/bin/env python3
"""Focused deployment regressions for the 2026-10-03 webselfhost audit."""

from __future__ import annotations

import ast
import hashlib
import json
import importlib.util
import inspect
import ipaddress
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def check_w11() -> None:
    snippets = read("selfhost/caddy/snippets.caddy")
    routes = read("chronicle-server/src/main/kotlin/com/openlattice/chronicle/filters/ResearcherApiKeyRoutes.kt")
    caddyfiles = [read(f"selfhost/Caddyfile.split{suffix}") for suffix in ("", ".local", ".tls")]
    docs = read("selfhost/docs/DEPLOYMENT-COMPATIBILITY.md")

    assert "@researcherNoApiKey" in snippets and "respond @researcherNoApiKey 404" in snippets
    matcher = re.search(r"@researcherNoApiKey\s*\{([^}]*)\}", snippets, re.S)
    assert matcher, "the public denial must be scoped to researcher-only V3 exports without an API key"
    block = matcher.group(1)
    assert "not header X-Api-Key *" in block
    assert "time-use-diary/[^/]+/(data|participants/data)" in block
    assert "survey/[^/]+/questionnaire/[^/]+/data" in block
    assert "time-use-diary/[^/]+/ids" in snippets and "questionnaire/[^/]+/responses" in snippets
    assert 'Route("GET", TUD, "/data", READ_ONLY)' in routes
    assert 'Route("GET", TUD, "/participants/data", READ_ONLY)' in routes
    assert 'Route("GET", SURVEY, "/questionnaire/$SEGMENT/data", READ_ONLY)' in routes
    assert all("import chronicle_deny_researcher_v3" in caddy for caddy in caddyfiles)
    assert all("import chronicle_strip_researcher_bearer" in caddy for caddy in caddyfiles)
    assert "X-Api-Key" in docs and "public" in docs.lower() and "scoped" in docs.lower()


def check_w12() -> None:
    snippets = read("selfhost/caddy/snippets.caddy")
    matchers = re.findall(r"(?m)^\s*@(?:hashed path_regexp|shell not path_regexp) (.+)$", snippets)
    assert len(matchers) == 2 and matchers[0] == matchers[1]
    pattern = re.compile(matchers[0])
    assert pattern.fullmatch("/chunk-app123.js")
    assert pattern.fullmatch("/chunk-style9.css")

    fonts = ROOT / "chronicle-web" / "vendor" / "equal" / "packages" / "tokens" / "dist" / "fonts"
    font_files = sorted(fonts.glob("*.woff2"))
    assert font_files, "the build's font inventory must exercise the immutable matcher"
    for font in font_files:
        digest = hashlib.sha256(font.read_bytes()).hexdigest()[:8]
        assert pattern.fullmatch(f"/fonts/{font.stem}-{digest}.woff2"), font.name
    assert not pattern.fullmatch("/fonts/atkinson-hyperlegible-latin-400-normal.woff2")
    assert not pattern.fullmatch("/index.html")
    assert 'header @hashed Cache-Control "public, max-age=31536000, immutable"' in snippets
    assert 'header @shell Cache-Control "no-cache"' in snippets


def check_w13() -> None:
    backend = yaml.safe_load(read("docker/docker-compose.traefik.yml"))["services"]["chronicle-backend"]
    raw_labels = backend["labels"]
    if isinstance(raw_labels, dict):
        labels = {str(key): str(value) for key, value in raw_labels.items()}
    else:
        labels = dict(label.split("=", 1) for label in raw_labels)
    for router in ("chronicle-mobile", "chronicle-mobile-proxy-fallback", "chronicle-web"):
        chain = labels[f"traefik.http.routers.{router}.middlewares"].split(",")
        assert "chronicle-compress" in chain, (router, chain)
    assert labels["traefik.http.middlewares.chronicle-compress.compress"] == "true"


def check_w16() -> None:
    for path in (
        "docker/keycloak/realm-chronicle.json.template",
        "k8s/base/keycloak/realm-chronicle.json.template",
    ):
        realm = json.loads(read(path))
        assert realm.get("bruteForceProtected") is True, path
        assert realm.get("permanentLockout") is False, path
        assert realm.get("failureFactor") == 5, path
        assert realm.get("waitIncrementSeconds") == 60, path
        assert realm.get("minimumQuickLoginWaitSeconds") == 60, path
        assert realm.get("maxFailureWaitSeconds") == 900, path
        assert realm.get("quickLoginCheckMilliSeconds") == 1000, path


def check_w49() -> None:
    expected = "oven/bun:1.3.12-alpine@sha256:26d8996560ca94eab9ce48afc0c7443825553c9a851f40ae574d47d20906826d"
    for path in ("selfhost/Dockerfile.frontend", "docker/Dockerfile.frontend.prod"):
        assert f"FROM {expected} AS builder" in read(path), path
    package = json.loads(read("chronicle-web/package.json"))
    assert package.get("engines", {}).get("bun") == ">=1.3.12"
    assert package.get("devDependencies", {}).get("bun") == "1.3.12"


def check_w51() -> None:
    compose = yaml.safe_load(read("selfhost/docker-compose.yml"))
    subnet = "${CHRONICLE_SUBNET:-172.28.0.0/16}"
    backend = compose["services"]["backend"]["environment"]
    guard = compose["services"]["config-guard"]["environment"]
    assert backend["CHRONICLE_TRUSTED_PROXY_CIDRS"] == subnet
    assert guard["CHRONICLE_SUBNET"] == subnet
    assert guard["CHRONICLE_TRUSTED_PROXY_CIDRS"] == subnet
    assert compose["networks"]["default"]["ipam"]["config"][0]["subnet"] == subnet

    validator = ROOT / "selfhost" / "guard-config.sh"

    def accepted(network: str, trusted: str) -> bool:
        result = subprocess.run(
            ["bash", str(validator), "--validate-compose-subnet", network, trusted],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return result.returncode == 0

    assert accepted("192.168.240.0/24", "192.168.240.0/24")
    assert not accepted("192.168.240.0/24", "172.28.0.0/16")
    assert not accepted("8.8.8.0/24", "8.8.8.0/24")
    assert not accepted("192.168.240.1/24", "192.168.240.1/24")
    docs = read("selfhost/docs/DEPLOYMENT-COMPATIBILITY.md")
    assert "CHRONICLE_SUBNET" in docs and "CHRONICLE_TRUSTED_PROXY_CIDRS" in docs


def check_w52() -> None:
    caddyfiles = [read(f"selfhost/Caddyfile.split{suffix}") for suffix in ("", ".local", ".tls")]
    for caddy in caddyfiles:
        assert "trusted_proxies static {$CADDY_TRUSTED_PROXIES:127.0.0.1/32}" in caddy
        assert "trusted_proxies_strict" in caddy
        assert "client_ip_headers X-Forwarded-For" in caddy
        assert "trusted_proxies static private_ranges" not in caddy
    compose = yaml.safe_load(read("selfhost/docker-compose.yml"))
    assert compose["services"]["web"]["environment"]["CADDY_TRUSTED_PROXIES"] == (
        "${CADDY_TRUSTED_PROXIES:-127.0.0.1/32}"
    )
    snippets = read("selfhost/caddy/snippets.caddy")
    assert "key {client_ip}" in snippets

    def strict_client_ip(forwarded: str, remote: str, trusted: list[str]) -> str:
        networks = [ipaddress.ip_network(cidr) for cidr in trusted]
        chain = [part.strip() for part in forwarded.split(",") if part.strip()] + [remote]
        for address in reversed(chain):
            candidate = ipaddress.ip_address(address)
            if any(candidate in network for network in networks):
                continue
            return address
        return remote

    assert strict_client_ip(
        "203.0.113.7, 198.51.100.9", "10.40.0.12", ["10.40.0.0/24"]
    ) == "198.51.100.9"
    assert strict_client_ip("", "198.51.100.10", ["10.40.0.0/24"]) == "198.51.100.10"
    validator = ROOT / "selfhost" / "guard-config.sh"
    valid = subprocess.run(
        ["bash", str(validator), "--validate-forwarder-cidrs", "10.40.0.0/24 2001:db8:1234::/48"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    broad = subprocess.run(
        ["bash", str(validator), "--validate-forwarder-cidrs", "0.0.0.0/0"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert valid.returncode == 0 and broad.returncode != 0
    docs = read("selfhost/docs/DEPLOYMENT-COMPATIBILITY.md")
    assert "CADDY_TRUSTED_PROXIES" in docs and "right" in docs.lower()


def check_w54() -> None:
    dockerfile = read("selfhost/Dockerfile.caddy")
    assert re.search(r"^USER 10001:0$", dockerfile, re.M), "Caddy image must default to the edge UID"
    assert "chown -R 10001:0 /data /config" in dockerfile

    compose = yaml.safe_load(read("selfhost/docker-compose.yml"))
    services = compose["services"]
    web = services["web"]
    init = services["caddy-storage-init"]
    assert web["user"] == "10001:0"
    assert "ALL" in web["cap_drop"] and "NET_BIND_SERVICE" in web["cap_add"]
    assert web["read_only"] is True
    assert web["depends_on"]["caddy-storage-init"]["condition"] == "service_completed_successfully"
    assert init["user"] == "0:0" and init["cap_drop"] == ["ALL"]
    assert init["cap_add"] == ["CHOWN"] and init["read_only"] is True
    assert "chown -R 10001:0 /data /config" in " ".join(init["command"])
    assert {"caddy_data:/data", "caddy_config:/config"}.issubset(set(init["volumes"]))

    monitoring = yaml.safe_load(read("selfhost/overlays/monitoring.yml"))["services"]["metrics-exporter"]
    assert monitoring["user"] == "10001:0"
    assert "ALL" in monitoring["cap_drop"] and not monitoring.get("cap_add")
    assert any("uid=10001,gid=0" in mount for mount in monitoring["tmpfs"])

    cert_init = read("selfhost/cert-init.sh")
    assert 'chown "${TLS_OWNER}:0" "$1"' in cert_init
    assert 'protect "$TLS_DIR/key.pem" 640' in cert_init
    assert 'protect "$KEY" 640' in cert_init
    for overlay in (
        "selfhost/overlays/mode-behind-proxy-internal.yml",
        "selfhost/overlays/mode-own-tls-internal.yml",
        "selfhost/overlays/mode-local-https.yml",
    ):
        content = yaml.safe_load(read(overlay))["services"]
        assert "cert-init" in content and "web" in content, overlay
        assert any(":/etc/caddy/certs:ro" in volume for volume in content["web"]["volumes"]), overlay
    local_export = yaml.safe_load(read("selfhost/overlays/mode-local-https.yml"))["services"]["ca-export"]
    assert local_export["user"] == "0:0", "host certificate export remains a privileged one-shot"


def check_w55() -> None:
    compose = yaml.safe_load(read("selfhost/docker-compose.yml"))["services"]
    postgres = compose["postgres"]
    assert postgres["read_only"] is True
    assert "postgres_data:/data/db" in postgres["volumes"]
    assert "postgres_tde_keyring:/var/lib/postgresql/tde-keyring" in postgres["volumes"]
    postgres_tmpfs = postgres["tmpfs"]
    assert any(mount.startswith("/tmp:size=") for mount in postgres_tmpfs)
    assert any(mount.startswith("/var/run/postgresql:size=") for mount in postgres_tmpfs)
    assert all("size=" in mount for mount in postgres_tmpfs)

    backup = yaml.safe_load(read("selfhost/overlays/backups.yml"))["services"]["db-backup"]
    assert backup["read_only"] is True
    assert any(mount.startswith("/tmp:size=") for mount in backup["tmpfs"])
    assert "${CHRONICLE_STATE_DIR:-.}/backups:/backups" in backup["volumes"]

    ca_export = yaml.safe_load(read("selfhost/overlays/mode-local-https.yml"))["services"]["ca-export"]
    assert ca_export["read_only"] is True
    assert any(mount.startswith("/tmp:size=") for mount in ca_export["tmpfs"])
    assert "${CHRONICLE_STATE_DIR:-.}/tls:/out" in ca_export["volumes"]


def check_w56() -> None:
    builder = ast.parse(read("scripts/build-selfhost-release.py"))
    main = next(node for node in builder.body if isinstance(node, ast.FunctionDef) and node.name == "main")
    root_files = next(
        node.value
        for node in ast.walk(main)
        if isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == "root_files" for target in node.targets)
    )
    assert isinstance(root_files, ast.List)
    inventory = {element.value for element in root_files.elts if isinstance(element, ast.Constant)}
    assert "network-policy.sh" in inventory, "the source-free release bundle omits its network-policy helper"
    assert (ROOT / "selfhost" / "network-policy.sh").is_file()
    assert any(
        isinstance(node, ast.For)
        and isinstance(node.target, ast.Name)
        and node.target.id == "name"
        and isinstance(node.iter, ast.Name)
        and node.iter.id == "root_files"
        for node in ast.walk(main)
    ), "the bundle builder must copy every declared root inventory item"


def check_w61() -> None:
    compose = yaml.safe_load(read("docker/docker-compose.traefik.yml"))["services"]
    vault = compose["vault"]
    assert "ALL" in vault["cap_drop"]
    assert vault["cap_add"] == ["IPC_LOCK"]
    socket_proxy = compose["docker-socket-proxy"]
    assert 1 <= socket_proxy["pids_limit"] <= 128
    assert socket_proxy["environment"]["POST"] == 0
    assert "/var/run/docker.sock:/var/run/docker.sock:ro" in socket_proxy["volumes"]


def check_w76() -> None:
    compose = yaml.safe_load(read("selfhost/docker-compose.yml"))["services"]["backend"]
    env = compose["environment"]
    defaults = {
        "CHRONICLE_EXPORT_MAX_ROWS": "1000000",
        "CHRONICLE_EXPORT_MAX_BYTES": "536870912",
        "CHRONICLE_EXPORT_MAX_RUNTIME_SECONDS": "1800",
        "CHRONICLE_EXPORT_MAX_TOTAL_BYTES": "8589934592",
        "CHRONICLE_EXPORT_MIN_FREE_BYTES": "1073741824",
    }
    example = read("selfhost/.env.example")
    for name, default in defaults.items():
        documented = re.findall(rf"(?m)^{re.escape(name)}=([0-9]+)$", example)
        assert documented == [default], (name, documented, default)
    chosen = {
        "CHRONICLE_EXPORT_MAX_ROWS": "250000",
        "CHRONICLE_EXPORT_MAX_BYTES": "10485760",
        "CHRONICLE_EXPORT_MAX_RUNTIME_SECONDS": "90",
        "CHRONICLE_EXPORT_MAX_TOTAL_BYTES": "1073741824",
        "CHRONICLE_EXPORT_MIN_FREE_BYTES": "10485760",
    }

    def rendered(expression: str, supplied: dict[str, str]) -> str:
        match = re.fullmatch(r"\$\{([A-Z0-9_]+):-([0-9]+)\}", expression)
        assert match
        value = supplied.get(match.group(1), "")
        return value if value else match.group(2)

    for name, default in defaults.items():
        expression = env[name]
        match = re.fullmatch(r"\$\{([A-Z0-9_]+):-([0-9]+)\}", expression)
        assert match and match.group(1) == name and match.group(2) == default, (name, expression)
        assert rendered(expression, {name: chosen[name]}) == chosen[name]
        assert rendered(expression, {}) == default
        assert rendered(expression, {name: ""}) == default
        assert int(default) > 0 and int(chosen[name]) > 0
    writer = read("chronicle-server/src/main/kotlin/com/openlattice/chronicle/services/export/ExportFileWriter.kt")
    assert writer.count('positiveLongSetting(') >= 5
    assert "toLongOrNull()?.takeIf { it > 0 }" in writer
    docs = read("selfhost/docs/DEPLOYMENT-COMPATIBILITY.md")
    docs_text = " ".join(docs.lower().split())
    assert all(name in docs for name in defaults)
    assert "positive decimal integers" in docs_text and "defaults" in docs_text
    assert "fails backend startup" in docs_text


def check_w79() -> None:
    guard = ROOT / "selfhost" / "guard-config.sh"

    def allowed(host: str) -> bool:
        result = subprocess.run(
            ["bash", str(guard), "--validate-public-host", host],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return result.returncode == 0

    for host in (
        "study.hospital.corp",
        "gateway.home",
        "mail.example.mail",
        "chronicle.internal",
        "host.home.arpa",
        "device.lan",
        "service.local",
        "server.invalid",
        "study.example.org",
    ):
        assert not allowed(host), host
    assert allowed("study.university.edu")
    assert not allowed("192.168.1.50")  # the local-https mode continues accepting private LAN addresses
    setup = read("selfhost/chronicle")
    assert 'bash ./guard-config.sh --validate-public-host "$domain"' in setup
    docs = read("selfhost/docs/DEPLOYMENT-COMPATIBILITY.md").lower()
    assert "corp" in docs and "home" in docs and "mail" in docs and "local-https" in docs


def check_cross_s02() -> None:
    example = read("selfhost/.env.example")
    assert re.search(r"(?m)^CHRONICLE_SESSION_IDLE_MINUTES=15$", example)
    compose = yaml.safe_load(read("selfhost/docker-compose.yml"))["services"]
    expected_expression = "${CHRONICLE_SESSION_IDLE_MINUTES:-15}"
    for service in ("config-guard", "backend"):
        assert compose[service]["environment"]["CHRONICLE_SESSION_IDLE_MINUTES"] == expected_expression

    guard = ROOT / "selfhost" / "guard-config.sh"

    def allowed(value: str) -> bool:
        result = subprocess.run(
            ["bash", str(guard), "--validate-session-idle-minutes", value],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return result.returncode == 0

    def compose_value(supplied: str | None) -> str:
        match = re.fullmatch(r"\$\{([A-Z0-9_]+):-([0-9]+)\}", expected_expression)
        assert match
        return supplied or match.group(2)

    for supplied in (None, "", "1", "15", "120"):
        assert allowed(compose_value(supplied)), supplied
    for invalid in ("0", "121", "-1", "1.0", "abc", "1000", "000"):
        assert not allowed(compose_value(invalid)), invalid

    server_config = read(
        "chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/ChronicleAuthConfiguration.kt"
    )
    assert 'System.getenv("CHRONICLE_SESSION_IDLE_MINUTES")?.toLong() ?: 15' in server_config
    assert "require(sessionIdleMinutes in 1..120)" in server_config
    for path in ("selfhost/README.md", "selfhost/docs/DEPLOYMENT-COMPATIBILITY.md"):
        docs = read(path)
        assert "CHRONICLE_SESSION_IDLE_MINUTES" in docs and "120" in docs and "15" in docs


CHECKS = {
    "W11": check_w11,
    "W12": check_w12,
    "W13": check_w13,
    "W16": check_w16,
    "W49": check_w49,
    "W51": check_w51,
    "W52": check_w52,
    "W54": check_w54,
    "W55": check_w55,
    "W56": check_w56,
    "W61": check_w61,
    "W76": check_w76,
    "W79": check_w79,
    "CROSS-S02": check_cross_s02,
}


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "--all":
        for name, check in CHECKS.items():
            check()
            print(f"{name} deployment regression passed")
        return
    if len(sys.argv) != 2 or sys.argv[1] not in CHECKS:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} --all|{'|'.join(CHECKS)}")
    CHECKS[sys.argv[1]]()
    print(f"{sys.argv[1]} deployment regression passed")


if __name__ == "__main__":
    main()
