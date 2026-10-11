"""Verified release handoff with a quiesced rollback backup."""

import datetime
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time

from .reconcile import ENABLED_ENV, RECOVERY_PHASE, RECOVERY_FILE, preflight

from .common import Interrupted, acquire_operation_lock, release_operation_lock, application_services, require_storage, UPDATE_PEAK_BYTES, run, warn
from .receipts import durable_replace, finish_operation, write_json
from .release import (ROLLBACK_DUMP, compose_names, compose_release, free_disk_floor, merge_env, postgres_major, postgres_sql,
                      read_env, read_manifest, release_command, require, require_no_encrypted_collection,
                      rollback_dump, value, require_current_owner, cleanup_releases)


def upgrade(source_dir):
    new = Path.cwd().resolve()
    old = Path(source_dir).resolve()
    held = generated = stopped = started = False
    partial = None
    status = 1
    began = time.monotonic()
    timeout = "300"
    lock = None
    operation_ready = False
    operation_lock = None

    def old_compose(*args, **kwargs):
        return compose_release(old, project, names, *args, **kwargs)

    def new_compose(*args, **kwargs):
        return compose_release(new, project, names, *args, **kwargs)

    def checked(call, message, *args, **kwargs):
        result = call(*args, **kwargs)
        require(result.returncode == 0, message)
        return result.stdout

    def write_receipt(result):
        receipt_data["status"] = result
        write_json(receipt, receipt_data)

    try:
        require(old != new, "--from must name a different release directory")
        require(old.is_dir(), f"previous selfhost directory does not exist: {old}")
        old_env = old / ".env"
        require(old_env.is_file() and not old_env.is_symlink(),
                f"previous release .env must be a regular file: {old_env}")
        mode = stat.S_IMODE(old_env.stat().st_mode)
        require(mode == 0o600, f"previous release .env is mode {mode:o}; run chmod 600 {old_env} before upgrading")
        settings = read_env(old_env)
        state = (old / (value(settings, "CHRONICLE_STATE_DIR", ".") or ".")).resolve()
        operation_lock = acquire_operation_lock(state)
        require(stat.S_IMODE(old_env.stat().st_mode) == 0o600, "previous release .env must have mode 0600")
        settings = read_env(old_env)
        require((old / (value(settings, "CHRONICLE_STATE_DIR", ".") or ".")).resolve() == state,
                "previous state location changed while acquiring the lock; retry the upgrade")
        project = value(settings, "COMPOSE_PROJECT_NAME", "chronicle-selfhost")
        os.environ.setdefault(ENABLED_ENV, value(settings, ENABLED_ENV, "true"))
        os.environ.update(CHRONICLE_OPS_PROJECT=project, CHRONICLE_OPS_STATE=str(state),
                          CHRONICLE_OPS_VERSION=value(settings, "RELEASE_VERSION", "unknown"),
                          COMPOSE_FILE=value(settings, "COMPOSE_FILE"))
        operation_ready = True
        for tool in ("docker", "python3"):
            require(shutil.which(tool), f"required command is unavailable: {tool}")
        require(run(["docker", "compose", "version"], quiet=True).returncode == 0,
                "the Docker Compose plugin is unavailable")
        require_current_owner(old, state, project)
        require(not os.path.lexists(new / ".env"),
                "new release already has .env; refusing to overwrite it (extract a clean bundle)")
        for directory, label in ((old, "previous"), (new, "new")):
            require((directory.parent / "release-manifest.json").is_file(),
                    f"{label} release manifest is missing: {directory}/../release-manifest.json")
        try:
            previous, old_key = read_manifest(old.parent / "release-manifest.json", False)
            target, new_key = read_manifest(new.parent / "release-manifest.json", True)
            require(new_key > old_key, f"new release {target['release_version']} must be newer than previous release {previous['release_version']}")
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(str(error), file=sys.stderr)
            raise ValueError("release bundle validation failed; the running release was not changed") from None
        old_version, new_version = previous["release_version"], target["release_version"]
        try:
            for key in settings:
                require(not key.startswith("COMPOSE_") or key in {"COMPOSE_FILE", "COMPOSE_PROJECT_NAME"},
                        f"unsupported Compose control setting in previous .env: {key}; remove it and retry")
            require(not any(char in str(state) for char in ("\n", "\r", "\t", "'")),
                    "CHRONICLE_STATE_DIR contains an unsupported control character or quote")
            require(re.fullmatch(r"[a-z0-9][a-z0-9_-]*", project),
                    f"invalid COMPOSE_PROJECT_NAME in previous .env: {project!r}")
            names = compose_names(settings, old)
        except ValueError as error:
            print(str(error), file=sys.stderr)
            raise ValueError("previous deployment configuration is not safe to upgrade") from None
        backups = state / "backups"
        require(backups.is_dir(), f"previous backups directory is missing: {backups}")
        require((state / "tls").is_dir(), f"previous TLS directory is missing: {state / 'tls'}")
        lock = state / ".chronicle-upgrade.lock"
        others = ((".chronicle-secret-rotation", "secret rotation"), (".chronicle-restore.lock", "restore"))
        for name, label in others:
            require(not os.path.lexists(state / name),
                    f"a {label} is active or incomplete ({state / name}); finish its documented recovery before upgrading")
        try:
            lock.mkdir(mode=0o700)
        except OSError:
            raise ValueError(f"another upgrade may be active (lock exists: {lock}). If no upgrade process is running, remove only that empty directory and retry.") from None
        held = True
        for name, label in others:
            require(not os.path.lexists(state / name),
                    f"a {label} started while the upgrade lock was being acquired; upgrade did not start")
        postgres = checked(old_compose, "previous PostgreSQL container is not running", "ps", "-q", "postgres", capture=True).strip()
        require(postgres, "previous PostgreSQL container is not running")
        health = checked(run, "could not inspect previous PostgreSQL", ["docker", "inspect", "--format",
                         '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}', postgres], capture=True).strip()
        require(health == "healthy", f"previous PostgreSQL is not healthy (state: {health})")
        version_num = postgres_sql(postgres, "SHOW server_version_num")
        require(version_num.isdigit(), "running PostgreSQL returned an invalid server_version_num")
        old_major = int(version_num) // 10000
        require_no_encrypted_collection(postgres, "the previous release was not changed", "upgrade")
        print(f"Preparing Chronicle {old_version} -> {new_version}.")
        print(f"  previous release: {old}\n  preserved state:  {state}")
        merge_env(settings, (new / ".env.example").read_text(), new / ".env", state, names)
        generated = True
        require_storage(state, project, free_disk_floor(settings), UPDATE_PEAK_BYTES)
        print("Validating new release configuration and pulling immutable images.")
        for args in (("config", "--quiet"), ("pull", "--policy", "missing"),
                     ("run", "--rm", "--no-deps", "config-guard")):
            new_compose(*args, check=True)
        config = checked(new_compose, "could not resolve the new PostgreSQL image", "config", "--format", "json", capture=True)
        image = json.loads(config)["services"]["postgres"]["image"]
        version_text = checked(run, f"could not inspect the PostgreSQL version in {image}",
                               ["docker", "run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL",
                                "--entrypoint", "postgres", image, "--version"], capture=True)
        new_major = postgres_major(version_text, image)
        require(new_major == old_major,
                f"automatic upgrade refuses PostgreSQL major {old_major} -> {new_major} against the same data volume. Follow docs/POSTGRES-18-UPGRADE.md for a dump/restore major upgrade.")
        print(f"  PostgreSQL major {old_major} is compatible with the running data volume.")
        require(run(["python3", str(new / "network-subnet.py"), "check"], input=config).returncode == 0,
                "the new release network range is not free on this host; the previous release was left running")
        timeout = os.environ.get("UPGRADE_WAIT_TIMEOUT_SECONDS", value(settings, "START_WAIT_TIMEOUT_SECONDS", "3600"))
        require(re.fullmatch("[1-9][0-9]*", timeout), "UPGRADE_WAIT_TIMEOUT_SECONDS must be a positive integer")
        require(int(timeout) <= 3600, "UPGRADE_WAIT_TIMEOUT_SECONDS must not exceed 3600")
        backups.chmod(0o700)
        timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        run_id = f"{timestamp}-{os.getpid()}"
        backup = backups / f"pre-upgrade-{old_version}-to-{new_version}-{run_id}.sql.gz"
        partial = Path(str(backup) + ".partial")
        require(not os.path.lexists(backup) and not os.path.lexists(partial),
                f"pre-upgrade backup destination already exists: {backup}")
        services = checked(old_compose, "previous Docker Compose configuration is invalid", "config", "--services", capture=True).splitlines()
        for service in ("postgres", "backend", "web", "db-init"):
            require(service in services, f"previous Docker Compose configuration is missing required service: {service}")
        writers = application_services(services)
        preflight()
        print("Quiescing the previous release before its rollback backup: " + " ".join(writers))
        stopped = True
        checked(old_compose, "could not stop every previous application service; the old release will be restarted", "stop", *writers)
        running = checked(old_compose, "could not verify that previous application services stopped", "ps", "--status", "running", "--services", capture=True).splitlines()
        for service in writers:
            require(service not in running, f"previous Compose service '{service}' is still running; backup was not started")
        require("postgres" in running, "previous PostgreSQL stopped while application services were quiesced")
        require_no_encrypted_collection(postgres, "the previous release will be restarted", "upgrade")
        print("Taking a consistent pre-upgrade SQL dump with application writers stopped.")
        command, environment = release_command(old, project, names)
        try:
            digest = rollback_dump([*command, "exec", "-T", "postgres", "/bin/bash", "-ceu", ROLLBACK_DUMP],
                                   partial, cwd=old, env=environment)
        except (OSError, ValueError):
            raise ValueError("pre-upgrade database dump failed; the previous release will be restarted") from None
        durable_replace(partial, backup)
        partial = None
        print(f"  verified pre-upgrade backup: {backup}")
        receipt_dir = state / "upgrade-receipts"
        require(not receipt_dir.is_symlink(), f"unsafe upgrade receipt directory: {receipt_dir}")
        receipt_dir.mkdir(mode=0o700, exist_ok=True)
        receipt_dir.chmod(0o700)
        receipt = receipt_dir / f"{run_id}-{old_version}-to-{new_version}.json"
        receipt_data = {"schema_version": 1, "timestamp_utc": timestamp, "compose_project": project,
                        "from": {"version": old_version, "source_revision": previous["source_revision"]},
                        "to": {"version": new_version, "source_revision": target["source_revision"]},
                        "pre_upgrade_backup": {"path": str(backup), "sha256": digest}}
        # A new release may redefine the project's networks (2026.10.5 pinned the default subnet).
        # Compose recreates a network only around services that still use it, so any previous
        # container left on it, such as monitoring, blocks the start.
        checked(old_compose, "could not stop the previous release; it will be restarted", "stop")
        print(f"Starting Chronicle {new_version} (bounded wait: {timeout}s).")
        result = new_compose("config", "--services", capture=True)
        if result.returncode:
            write_receipt("failed-service-discovery")
            raise ValueError(f"Upgrade could not resolve the new release service graph. The verified backup remains at:\n  {backup}")
        configured = result.stdout.splitlines()
        startup = [service for service in configured if service and service != "ca-export"]
        require(startup, "new release has no long-running services")
        write_json(lock / RECOVERY_FILE, {"owner": str(new), "phase": RECOVERY_PHASE,
                                           "backup": str(backup), "sha256": digest})
        started = True
        if new_compose("up", "-d", "--wait", "--wait-timeout", timeout, "--remove-orphans", "--force-recreate", *startup).returncode:
            write_receipt("failed")
            raise ValueError(f"\nUpgrade startup failed. The verified backup is unchanged at:\n  {backup}\n"
                             "Do not start the previous backend against a possibly migrated schema. Diagnose and\n"
                             "continue forward from this bundle, or follow docs/UPGRADE-ROLLBACK.md to restore the\n"
                             "pre-upgrade dump before starting the previous release.")
        if "ca-export" in configured and new_compose("run", "--rm", "--no-deps", "ca-export").returncode:
            write_receipt("failed-ca-export")
            raise ValueError(f"Upgrade services are healthy, but the local CA export failed. Continue forward from\n"
                             f"this bundle after correcting ca-export; the verified backup remains at {backup}.")
        if run(["./chronicle", "verify"]).returncode:
            write_receipt("failed-verification")
            raise ValueError(f"Upgrade containers started, but external verification failed. Continue forward from\n"
                             f"this bundle; the verified pre-upgrade dump remains at {backup}.")
        from .reconcile import install
        install(Path.cwd() / "chronicle", state, project)
        write_receipt("succeeded")
        os.environ["CHRONICLE_OPS_VERSION"] = new_version
        print(f"\nUpgrade complete: Chronicle {new_version} is healthy and verified.\nReceipt: {receipt}\n"
              f"Run future operator commands from: {new}")
        status = 0
        try:
            cleanup_releases(new.parent.parent, state, apply=True, rollback_target=old.parent)
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            warn(f"release image cleanup could not finish: {error}; retry ./chronicle cleanup")
    except Interrupted as error:
        status = error.status
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
    finally:
        if partial is not None:
            discard(partial)
        if status and stopped and not started:
            print("Upgrade stopped before the new release was started; restarting the previous release.", file=sys.stderr)
            try:
                old_compose("up", "-d", "--wait", "--wait-timeout", timeout, "--remove-orphans", "--force-recreate", check=True)
                print("Previous release is healthy again.", file=sys.stderr)
            except (OSError, subprocess.SubprocessError):
                print("WARNING: the previous release did not return healthy. Its database schema was not changed; diagnose the old stack before retrying.", file=sys.stderr)
        if status and started:
            # Also reached on a signal or tool error, where no failure message names the backup.
            print(f"Recovery: the verified pre-upgrade backup is {backup}. Continue forward from this bundle, or\n"
                  "follow docs/UPGRADE-ROLLBACK.md to restore it before starting the previous release.", file=sys.stderr)
        if status and generated and not started:
            discard(new / ".env")
        if held and not (status and started):
            try:
                discard(lock / RECOVERY_FILE)
                lock.rmdir()
            except OSError:
                pass
        if operation_ready:
            # Record through the release that owns the running stack. Compose loads the project from
            # the working directory, and a previous release's network definitions would make it
            # detach the new stack from a network it considers diverged.
            if started:
                os.environ["COMPOSE_FILE"] = ":".join(names)
            os.chdir(new if started else old)
            finish_operation("upgrade", status, "upgrade_failed", began)
            os.chdir(new)
        release_operation_lock(operation_lock)
    return status


def discard(path):
    """Best-effort removal during cleanup: a failure must not skip the restart, lock release or receipt."""
    try:
        path.unlink(missing_ok=True)
    except OSError as error:
        warn(f"could not remove {path}: {error}")
