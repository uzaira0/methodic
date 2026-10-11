"""Adopt a source checkout into a release bundle."""

from pathlib import Path
import datetime
import os
import re
import shutil
import stat
import subprocess
import sys

from .reconcile import ENABLED_ENV, RECOVERY_PHASE, RECOVERY_FILE, preflight

from .common import Interrupted, acquire_operation_lock, release_operation_lock, application_services, run
from .receipts import write_json
from .release import (ROLLBACK_DUMP, compose_names, compose_release, merge_env, postgres_major, postgres_sql,
                      read_env, read_manifest, require, require_no_encrypted_collection, rollback_dump, release_command, value,
                      require_current_owner)


def checked_run(args, **kwargs):
    return run(args, check=True, **kwargs)


def adopt(source_dir):
    new = Path.cwd().resolve()
    source = Path(source_dir).resolve()
    copied = []
    stopped = started = lock_held = False
    receipt = None
    operation_lock = None
    # The lock upgrade/restore/rotate-secret/up already honor in the source state directory.
    lock = source / ".chronicle-upgrade.lock"

    def compose(*args, capture=False):
        return compose_release(source, project, names, *args, capture=capture, check=True)

    def write_receipt(status):
        receipt_data["status"] = status
        write_json(receipt, receipt_data)

    try:
        require(source.is_dir(), f"source selfhost directory does not exist: {source}")
        require(source != new and source not in new.parents and new not in source.parents,
                "--from must name a separate source checkout, outside the new bundle")
        require(not os.path.lexists(source.parent / "release-manifest.json"),
                f"source has a release manifest; use ./chronicle upgrade --from '{source}' instead")
        require(not os.path.lexists(new / ".env"),
                "new release already has .env; extract a clean bundle")
        operation_lock = acquire_operation_lock(source)
        # Same fail-closed interlocks as up/upgrade/rotate-secret: adopting a source checkout
        # must not launder a preserved lock by leaving it behind in the old directory.
        for preserved in (".chronicle-restore.lock", ".chronicle-upgrade.lock", ".chronicle-secret-rotation"):
            require(not os.path.lexists(source / preserved),
                    f"source has an incomplete operation preserved at {source / preserved}; "
                    "follow its recovery runbook before adopting")
        # Hold upgrade's lock for the whole handoff so no rotation, restore, upgrade or setup can
        # change the source settings this command caches below. Same stale-lock rule as upgrade.
        try:
            os.mkdir(lock, 0o700)
        except FileExistsError:
            raise ValueError(f"another upgrade or adopt may be active (lock exists: {lock}). If none is "
                             "running, remove only that empty directory and retry.") from None
        lock_held = True
        for other in (".chronicle-restore.lock", ".chronicle-secret-rotation"):
            require(not os.path.lexists(source / other),
                    f"an operation started while the adopt lock was being acquired ({source / other}); "
                    "adopt did not start")
        old_env = source / ".env"
        require(old_env.is_file() and not old_env.is_symlink(),
                "source .env must be a regular file")
        require(stat.S_IMODE(old_env.stat().st_mode) == 0o600, "source .env must have mode 0600")
        for name in ("backups", "tls"):
            require((source / name).is_dir() and not (source / name).is_symlink(),
                    f"source {name}/ must be a directory, not a symlink")
            target = new / name
            require(not os.path.lexists(target) or
                    (target.is_dir() and not target.is_symlink() and not any(target.iterdir())),
                    f"new {name}/ must be absent or empty; extract a clean bundle")
        require((new.parent / "release-manifest.json").is_file(), "new release manifest is missing")
        manifest, _ = read_manifest(new.parent / "release-manifest.json", True)
        old = read_env(old_env)
        os.environ.setdefault(ENABLED_ENV, value(old, ENABLED_ENV, "true"))
        template = (new / ".env.example").read_text()
        defaults = read_env(new / ".env.example")
        for key in ("BACKEND_IMAGE", "SELFHOST_FRONTEND_IMAGE", "CADDY_IMAGE"):
            require(re.fullmatch(r"[^\s@]+@sha256:[0-9a-f]{64}", value(defaults, key)),
                    f"new .env.example must contain a digest-pinned {key}")
        project = value(old, "COMPOSE_PROJECT_NAME", "chronicle-selfhost")
        require(re.fullmatch(r"[a-z0-9][a-z0-9_-]*", project), "invalid source COMPOSE_PROJECT_NAME")
        require((source / value(old, "CHRONICLE_STATE_DIR", ".")).resolve() == source,
                "source CHRONICLE_STATE_DIR must resolve to the source selfhost directory")
        require_current_owner(source, source, project)
        require(not any(key.startswith("COMPOSE_") and key not in
                        {"COMPOSE_FILE", "COMPOSE_PROJECT_NAME"} for key in old),
                "unsupported source Compose control setting")
        names = compose_names(old, source)
        for name in names:
            require((source / name).is_file() and (new / name).is_file(),
                    f"Compose file missing in source or new release: {name}")
        child_env = {key: val for key, val in os.environ.items()
                     if key not in old and key not in defaults and not key.startswith("COMPOSE_")}
        child_env[ENABLED_ENV] = os.environ[ENABLED_ENV]
        for tool in ("docker", "cp"):
            require(shutil.which(tool), f"required command is unavailable: {tool}")
        postgres = compose("ps", "-q", "postgres", capture=True).stdout.strip()
        require(postgres and len(postgres.splitlines()) == 1, "source PostgreSQL container is not running")
        health = checked_run(["docker", "inspect", "--format",
                      '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{end}}', postgres],
                     capture=True).stdout.strip()
        require(health == "true healthy", "source PostgreSQL container must be running and healthy")
        services = compose("config", "--services", capture=True).stdout.splitlines()
        require(all(name in services for name in ("postgres", "backend", "web", "db-init")),
                "source Compose configuration is missing required services")

        # upgrade.sh's database preconditions, checked while the source is still fully running.
        # A failed query is indeterminate and refuses adoption rather than reading as "clear".
        version_num = postgres_sql(postgres, "SHOW server_version_num")
        require(version_num.isdigit(), "running PostgreSQL returned an invalid server_version_num")
        new_postgres_image = value(defaults, "POSTGRES_IMAGE")
        require(new_postgres_image, "new .env.example has no POSTGRES_IMAGE")
        new_postgres_version = checked_run(["docker", "run", "--rm", "--network", "none", "--read-only",
                                    "--cap-drop", "ALL", "--entrypoint", "postgres", new_postgres_image,
                                    "--version"], capture=True).stdout
        new_major = postgres_major(new_postgres_version, new_postgres_image)
        old_major = int(version_num) // 10000
        require(new_major == old_major,
                f"adopt refuses PostgreSQL major {old_major} -> {new_major} against the same data volume. "
                "Follow docs/POSTGRES-18-UPGRADE.md for a dump/restore major upgrade.")
        def encryption_precheck():
            require_no_encrypted_collection(postgres, "the source checkout was not changed", "adoption")

        encryption_precheck()
        writers = application_services(services)
        preflight()
        stopped = True
        compose("stop", *writers)
        running = compose("ps", "--status", "running", "--services", capture=True).stdout.splitlines()
        require("postgres" in running and not set(writers).intersection(running),
                "source writers did not stop or PostgreSQL stopped; backup was not started")
        # Again with writers stopped: a study enabled, or ciphertext stored, after the first check.
        encryption_precheck()
        timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        run_id = f"{timestamp}-{os.getpid()}"
        backup = source / "backups" / f"pre-adopt-{run_id}.sql.gz"
        command, environment = release_command(source, project, names)
        digest = rollback_dump([*command, "exec", "-T", "postgres", "/bin/bash", "-ceu", ROLLBACK_DUMP],
                               backup, cwd=source, env=environment)
        copied.append(".env")
        checked_run(["cp", "-a", str(old_env), str(new / ".env")])
        os.chmod(new / ".env", 0o600)
        old["COMPOSE_PROJECT_NAME"] = project
        merge_env(old, template, new / ".env", str(source), names)
        # Guard and pull the new release while the source stack can still restart: a setting the
        # new guard rejects, or an unreachable registry, must not leave neither stack running.
        # A separate project name keeps this one-shot container out of the source project. It is
        # unique to this run and must be unused, because the cleanup below runs `down` on it.
        check_project = f"{project}-adopt-check-{os.getpid()}"
        require(not checked_run(["docker", "ps", "-aq", "--filter", f"label=com.docker.compose.project={check_project}"],
                        capture=True).stdout.strip(),
                f"compose project {check_project} already has containers; adopt did not start")
        check = ["docker", "compose", "--project-name", check_project]
        try:
            checked_run([*check, "run", "--rm", "--no-deps", "config-guard"], cwd=new, env=child_env)
            checked_run([*check, "pull", "--quiet"], cwd=new, env=child_env)
        finally:
            run([*check, "down"], cwd=new, env=child_env, quiet=True)
        # Host checks too (disk floor, ports, bind addresses): `up` ran them only after the
        # source was torn down, so a failure there left neither stack running.
        checked_run(["./chronicle", "adopt-precheck", str(source)], env=child_env)
        receipt_dir = new / "upgrade-receipts"
        require(not os.path.lexists(receipt_dir), "new upgrade-receipts/ already exists; extract a clean bundle")
        copied.append("upgrade-receipts")
        receipt_dir.mkdir(mode=0o700)
        receipt = receipt_dir / f"{run_id}-adopt.json"
        receipt_data = {"schema_version": 1, "operation": "adopt", "timestamp_utc": timestamp,
                   "compose_project": project, "from": {"directory": str(source), "kind": "source-checkout"},
                   "to": {"directory": str(new), "version": manifest["release_version"]},
                   "pre_adopt_backup": {"path": str(backup), "sha256": digest}}
        write_receipt("starting")
        # up's project-collision guard rejects containers labelled with the source directory.
        # Remove the stopped source containers/network while preserving every named volume.
        compose("down", "--remove-orphans")
        recovery = {"owner": str(new), "phase": RECOVERY_PHASE, "backup": str(backup), "sha256": digest}
        write_json(lock / RECOVERY_FILE, recovery)
        started = True
        checked_run(["./chronicle", "up"], env=child_env)
        write_receipt("verifying")
        checked_run(["./chronicle", "verify"], env=child_env)
        from .reconcile import install
        install(new / "chronicle", source, project)
        write_receipt("succeeded")
        print(f"Adoption complete. Receipt: {receipt}\nRun future operator commands from: {new}")
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, Interrupted) as error:
        print(f"error: adopt failed: {error}", file=sys.stderr)
        if started:
            try:
                write_receipt("failed")
            except OSError:
                print("Could not update the adoption receipt.", file=sys.stderr)
            import shlex
            print("The new release may have migrated the database. After independently reviewing the dump, "
                  "recover from this bundle with:\n"
                  f"  ./chronicle rollback --from {shlex.quote(str(source))} --trusted-sha256={digest} "
                  f"/backups/{backup.name}\nSee docs/UPGRADE-ROLLBACK.md.", file=sys.stderr)
        else:
            if stopped:
                try:
                    compose("up", "-d", "--wait", "--wait-timeout", value(old, "START_WAIT_TIMEOUT_SECONDS", "3600"), "--remove-orphans", "--force-recreate")
                    print("Source stack restarted.", file=sys.stderr)
                except (OSError, subprocess.SubprocessError):
                    print("Source restart failed; diagnose the source stack before retrying.", file=sys.stderr)
            for name in reversed(copied):
                target = new / name
                try:
                    if target.is_dir() and not target.is_symlink():
                        shutil.rmtree(target)
                    else:
                        target.unlink(missing_ok=True)
                except (OSError, subprocess.SubprocessError) as cleanup_error:
                    print(f"Could not remove copied {target} ({cleanup_error}); delete it as root, "
                          "or extract a clean bundle, before retrying.", file=sys.stderr)
        return error.status if isinstance(error, Interrupted) else 1
    finally:
        if lock_held and not (started and receipt_data.get("status") != "succeeded"):
            try:
                (lock / RECOVERY_FILE).unlink(missing_ok=True)
                os.rmdir(lock)
            except OSError as error:
                print(f"Could not release adopt lock {lock} ({error}); remove only that empty "
                      "directory once no adopt is running.", file=sys.stderr)
        release_operation_lock(operation_lock)
    return 0
