"""Shared operator output and subprocess calls."""

import os
import fcntl
import json
import ipaddress
from pathlib import Path
import re
import signal
import subprocess
import sys

RED, GRN, YEL, BLD, RST = "\033[31m", "\033[32m", "\033[33m", "\033[1m", "\033[0m"
WRITABLE_ROOT_REASON_LABEL = "org.chronicle.security.writable-root-reason"
OPERATION_LOCK = ".reconcile.lock"
OPERATION_LOCK_MODE = 0o644  # Contains no data; older bundle preflights require readability.
LOCK_FD_ENV = "CHRONICLE_OPERATION_LOCK_FD"
GIB = 1024 ** 3
MIN_FREE_INODES = 10_000
UPDATE_PEAK_BYTES = 3 * GIB
PREPARATION_TIMEOUT_SECONDS = 600


MEMORY_HEADROOM_BYTES = GIB // 2


def require_memory(settings, available_kib, monitoring=False):
    from .release import value
    keys = ["POSTGRES", "BACKEND", "WEB", "FRONTEND", "BACKUP"]
    fixed = 0
    if monitoring:
        keys += ["CADVISOR", "VICTORIAMETRICS", "VICTORIALOGS", "FLUENT_BIT", "OPERATIONAL_PROBE", "METRICS_EXPORTER", "GRAFANA"]
        fixed = (128 + 64) * 1024 ** 2  # Monitoring config and Docker API proxy.
    required = MEMORY_HEADROOM_BYTES + fixed
    for key in keys:
        raw = value(settings, key + "_MEM_LIMIT")
        match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([kmgt]?)(?:b)?", raw.lower())
        if not match:
            raise ValueError("invalid memory ceiling: " + key)
        required += int(float(match[1]) * 1024 ** ("kmgt".index(match[2]) + 1 if match[2] else 0))
    if required > available_kib * 1024:
        raise ValueError(f"selected service ceilings plus host headroom need {required // 1024 ** 2} MiB; host has {available_kib // 1024}. Disable monitoring or review memory ceilings before setup")
    return required


def storage_report(state, project, floor_gib=5, peak_bytes=0):
    info = run(["docker", "info", "--format", "{{.DockerRootDir}}"], capture=True, timeout=15, check=True)
    paths = {"state": Path(state), "docker-data": Path(info.stdout.strip())}
    containers = run(["docker", "ps", "-a", "-q", "--filter", f"label=com.docker.compose.project={project}",
                      "--filter", "label=com.docker.compose.service=postgres"], capture=True, timeout=15, check=True)
    if containers.stdout.strip():
        inspected = run(["docker", "inspect", *containers.stdout.split()], capture=True, timeout=15, check=True)
        for container in json.loads(inspected.stdout):
            pgdata = next((entry.partition("=")[2] for entry in container["Config"]["Env"] if entry.startswith("PGDATA=")), None)
            if not pgdata:
                raise ValueError("cannot identify PostgreSQL's actual PGDATA mount")
            for mount in container["Mounts"]:
                if Path(pgdata).is_relative_to(mount["Destination"]):
                    paths["database-volume"] = Path(mount["Source"])
    else:
        volumes = run(["docker", "volume", "ls", "-q", "--filter", f"label=com.docker.compose.project={project}",
                       "--filter", "label=com.docker.compose.volume=postgres_data"], capture=True, timeout=15, check=True)
        if volumes.stdout.strip():
            inspected = run(["docker", "volume", "inspect", *volumes.stdout.split()], capture=True, timeout=15, check=True)
            for volume in json.loads(inspected.stdout):
                device = (volume.get("Options") or {}).get("device", "")
                paths["database-volume"] = Path(device if device.startswith("/") else volume["Mountpoint"])
    rows = []
    for name, path in paths.items():
        try:
            try:
                disk = os.statvfs(path)
            except PermissionError:
                # Protected descendants still share the filesystem's accessible mount point.
                mounts = [Path(re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), line.split()[4]))
                          for line in Path("/proc/self/mountinfo").read_text().splitlines()]
                mount = max((mount for mount in mounts if mount == path or mount in path.parents), key=lambda mount: len(mount.parts))
                disk = os.statvfs(mount)
            free, inodes = disk.f_bavail * disk.f_frsize, disk.f_favail
            enough_inodes = disk.f_files == 0 or inodes >= MIN_FREE_INODES
        except (PermissionError, FileNotFoundError):
            if name == "state":
                raise
            from .release import read_env, value
            image = os.environ.get("POSTGRES_IMAGE") or value(read_env(Path.cwd() / ".env"), "POSTGRES_IMAGE")
            measured = run(["docker", "run", "--rm", "--pull", "never", "--network", "none", "--read-only",
                            "--cap-drop", "ALL", "--user", "0", "--mount", f"type=bind,src={path},dst=/storage,readonly",
                            "--entrypoint", "/bin/bash", image, "-ceu", "df -Pk /storage; df -Pi /storage"],
                           capture=True, timeout=15, check=True).stdout.splitlines()
            free, inodes = int(measured[1].split()[3]) * 1024, int(measured[3].split()[3])
            enough_inodes = inodes >= MIN_FREE_INODES
        required = int(floor_gib) * GIB + (peak_bytes if name != "database-volume" else 0)
        enough = free >= required and enough_inodes
        rows.append((name, enough, free, inodes, required))
    return rows


def require_storage(state, project, floor_gib=5, peak_bytes=0):
    for name, enough, free, inodes, required in storage_report(state, project, floor_gib, peak_bytes):
        if not enough:
            raise ValueError(f"{name}: {free} bytes and {inodes} inodes free; require {required} bytes and {MIN_FREE_INODES} inodes before mutation")


def acquire_operation_lock(state, blocking=True):
    path = Path(state) / OPERATION_LOCK
    inherited = os.environ.get(LOCK_FD_ENV, "")
    if inherited.isdigit():
        try:
            if os.path.samestat(os.fstat(int(inherited)), path.stat()):
                fcntl.flock(int(inherited), fcntl.LOCK_EX)
                os.fchmod(int(inherited), OPERATION_LOCK_MODE)
                return None
        except OSError:
            pass
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        os.fchmod(descriptor, OPERATION_LOCK_MODE)
    except BaseException:
        os.close(descriptor)
        raise
    os.environ[LOCK_FD_ENV] = str(descriptor)
    return descriptor


def release_operation_lock(descriptor):
    if descriptor is not None:
        os.environ.pop(LOCK_FD_ENV, None)
        os.close(descriptor)


def dashboard_ca(tls):
    tls = Path(tls)
    anchor, certificate = tls / "internal-ca.crt", tls / "internal-cert.pem"
    if anchor.is_file() and run(["openssl", "verify", "-no_check_time", "-CAfile", str(anchor),
                                str(certificate)], quiet=True, timeout=10).returncode == 0:
        return anchor
    return certificate


def authority(host, port):
    return f"[{host}]:{port}" if ":" in host and not host.startswith("[") else f"{host}:{port}"


def dashboard_origin(settings):
    from .release import value
    return value(settings, "DASHBOARD_BASE_URL") or "https://" + authority(
        value(settings, "INTERNAL_BIND") or "127.0.0.1", value(settings, "INTERNAL_PORT") or "8081")


def compose_gateway(subnet):
    return str(ipaddress.ip_network(subnet).network_address + 1)


def loopback_networks(cidrs):
    networks = [ipaddress.ip_network(cidr) for cidr in cidrs.split()]
    return bool(networks) and all(network.is_loopback for network in networks)


class Interrupted(BaseException):
    def __init__(self, signum):
        self.status = 128 + signum


def interrupted(signum, _frame):
    raise Interrupted(signum)


def warn(message):
    print("{}warning:{} {}".format(YEL, RST, message), file=sys.stderr)


def run(args, capture=False, quiet=False, timeout=None, **kwargs):
    if timeout is None and any(arg in ("pull", "config", "info", "inspect") for arg in args):
        timeout = PREPARATION_TIMEOUT_SECONDS
    descriptor = os.environ.get(LOCK_FD_ENV, "")
    if descriptor.isdigit():
        kwargs.setdefault("pass_fds", (int(descriptor),))
    streams = dict(text=True, stdout=subprocess.PIPE if capture else subprocess.DEVNULL if quiet else None,
                   stderr=kwargs.pop("stderr", subprocess.DEVNULL if quiet else None))
    if timeout is None:
        return subprocess.run(args, **streams, **kwargs)
    data, check = kwargs.pop("input", None), kwargs.pop("check", False)
    if data is not None:
        kwargs["stdin"] = subprocess.PIPE
    with subprocess.Popen(args, start_new_session=True, **streams, **kwargs) as process:
        try:
            output, errors = process.communicate(data, timeout=timeout)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.communicate(timeout=1)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                pass
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate()
            raise
        if check and process.returncode:
            raise subprocess.CalledProcessError(process.returncode, args, output, errors)
        return subprocess.CompletedProcess(args, process.returncode, output, errors)


def compose(*args, **kwargs):
    return run(["docker", "compose", "-p", os.environ["CHRONICLE_OPS_PROJECT"], *args], **kwargs)


def application_services(services):
    return ["backend", "web", "db-init"] + (["db-backup"] if "db-backup" in services else [])
