"""Entry point for the installed selfhost package."""

import argparse
import os
import signal
import sys
import time

from .common import Interrupted, interrupted
from .dump import validate_dump
from .receipts import finish_operation, record_operation, write_operation_receipt, write_text
from .restore import Restore


def main(args=None):
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    restore = commands.add_parser("restore")
    restore.add_argument("--yes", action="store_true")
    restore.add_argument("--no-start", action="store_true")
    restore.add_argument("--trusted-sha256", default="")
    restore.add_argument("dump", nargs="?", default="")
    child = commands.add_parser("rollback")
    child.add_argument("--from", dest="source", required=True)
    child.add_argument("--trusted-sha256", required=True)
    child.add_argument("--yes", action="store_true")
    child.add_argument("dump")
    verify = commands.add_parser("verify")
    verify.add_argument("--dashboard-password", action="store_true")
    for command in ("upgrade", "adopt"):
        child = commands.add_parser(command)
        child.add_argument("--from", dest="source", required=True)
    for command in ("record-operation", "write-operation-receipt"):
        child = commands.add_parser(command)
        child.add_argument("operation")
        child.add_argument("outcome")
        child.add_argument("category", nargs="?", default="none")
        if command == "write-operation-receipt":
            child.add_argument("duration", nargs="?", default="0", type=int)
    child = commands.add_parser("validate-dump")
    child.add_argument("path")
    child = commands.add_parser("reconcile")
    child.add_argument("action", nargs="?", choices=("install", "uninstall", "stop", "resume", "preflight", "lock-path", "check", "check-start", "stopped"), default="install")
    commands.add_parser("owner-check")
    commands.add_parser("dashboard-login-migrate")
    child = commands.add_parser("cleanup")
    child.add_argument("--releases-dir", required=True)
    child.add_argument("--apply", action="store_true")
    child = commands.add_parser("storage-check")
    child = commands.add_parser("public-check")
    child = commands.add_parser("backup-storage")
    commands.add_parser("database-privileges")
    child = commands.add_parser("operation-lock")
    child.add_argument("--state")
    child.add_argument("--nonblocking", action="store_true")
    child.add_argument("args", nargs=argparse.REMAINDER)
    options = parser.parse_args(args)
    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupted)
    if options.command == "operation-lock":
        from .common import acquire_operation_lock, LOCK_FD_ENV
        from .release import read_env, value, require
        from pathlib import Path
        # Read only the state location to bootstrap locking; the child reloads settings under it.
        state = options.state
        if state is None:
            path = Path.cwd() / ".env"
            require(path.is_file() and not path.is_symlink(), ".env must be a regular file")
            require(path.stat().st_mode & 0o777 == 0o600, ".env must have mode 0600")
            state = value(read_env(path), "CHRONICLE_STATE_DIR", ".") or "."
        command = options.args[1:] if options.args[:1] == ["--"] else options.args
        require(command, "operation-lock requires a command")
        try:
            acquire_operation_lock(state, blocking=not options.nonblocking)
        except BlockingIOError:
            return 0
        os.environ["CHRONICLE_OPS_STATE"] = str(Path(state).resolve())
        os.set_inheritable(int(os.environ[LOCK_FD_ENV]), True)
        os.execvp(command[0], command)
    if options.command == "restore":
        return Restore(os.environ["CHRONICLE_OPS_STATE"], os.environ["CHRONICLE_OPS_BACKUPS"],
                       options.dump, options.trusted_sha256,
                       os.environ.get("RESTORE_START_WAIT_TIMEOUT_SECONDS", os.environ.get("START_WAIT_TIMEOUT_SECONDS", "3600")),
                       options.no_start, options.yes).execute()
    if options.command == "upgrade":
        from .upgrade import upgrade
        return upgrade(options.source)
    if options.command == "rollback":
        from .restore import rollback
        return rollback(options.source, options.dump, options.trusted_sha256, options.yes)
    if options.command == "adopt":
        from .adopt import adopt
        return adopt(options.source)
    if options.command == "verify":
        from .verify import verify
        from .common import acquire_operation_lock, release_operation_lock
        status = 1
        started = time.monotonic()
        descriptor = None
        try:
            descriptor = acquire_operation_lock(os.environ["CHRONICLE_OPS_STATE"])
            status = verify(["--dashboard-password"] if options.dashboard_password else [])
            if status == 0 and descriptor is not None:
                from .reconcile import complete_recovery
                complete_recovery()
        except Interrupted as error:
            status = error.status
        finally:
            release_operation_lock(descriptor)
            finish_operation("verify", status, "verification_failed", started)
        return status
    if options.command == "owner-check":
        from .release import require_current_owner
        from pathlib import Path
        require_current_owner(Path.cwd(), os.environ["CHRONICLE_OPS_STATE"], os.environ["CHRONICLE_OPS_PROJECT"])
    elif options.command == "dashboard-login-migrate":
        from .release import migrate_dashboard_login
        from pathlib import Path
        print("changed" if migrate_dashboard_login(Path.cwd()) else "unchanged")
    elif options.command == "validate-dump":
        validate_dump(options.path)
    elif options.command == "reconcile":
        from .reconcile import install, preflight, check_mutations, STOP_MARKER
        from .common import OPERATION_LOCK
        from pathlib import Path
        state = Path(os.environ["CHRONICLE_OPS_STATE"])
        if options.action == "stopped":
            return 0 if (state / STOP_MARKER).exists() else 1
        if options.action == "lock-path":
            print(state / OPERATION_LOCK)
        elif options.action in ("check", "check-start"):
            check_mutations(state, Path.cwd(), allow_forward=options.action == "check-start")
        elif options.action == "preflight":
            preflight()
        elif options.action == "install":
            install(Path.cwd() / "chronicle", state, os.environ["CHRONICLE_OPS_PROJECT"])
        elif options.action == "uninstall":
            from .reconcile import uninstall
            uninstall(state, os.environ["CHRONICLE_OPS_PROJECT"])
        elif options.action == "stop":
            write_text(state / STOP_MARKER, "")
        else:
            (state / STOP_MARKER).unlink(missing_ok=True)
    elif options.command == "cleanup":
        from .release import cleanup_releases
        from .common import acquire_operation_lock, release_operation_lock
        descriptor = acquire_operation_lock(os.environ["CHRONICLE_OPS_STATE"])
        try:
            cleanup_releases(options.releases_dir, os.environ["CHRONICLE_OPS_STATE"], options.apply)
        finally:
            release_operation_lock(descriptor)
    elif options.command == "storage-check":
        from .common import require_storage
        require_storage(os.environ["CHRONICLE_OPS_STATE"], os.environ["CHRONICLE_OPS_PROJECT"],
                        os.environ.get("MIN_FREE_DISK_GIB", "5"))
    elif options.command == "public-check":
        from .verify import verify_public_origin
        from .release import read_env, value
        from pathlib import Path
        settings = read_env(Path.cwd() / ".env")
        return verify_public_origin(value(settings, "CHRONICLE_PUBLIC_BASE_URL") or "https://" + value(settings, "DOMAIN"))
    elif options.command == "backup-storage":
        from .verify import verify_backup_storage
        from .release import read_env, value
        from pathlib import Path
        return verify_backup_storage(os.environ["CHRONICLE_OPS_BACKUPS"],
                                     value(read_env(Path.cwd() / ".env"), "BACKUP_STORAGE_ENCRYPTION_WAIVER"))
    elif options.command == "database-privileges":
        from .verify import verify_database_privileges
        verify_database_privileges()
    elif options.command == "record-operation":
        record_operation(options.operation, options.outcome, options.category)
    else:
        write_operation_receipt(options.operation, options.outcome, options.category, options.duration)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print("error: " + str(error), file=sys.stderr)
        sys.exit(1)
    except Interrupted as error:
        sys.exit(error.status)
