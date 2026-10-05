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


CHECKS = {
    "W51": check_w51,
    "W52": check_w52,
    "W56": check_w56,
    "W79": check_w79,
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
