"""Guarded restore orchestration and recovery."""

import os
import json
from pathlib import Path, PurePosixPath
import re
import sys
import time

from .reconcile import RECOVERY_PHASE, RECOVERY_FILE

from .dump import DumpError, EXIT_REJECTED_BEFORE_MUTATION, EXIT_RESTORE_TRANSACTION_ROLLED_BACK, validate_dump
from .common import BLD, GRN, RED, RST, Interrupted, acquire_operation_lock, release_operation_lock, application_services, compose, warn
from .receipts import OPERATOR_RECEIPTS_DIR, durable_replace, finish_operation, write_text
from .release import read_env, value
from .reconcile import STOP_MARKER

class RestoreError(Exception):
    pass


def resolve_host_path(root_text, container_text):
    parts = PurePosixPath(container_text).parts
    if len(parts) < 3 or parts[:2] != ("/", "backups"):
        raise RestoreError("restore path must be below /backups")
    relative = parts[2:]
    if any(part in {"", ".", ".."} for part in relative):
        raise RestoreError("restore path contains an unsafe component")
    if not relative[-1].endswith(".sql.gz"):
        raise RestoreError("restore path must end in .sql.gz")
    try:
        root = Path(root_text).resolve(strict=True)
        target = root.joinpath(*relative).resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise RestoreError("cannot resolve restore path: {}".format(error)) from None
    if any(character in str(target) for character in ("\n", "\r", "\x00")):
        raise RestoreError("restore path resolves to a name containing a control character")
    if os.path.commonpath((str(root), str(target))) != str(root):
        raise RestoreError("restore path resolves outside the backups directory")
    if not target.is_file():
        raise RestoreError("restore path is not a regular file")
    return target


class Restore:
    def __init__(self, root, backups, container_path, digest, timeout, no_start,
                 assume_yes, terminal=None, owner_pid=None, recovery_owner=None):
        self.root = Path(root)
        self.backups = backups
        database = os.environ.get("POSTGRES_DB", "chronicle")
        self.container_path = container_path or f"/backups/last/{database}-latest.sql.gz"
        self.digest, self.timeout = digest, timeout
        self.no_start, self.assume_yes, self.terminal = no_start, assume_yes, terminal
        self.owner_pid = str(owner_pid or os.getpid())
        self.recovery_owner = recovery_owner
        self.started = time.monotonic()
        self.lock = self.root / ".chronicle-restore.lock"
        self.held = self.preserve = self.restart = False
        self.previous = []
        self.stopped = application_services([])

    def dc(self, *args, **kwargs):
        result = compose(*args, **kwargs)
        return result.returncode, (result.stdout or "").rstrip("\n")

    def require_dc(self, message, *args, **kwargs):
        status, output = self.dc(*args, **kwargs)
        if status:
            raise RestoreError(message)
        return output

    def write_lock(self, name, value):
        if not re.fullmatch("[a-z-]+", name):
            raise RestoreError("internal error: invalid restore lock field")
        temporary = self.lock / ".{}.{}".format(name, self.owner_pid)
        try:
            temporary.write_text(str(value) + "\n", encoding="utf-8", errors="surrogateescape")
        except OSError:
            raise RestoreError("could not write restore operation metadata") from None
        try:
            temporary.chmod(0o600)
        except OSError:
            raise RestoreError("could not protect restore operation metadata") from None
        try:
            os.replace(temporary, self.lock / name)
        except OSError:
            raise RestoreError("could not publish restore operation metadata") from None

    def release(self):
        if not self.held:
            return True
        if not self.lock.is_dir() or self.lock.is_symlink():
            return False
        for name in ("owner-pid", "phase", "restore-file"):
            for path in (self.lock / name, self.lock / ".{}.{}".format(name, self.owner_pid)):
                try:
                    path.unlink(missing_ok=True)
                except OSError:
                    pass
        try:
            self.lock.rmdir()
        except OSError:
            return False
        self.held = False
        return True

    def cleanup(self):

        if self.restart:
            if self.previous:
                warn("the live database was not replaced; restarting the services that were running before the stop attempt: " + " ".join(self.previous))
                status, _ = self.dc("up", "-d", "--wait", "--wait-timeout", self.timeout,
                                    "--no-deps", *self.previous)
                if not status:
                    print("         The pre-restore service state was restored.", file=sys.stderr)
                else:
                    warn("the database was not changed, but the previous application services could not all be restarted.")
                    print("         Diagnose Docker Compose, then run ./chronicle up.", file=sys.stderr)
            self.restart = False
            # Rejected input and rolled-back transactions preserve the original public data.
            self.preserve = False
        if self.held:
            if self.preserve:
                warn("do not start Chronicle application services against this database.")
                print("         Restore state is preserved at {}.".format(self.lock), file=sys.stderr)
                print("         Confirm no restore process or restore container is running, diagnose the", file=sys.stderr)
                print("         failure, then follow docs/BACKUP-RESTORE.md to release only that lock.", file=sys.stderr)
            elif not self.release():
                warn("could not release restore lock {}".format(self.lock))

    def trust_dump(self, path):
        try:
            validate_dump(path, self.digest)
        except DumpError as error:
            self.reject_dump(str(error))

    def reject_dump(self, message):
        print("FAIL restore " + message, file=sys.stderr)
        raise RestoreError("restore dump trust verification failed")

    def interlocks(self, acquired=False):
        for name, operation in ((".chronicle-upgrade.lock", "upgrade"),
                                (".chronicle-secret-rotation", "secret rotation")):
            lock = self.root / name
            if os.path.lexists(lock):
                if operation == "upgrade" and self.recovery_owner:
                    recovery = json.loads((lock / RECOVERY_FILE).read_text())
                    if recovery["owner"] == self.recovery_owner:
                        continue
                article = "an" if operation == "upgrade" else "a"
                detail = ("started while the restore lock was being acquired; restore did not start"
                          if acquired else "is active or incomplete ({}); do not restore concurrently".format(lock))
                raise RestoreError("{} {} {}".format(article, operation, detail))

    def perform(self):
        if not re.fullmatch("[1-9][0-9]*", self.timeout):
            raise RestoreError("RESTORE_START_WAIT_TIMEOUT_SECONDS must be a positive integer")
        if int(self.timeout) > 3600:
            raise RestoreError("RESTORE_START_WAIT_TIMEOUT_SECONDS must not exceed 3600")
        if not self.root.is_dir():
            raise RestoreError("CHRONICLE_STATE_DIR does not exist: {}".format(self.root))
        if "\n" in self.container_path or "\r" in self.container_path:
            raise RestoreError("restore path must not contain control characters")
        try:
            host_path = resolve_host_path(self.backups, self.container_path)
        except RestoreError as error:
            print(str(error), file=sys.stderr)
            raise RestoreError("restore dump is unavailable or unsafe: " + self.container_path) from None
        if not host_path.stat().st_size:
            raise RestoreError("restore dump is empty: " + self.container_path)
        print("{}Restoring Chronicle from{} {}".format(BLD, RST, self.container_path))
        print("  Checking gzip integrity before stopping application services.")
        self.trust_dump(host_path)
        services = self.require_dc("Docker Compose configuration is invalid", "--profile", "restore",
                                   "config", "--services", capture=True).split("\n")
        for name in ("postgres", "backend", "web", "restore"):
            if name not in services:
                raise RestoreError("Docker Compose configuration is missing required service: " + name)
        self.stopped = application_services(services)
        running = self.require_dc("could not inspect running Compose services", "--profile", "restore",
                                  "ps", "--status", "running", "--services", capture=True).split("\n")
        if "restore" in running:
            raise RestoreError("a one-shot restore container is already running; do not start another restore")
        self.previous = [name for name in self.stopped if name in running]
        if not self.assume_yes:
            if not (sys.stdin.isatty() if self.terminal is None else self.terminal):
                raise RestoreError("confirmation requires a terminal; review the restore runbook, then repeat with --yes")
            if input("Stop Chronicle and replace its database with this dump? [y/N] ") not in ("y", "Y"):
                raise RestoreError("restore cancelled")
        self.interlocks()
        try:
            self.lock.mkdir(mode=0o700)
        except OSError:
            raise RestoreError("another restore is active or incomplete ({}). Follow docs/BACKUP-RESTORE.md before removing the lock.".format(self.lock)) from None
        self.held = True
        try:
            self.lock.chmod(0o700)
        except OSError:
            raise RestoreError("could not protect restore lock") from None
        self.interlocks(acquired=True)
        self.write_lock("owner-pid", self.owner_pid)
        self.write_lock("restore-file", self.container_path)
        self.write_lock("phase", "prepared")
        print("  Stopping application access and backup activity: " + " ".join(self.stopped))
        self.write_lock("phase", "stopping-services")
        self.restart = True
        self.require_dc("could not stop every application service; restore was not started", "stop", *self.stopped)
        running = self.require_dc("could not verify that application services stopped", "--profile", "restore",
                                  "ps", "--status", "running", "--services", capture=True).split("\n")
        for name in self.stopped:
            if name in running:
                raise RestoreError("Compose service '{}' is still running; restore was not started".format(name))
        if "restore" in running:
            raise RestoreError("a different one-shot restore container is running; restore was not started")
        self.preserve, self.restart = True, False
        self.write_lock("phase", "restoring")
        args = ["run", "--rm", "-e", "CHRONICLE_RESTORE_ORCHESTRATED=true"]
        if self.no_start:
            args += ["-e", "CHRONICLE_RESTORE_LEAVE_STOPPED=true"]
        args += ["-e", "CHRONICLE_RESTORE_TRUSTED_SHA256=" + self.digest,
                 "-e", "RESTORE_FILE=" + self.container_path, "restore"]
        status, _ = self.dc("--profile", "restore", *args)
        if status:
            if status == EXIT_RESTORE_TRANSACTION_ROLLED_BACK:
                self.restart, self.preserve = True, False
                raise RestoreError("restore transaction was rolled back; the live database was preserved. Choose a newer backup or continue from the current release")
            if status == EXIT_REJECTED_BEFORE_MUTATION:
                self.restart, self.preserve = True, False
                raise RestoreError("restore backup changed before database mutation; rerun ./chronicle restore with the reviewed backup digest")
            raise RestoreError("database restore failed; Chronicle was deliberately left stopped")
        self.write_lock("phase", "database-restored")
        if self.no_start:
            write_text(self.root / STOP_MARKER, "restored; explicit up required\n")
            print("  Database restored; application services remain stopped because --no-start was used.")
        else:
            self.start()
        self.preserve = False
        if not self.release():
            self.preserve = True
            raise RestoreError("restore completed, but its operation lock could not be released")

    def start(self):
        print("  Starting Chronicle (bounded health wait: {}s).".format(self.timeout))
        self.write_lock("phase", "starting-services")
        configured = self.require_dc("could not resolve the post-restore Compose services", "config",
                                     "--services", capture=True).split("\n")
        startup = [service for service in configured if service and service != "ca-export"]
        if not startup:
            raise RestoreError("restore found no long-running services to start")
        status, _ = self.dc("up", "-d", "--wait", "--wait-timeout", self.timeout,
                            "--remove-orphans", "--force-recreate", *startup)
        if status:
            self.stop_failed_start("post-restore startup failed", "startup failure",
                                   "database restored, but Chronicle did not return healthy")
        if "ca-export" in configured:
            status, _ = self.dc("run", "--rm", "--no-deps", "ca-export")
            if status:
                self.stop_failed_start("local CA export failed after restore", "CA export failure",
                                       "database restored, but Chronicle could not publish its local CA")
        self.write_lock("phase", "verified")

    def stop_failed_start(self, warning, reason, error):
        warn(warning + "; stopping application services again")
        status, _ = self.dc("stop", *self.stopped, quiet=True)
        if status:
            warn("could not confirm every application service stopped after " + reason)
        raise RestoreError(error)

    def execute(self):
        status = 1
        operation_lock = None
        try:
            operation_lock = acquire_operation_lock(self.root)
            self.perform()
            status = 0
        except (RestoreError, OSError, EOFError, ValueError, KeyError) as error:
            print("{}error:{} {}".format(RED, RST, error), file=sys.stderr)
        except Interrupted as error:
            status = error.status
        finally:
            finish_operation("restore", status, "restore_failed", self.started)
            if status and self.held:
                self.cleanup()
            release_operation_lock(operation_lock)
        if status == 0:
            print("Restore took {} seconds.".format(int(time.monotonic() - self.started)))
            detail = ("The Chronicle application remains stopped." if self.no_start else
                      "Chronicle is healthy; run ./chronicle verify next.")
            print("{}Restore complete.{} {}".format(GRN, RST, detail))
        return status


def return_monitoring_volumes(project):
    # Since 2026.10.9 monitoring-config re-owns its writable volumes for non-root services.
    # Earlier releases run those services as root with every capability dropped, so they need
    # root ownership back; later releases re-own the volumes when monitoring-config starts.
    from .common import run
    config = json.loads(compose("config", "--format", "json", capture=True, check=True).stdout)
    init = config["services"].get("monitoring-config")
    if not init:
        return
    wanted = {config["volumes"][mount["source"]]["name"] for mount in init.get("volumes", [])
              if mount.get("type") == "volume" and not mount.get("read_only")}
    present = run(["docker", "volume", "ls", "-q", "--filter", f"label=com.docker.compose.project={project}"],
                  capture=True, check=True, timeout=60).stdout.split()
    volumes = sorted(wanted.intersection(present))
    if not volumes:
        return
    mounts = [arg for index, name in enumerate(volumes) for arg in ("--mount", f"type=volume,src={name},dst=/volume/{index}")]
    run(["docker", "run", "--rm", "--pull", "never", "--network", "none", "--user", "0", "--cap-drop", "ALL",
         "--cap-add", "CHOWN", "--cap-add", "DAC_OVERRIDE", "--cap-add", "FOWNER", *mounts, "--entrypoint", "chown",
         config["services"]["postgres"]["image"], "-R", "0:0", *(f"/volume/{index}" for index in range(len(volumes)))],
        check=True, timeout=300)


def rollback(source, dump, digest, assume_yes=False):
    from .common import run
    from .release import compose_names, merge_env, require, require_current_owner
    from .reconcile import ENABLED_ENV, install, uninstall
    old, current = Path(source).resolve(), Path.cwd().resolve()
    require(old != current, "rollback --from must name the previous release")
    settings, current_settings = read_env(old / ".env"), read_env(current / ".env")
    project = value(settings, "COMPOSE_PROJECT_NAME", "chronicle-selfhost")
    require(project == value(current_settings, "COMPOSE_PROJECT_NAME", "chronicle-selfhost"), "rollback projects differ")
    state = (current / value(current_settings, "CHRONICLE_STATE_DIR", ".")).resolve()
    legacy = not (old / "chronicle_ops" / "__main__.py").is_file()
    descriptor = acquire_operation_lock(state)
    succeeded = False
    stopped = False
    try:
        settings, current_settings = read_env(old / ".env"), read_env(current / ".env")
        require(project == value(current_settings, "COMPOSE_PROJECT_NAME", "chronicle-selfhost"), "rollback projects changed; retry")
        require((current / value(current_settings, "CHRONICLE_STATE_DIR", ".")).resolve() == state,
                "rollback state location changed; retry")
        require_current_owner(current, state, project)
        require((current / ".env").stat().st_mode & 0o777 == 0o600,
                "candidate .env must have mode 0600 before rollback")
        os.environ.setdefault(ENABLED_ENV, value(current_settings, ENABLED_ENV, "true"))
        settings.update({key: raw for key, raw in current_settings.items()
                         if key.endswith(("_PASSWORD", "_SECRET", "_SECRET_PREVIOUS"))
                         or key == "DASHBOARD_PASSWORD_HASH"
                         or key.startswith(("MOBILE_SIGNING_", "CHRONICLE_REVIEWER_"))})
        previously_stopped = (state / STOP_MARKER).exists()
        write_text(state / STOP_MARKER, "rollback in progress\n")
        stopped = True
        os.environ.update(CHRONICLE_OPS_STATE=str(state), CHRONICLE_OPS_PROJECT=project,
                          CHRONICLE_OPS_BACKUPS=str(state / "backups"),
                          COMPOSE_FILE=value(current_settings, "COMPOSE_FILE"))
        operation = Restore(state, str(state / "backups"), dump, digest,
                            os.environ.get("RESTORE_START_WAIT_TIMEOUT_SECONDS", "3600"),
                            True, assume_yes, recovery_owner=str(current))
        if operation.execute():
            if not operation.preserve and not operation.held:
                if not previously_stopped:
                    (state / STOP_MARKER).unlink(missing_ok=True)
                stopped = False
            return 1
        marker = state / ".chronicle-upgrade.lock"
        if marker.exists():
            (marker / RECOVERY_FILE).unlink()
            marker.rmdir()
        merge_env(settings, (old / ".env.example").read_text(), old / ".env", state,
                  compose_names(settings, old), preserve_images=True)
        compose("down", "--remove-orphans", check=True)
        return_monitoring_volumes(project)
        private = state / OPERATOR_RECEIPTS_DIR
        require(not private.is_symlink(), "unsafe operator receipt directory")
        private.mkdir(mode=0o700, exist_ok=True)
        private.chmod(0o700)
        if legacy:
            from .release import set_current_owner
            set_current_owner(old, state)
            uninstall(state, project)
            for log in state.glob("reconcile.*"):
                require(log.is_file() and not log.is_symlink(), "unsafe reconciliation log")
                durable_replace(log, private / log.name)
            (state / STOP_MARKER).chmod(0o644)
            print("Previous release has no reconciliation support; its automatic schedule was removed.")
        else:
            install(old / "chronicle", state, project, update_only=True)
        require(run([str(old / "chronicle"), "up"], check=True).returncode == 0, "rollback startup failed")
        require(run([str(old / "chronicle"), "verify"], check=True).returncode == 0, "rollback acceptance failed")
        (state / STOP_MARKER).unlink(missing_ok=True)
        archived_env = private / f".env.rollback-{time.time_ns()}"
        require(not os.path.lexists(archived_env),
                "candidate .env.rollback already exists; archive it privately before retrying rollback")
        durable_replace(current / ".env", archived_env)
        succeeded = True
        return 0
    finally:
        try:
            if stopped and not succeeded:
                write_text(state / STOP_MARKER, "rollback incomplete\n")
                if legacy:
                    (state / STOP_MARKER).chmod(0o644)
        finally:
            release_operation_lock(descriptor)
