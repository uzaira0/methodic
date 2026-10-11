from contextlib import ExitStack
import io
import os
from pathlib import Path
import stat
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "selfhost"))
from chronicle_ops.common import Interrupted
from chronicle_ops.upgrade import upgrade
from chronicle_ops.reconcile import ENABLED_ENV


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        if hasattr(self, "stack"):
            self.stack.close()
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.events = []
        self.recorded = []
        self.cwd = None
        self.failure = ""
        self.race = None
        self.locked = False
        def lexists(path):
            return self.locked and str(path).endswith(self.race or "/never")
        def mkdir(path, **kwargs):
            if str(path).endswith(".chronicle-upgrade.lock"):
                self.locked = True
        def compose(directory, project, names, *args, **kwargs):
            release = "old" if str(directory).startswith("/old") else "new"
            self.events.append((release, *args))
            code = 0
            output = ""
            if args == ("ps", "-q", "postgres"):
                output = "old-postgres\n"
            elif args == ("config", "--format", "json"):
                output = '{"services":{"postgres":{"image":"percona"}}}'
            elif args == ("config", "--services"):
                output = "postgres\nbackend\nweb\ndb-init\ndb-backup\nca-export\n"
                if release == "new" and self.failure == "discovery":
                    code = 1
            elif args[:1] == ("ps",):
                output = "postgres\n"
            elif args[:1] == ("stop",) and self.failure == "stop":
                code = 42
            elif release == "new" and args[:1] == ("up",) and self.failure == "startup":
                code = 42
            elif release == "new" and args[:1] == ("up",) and self.failure == "interrupt":
                raise Interrupted(15)
            return subprocess.CompletedProcess(args, code, output)
        def run(args, **kwargs):
            self.events.append(tuple(args))
            output = "healthy\n" if "inspect" in args else "postgres (PostgreSQL) 18.6\n"
            code = 1 if args == ["./chronicle", "verify"] and self.failure == "verify" else 0
            return subprocess.CompletedProcess(args, code, output)
        def dump(*args, **kwargs):
            self.events.append(("dump",))
            if self.failure == "dump":
                raise ValueError("dump failed")
            return "a" * 64
        previous = {"release_version": "1.0.0", "source_revision": "1" * 40}
        target = {"release_version": "1.0.1", "source_revision": "2" * 40}
        patches = {
            "chronicle_ops.upgrade.acquire_operation_lock": {"return_value": None},
            "chronicle_ops.upgrade.release_operation_lock": {},
            "chronicle_ops.upgrade.require_storage": {},
            "chronicle_ops.upgrade.require_current_owner": {},
            "chronicle_ops.upgrade.read_env": {"return_value": {"COMPOSE_PROJECT_NAME": "pilot", "CHRONICLE_STATE_DIR": "/state", "COMPOSE_FILE": "overlays/monitoring.yml"}},
            "chronicle_ops.upgrade.read_manifest": {"side_effect": [(previous, (1,)), (target, (2,))]},
            "chronicle_ops.upgrade.compose_names": {"return_value": ["docker-compose.yml", "overlays/monitoring.yml"]},
            "chronicle_ops.upgrade.compose_release": {"side_effect": compose},
            "chronicle_ops.upgrade.run": {"side_effect": run},
            "chronicle_ops.upgrade.postgres_sql": {"return_value": "180006"},
            "chronicle_ops.upgrade.require_no_encrypted_collection": {},
            "chronicle_ops.upgrade.merge_env": {},
            "chronicle_ops.upgrade.cleanup_releases": {},
            "chronicle_ops.upgrade.rollback_dump": {"side_effect": dump},
            "chronicle_ops.release.release_command": {"return_value": (["docker", "compose"], {})},
            "chronicle_ops.upgrade.write_json": {},
            "chronicle_ops.upgrade.finish_operation": {"side_effect": lambda *args: self.recorded.append((self.cwd, os.environ.get("COMPOSE_FILE")))},
            "chronicle_ops.reconcile.install": {},
            "chronicle_ops.upgrade.preflight": {"side_effect": lambda: self.events.append(("scheduler-preflight",))},
            "chronicle_ops.upgrade.shutil.which": {"return_value": "/bin/tool"},
            "chronicle_ops.upgrade.os.path.lexists": {"side_effect": lexists},
            "chronicle_ops.upgrade.os.chdir": {"side_effect": lambda path: setattr(self, "cwd", Path(path))},
            "chronicle_ops.receipts.os.replace": {"side_effect": lambda *args: self.events.append(("rename",))},
            "chronicle_ops.receipts.os.open": {"return_value": 17},
            "chronicle_ops.receipts.os.fsync": {"side_effect": lambda fd: self.events.append(("fsync", fd))},
            "chronicle_ops.receipts.os.close": {},
        }
        self.mocks = {name: self.stack.enter_context(patch(name, **kwargs)) for name, kwargs in patches.items()}
        self.stack.enter_context(patch.dict(os.environ, {"UPGRADE_WAIT_TIMEOUT_SECONDS": "17", ENABLED_ENV: "false"}))
        self.stack.enter_context(patch.object(Path, "cwd", return_value=Path("/new/selfhost")))
        for name in ("is_dir", "is_file"):
            self.stack.enter_context(patch.object(Path, name, return_value=True))
        self.stack.enter_context(patch.object(Path, "resolve", lambda path: path))
        self.stack.enter_context(patch.object(Path, "is_symlink", return_value=False))
        self.stack.enter_context(patch.object(Path, "stat", return_value=type("Stat", (), {"st_mode": stat.S_IFREG | 0o600})()))
        self.stack.enter_context(patch.object(Path, "read_text", return_value="template"))
        self.stack.enter_context(patch.object(Path, "mkdir", mkdir))
        self.stack.enter_context(patch.object(Path, "chmod"))
        self.removed = self.stack.enter_context(patch.object(Path, "unlink", autospec=True))
        self.released = self.stack.enter_context(patch.object(Path, "rmdir", autospec=True))
        self.stack.enter_context(patch("sys.stdout", io.StringIO()))
        self.errors = self.stack.enter_context(patch("sys.stderr", new_callable=io.StringIO))

    def receipt(self, status):
        cleanup = self.mocks["chronicle_ops.upgrade.cleanup_releases"]
        if status == 0:
            cleanup.assert_called_once_with(Path('/new').parent, Path('/state'), apply=True, rollback_target=Path('/old'))
        else:
            cleanup.assert_not_called()
        call = self.mocks["chronicle_ops.upgrade.finish_operation"].call_args
        self.assertEqual(call.args[:3], ("upgrade", status, "upgrade_failed"))

    def test_success_order_receipt_and_environment_isolation(self):
        self.assertEqual(upgrade("/old/selfhost"), 0)
        stop = next(i for i, row in enumerate(self.events) if row[:2] == ("old", "stop"))
        dump = self.events.index(("dump",))
        start = next(i for i, row in enumerate(self.events) if row[:2] == ("new", "up"))
        self.assertIn('--force-recreate', self.events[start])
        self.assertLess(stop, dump)
        self.assertLess(dump, start)
        # The operation is recorded through the started release, never the previous project definition.
        self.assertEqual(self.recorded, [(Path("/new/selfhost"), "docker-compose.yml:overlays/monitoring.yml")])
        # Every previous service, not only the writers, stops before the new networks are created.
        self.assertIn(("old", "stop"), self.events[dump:start])
        self.assertLess(dump, self.events.index(("rename",)))
        self.assertLess(self.events.index(("rename",)), self.events.index(("fsync", 17)))
        self.assertLess(self.events.index(("fsync", 17)), start)
        self.mocks["chronicle_ops.receipts.os.open"].assert_called_once_with(Path("/state/backups"), os.O_RDONLY)
        self.assertFalse(any(row[:2] == ("old", "up") for row in self.events))
        self.assertEqual(self.mocks["chronicle_ops.upgrade.require_no_encrypted_collection"].call_count, 2)
        self.assertEqual(self.mocks["chronicle_ops.upgrade.write_json"].call_args.args[1]["status"], "succeeded")
        self.released.assert_called_once_with(Path("/state/.chronicle-upgrade.lock"))
        self.receipt(0)
        self.assertLess(self.events.index(("scheduler-preflight",)), stop)
        self.mocks["chronicle_ops.reconcile.install"].assert_called_once_with(Path("/new/selfhost/chronicle"), Path("/state"), "pilot")

    def test_scheduler_preflight_failure_leaves_writers_running(self):
        self.mocks["chronicle_ops.upgrade.preflight"].side_effect = ValueError("scheduler unavailable")
        self.assertEqual(upgrade("/old/selfhost"), 1)
        self.assertFalse(any(row[1:2] == ("stop",) for row in self.events))
        self.mocks["chronicle_ops.reconcile.install"].assert_not_called()

    def test_upgrade_reloads_credentials_after_waiting_for_rotation_lock(self):
        settings = self.mocks["chronicle_ops.upgrade.read_env"].return_value
        settings["JWT_SECRET"] = "retired-secret"
        latest = dict(settings, JWT_SECRET="rotated-secret", POSTGRES_PASSWORD="rotated-password")
        def acquire(_state):
            self.mocks["chronicle_ops.upgrade.read_env"].return_value = latest
        self.mocks["chronicle_ops.upgrade.acquire_operation_lock"].side_effect = acquire
        self.assertEqual(upgrade("/old/selfhost"), 0)
        self.assertEqual(self.mocks["chronicle_ops.upgrade.merge_env"].call_args.args[0], latest)

    def test_upgrade_honors_saved_reconciliation_opt_out_without_export(self):
        os.environ.pop(ENABLED_ENV, None)
        self.mocks["chronicle_ops.upgrade.read_env"].return_value[ENABLED_ENV] = "false"
        self.assertEqual(upgrade("/old/selfhost"), 0)
        self.assertEqual(os.environ[ENABLED_ENV], "false")

    def test_interrupted_start_names_the_backup_and_never_restarts_old(self):
        self.failure = "interrupt"
        self.assertEqual(upgrade("/old/selfhost"), 143)
        self.assertIn("Recovery: the verified pre-upgrade backup is /state/backups/pre-upgrade-", self.errors.getvalue())
        self.assertFalse(any(row[:2] == ("old", "up") for row in self.events))

    def test_backup_directory_sync_failure_restarts_old_before_any_new_start(self):
        self.mocks["chronicle_ops.receipts.os.fsync"].side_effect = OSError("sync failed")
        self.assertEqual(upgrade("/old/selfhost"), 1)
        self.assertTrue(any(row[:2] == ("old", "up") for row in self.events))
        self.assertFalse(any(row[:2] == ("new", "up") for row in self.events))
        self.assertEqual(self.recorded, [(Path("/old/selfhost"), "overlays/monitoring.yml")])
        self.mocks["chronicle_ops.receipts.os.close"].assert_called_once_with(17)
        self.receipt(1)

    def test_recovery_publication_failure_restarts_old_and_releases_interlocks(self):
        from chronicle_ops.reconcile import RECOVERY_FILE
        def publish(path, data):
            if path.name == RECOVERY_FILE:
                raise OSError("recovery publication failed")
        self.mocks["chronicle_ops.upgrade.write_json"].side_effect = publish
        self.assertEqual(upgrade("/old/selfhost"), 1)
        self.assertTrue(any(row[:2] == ("old", "up") for row in self.events))
        self.assertFalse(any(row[:2] == ("new", "up") for row in self.events))
        self.assertIn(Path("/new/selfhost/.env"), [call.args[0] for call in self.removed.call_args_list])
        self.released.assert_called_once_with(Path("/state/.chronicle-upgrade.lock"))

    def test_tool_failures_record_receipt_in_previous_deployment(self):
        for failure in ("docker", "compose"):
            with self.subTest(failure=failure):
                self.setUp()
                if failure == "docker":
                    self.mocks["chronicle_ops.upgrade.shutil.which"].return_value = None
                else:
                    self.mocks["chronicle_ops.upgrade.run"].side_effect = None
                    self.mocks["chronicle_ops.upgrade.run"].return_value = subprocess.CompletedProcess([], 1)
                self.assertEqual(upgrade("/old/selfhost"), 1)
                self.receipt(1)
                self.assertEqual(os.environ["CHRONICLE_OPS_STATE"], "/state")
                self.assertFalse(self.locked)
                self.doCleanups()

    def test_failures_restart_old_only_before_new_start_and_record_one_outcome(self):
        for failure in ("stop", "dump", "discovery", "startup", "verify"):
            with self.subTest(failure=failure):
                self.setUp()
                self.failure = failure
                self.assertEqual(upgrade("/old/selfhost"), 1)
                self.assertEqual(any(row[:2] == ("old", "up") for row in self.events), failure in ("stop", "dump", "discovery"))
                removed = [call.args[0] for call in self.removed.call_args_list]
                self.assertEqual(Path("/new/selfhost/.env") in removed, failure in ("stop", "dump", "discovery"))
                if failure in ("startup", "verify"):
                    self.released.assert_not_called()
                    checkpoints = [call.args[1] for call in self.mocks["chronicle_ops.upgrade.write_json"].call_args_list if call.args[0].name == "recovery.json"]
                    self.assertEqual(checkpoints[0]["owner"], "/new/selfhost")
                    self.assertEqual(checkpoints[0]["phase"], "migration-started")
                else:
                    self.released.assert_called_once_with(Path("/state/.chronicle-upgrade.lock"))
                self.receipt(1)
                self.mocks["chronicle_ops.upgrade.finish_operation"].assert_called_once()
                self.doCleanups()

    def test_cleanup_deletion_errors_still_restart_release_lock_and_record_receipt(self):
        self.failure = "dump"
        self.removed.side_effect = PermissionError("read-only")
        self.assertEqual(upgrade("/old/selfhost"), 1)
        self.assertTrue(any(row[:2] == ("old", "up") for row in self.events))
        self.released.assert_called_once_with(Path("/state/.chronicle-upgrade.lock"))
        self.receipt(1)
        self.assertIn("could not remove", self.errors.getvalue())

    def test_post_acquisition_interlocks(self):
        for name in (".chronicle-restore.lock", ".chronicle-secret-rotation"):
            with self.subTest(name=name):
                self.setUp()
                self.race = name
                self.assertEqual(upgrade("/old/selfhost"), 1)
                self.assertIn("started while the upgrade lock was being acquired", self.errors.getvalue())
                self.assertFalse(any("stop" in row or row == ("dump",) for row in self.events))
                self.released.assert_called_once()
                self.doCleanups()
