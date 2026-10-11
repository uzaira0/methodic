#!/usr/bin/env python3
"""Select or check a Compose subnet against the host's Docker networks."""

import ipaddress
import json
import subprocess
import sys
import shutil


def docker_networks():
    ids = subprocess.run(
        ["docker", "network", "ls", "-q"],
        check=True, capture_output=True, text=True,
    ).stdout.split()
    return json.loads(subprocess.run(
        ["docker", "network", "inspect", *ids],
        check=True, capture_output=True, text=True,
    ).stdout) if ids else []


def is_own(other, project):
    # Name alone is not ownership: a hand-made network can carry the same name, and Compose
    # refuses to adopt it. Only this project's Compose-created default network is excluded.
    labels = other.get("Labels") or {}
    return (other["Name"] == f"{project}_default"
            and labels.get("com.docker.compose.project") == project
            and labels.get("com.docker.compose.network") == "default")


def overlap(wanted, existing, project):
    for other in existing:
        if is_own(other, project):
            continue
        for config in (other.get("IPAM") or {}).get("Config") or []:
            subnet = config.get("Subnet")
            if not subnet:
                continue
            held = ipaddress.ip_network(subnet, strict=False)
            for want in wanted:
                if held.version == want.version and held.overlaps(want):
                    return want, other["Name"], held
    return None


def host_networks(existing, project):
    own_bridges = {network.get("Options", {}).get("com.docker.network.bridge.name") or "br-" + network.get("Id", "")[:12]
                   for network in existing if is_own(network, project)}
    if shutil.which("ip"):
        routes = []
        for family in ("-4", "-6"):
            routes += json.loads(subprocess.run(["ip", family, "-j", "route", "show", "table", "all"],
                                               capture_output=True, text=True, check=True).stdout)
        return [{"Name": "host route " + route.get("dev", "unknown"), "IPAM": {"Config": [{"Subnet": route["dst"]}]}}
                for route in routes if route.get("dst", "default") != "default" and route.get("dev") not in own_bridges]
    if sys.platform != "darwin":
        raise ValueError("iproute2 is required to check institutional/VPN routes")
    routes = subprocess.run(["netstat", "-rn"], capture_output=True, text=True, check=True).stdout
    result = []
    for line in routes.splitlines():
        fields = line.split()
        if not fields or fields[0] == "default":
            continue
        try:
            destination = fields[0]
            address, separator, prefix = destination.partition('/')
            if ':' not in address and all(part.isdigit() for part in address.split('.')):
                octets = address.split('.')
                destination = '.'.join(octets + ['0'] * (4 - len(octets))) + '/' + (prefix if separator else str(8 * len(octets)))
            subnet = ipaddress.ip_network(destination, strict=False)
        except ValueError:
            continue
        result.append({"Name": "host route", "IPAM": {"Config": [{"Subnet": str(subnet)}]}})
    return result


def select(default, project):
    wanted = ipaddress.ip_network(default)
    try:
        existing = docker_networks()
    except (OSError, subprocess.CalledProcessError, ValueError):
        existing = []
    existing += host_networks(existing, project)
    if not overlap([wanted], existing, project):
        print(default)
        return
    # Avoid Docker's usual 172.16/12 and 192.168/16 address pools.
    for index in range(256):
        candidate = ipaddress.ip_network(f"10.253.{index}.0/24")
        if not overlap([candidate], existing, project):
            print(candidate)
            return
    sys.exit("no free subnet in 10.253.0.0/16; set CHRONICLE_SUBNET in .env to a free private range")


def check():
    config = json.load(sys.stdin)
    network = (config.get("networks") or {}).get("default") or {}
    wanted = [
        ipaddress.ip_network(config["subnet"], strict=False)
        for config in (network.get("ipam") or {}).get("config") or []
        if config.get("subnet")
    ]
    if not wanted:
        return
    existing = docker_networks()
    conflict = overlap(wanted, existing + host_networks(existing, config.get("name")), config.get("name"))
    if conflict:
        want, name, held = conflict
        sys.exit(f"CHRONICLE_SUBNET {want} overlaps Docker network {name} ({held}); "
                 "set CHRONICLE_SUBNET in .env to a free private range")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["check"]:
            check()
        elif len(sys.argv) == 4 and sys.argv[1] == "select":
            select(sys.argv[2], sys.argv[3])
        else:
            sys.exit("usage: network-subnet.py check | select DEFAULT PROJECT")
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        sys.exit(f"could not check CHRONICLE_SUBNET against Docker networks: {error}")
