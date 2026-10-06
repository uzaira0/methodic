#!/usr/bin/env python3
"""Select or check a Compose subnet against the host's Docker networks."""

import ipaddress
import json
import subprocess
import sys


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


def select(default, project):
    wanted = ipaddress.ip_network(default)
    try:
        existing = docker_networks()
    except (OSError, subprocess.CalledProcessError, ValueError):
        # Setup can retain the example default when the daemon is unavailable.
        print(default)
        return
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
    conflict = overlap(wanted, docker_networks(), config.get("name"))
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
