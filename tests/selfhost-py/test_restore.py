import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "selfhost"))
from chronicle_ops.dump import safe_dump
from chronicle_ops.restore import EXIT_REJECTED_BEFORE_MUTATION, EXIT_RESTORE_TRANSACTION_ROLLED_BACK, Interrupted, Restore, RestoreError, resolve_host_path


DUMP = (b"-- PostgreSQL database dump\n\\restrict fixture\nSELECT 1;\n"
        b"\\unrestrict fixture\n-- PostgreSQL database dump complete\n")


class MemoryFiles:
    def __init__(self):
        self.dirs = {"/deployment", "/deployment/backups", "/deployment/backups/last"}
        self.files = {"/deployment/backups/last/chronicle-latest.sql.gz": gzip.compress(DUMP, mtime=0)}
        self.links = {}
        self.faults = {}
        self.history = []

    def fault(self, action, path):
        error = self.faults.get((action, str(path)))
        if error:
            raise error

    def mkdir(self, path, **kwargs):
        self.fault("mkdir", path)
        key = str(path)
        if self.exists(key):
            raise FileExistsError(key)
        self.dirs.add(key)
        self.history.append(("mkdir", key, kwargs.get("mode")))

    def exists(self, path):
        key = str(path)
        return key in self.dirs or key in self.files or key in self.links

    def resolve(self, path, strict=False):
        self.fault("resolve", path)
        path = Path(self.links.get(str(path), str(path)))
        if strict and not self.exists(path):
            raise FileNotFoundError(str(path))
        return path

    def chmod(self, path, mode):
        self.fault("chmod", path)
        self.history.append(("chmod", str(path), mode))

    def write_text(self, path, value):
        self.fault("write", path)
        self.files[str(path)] = value.encode()
        self.history.append(("write", str(path), value))

    def replace(self, source, target):
        self.fault("replace", target)
        self.files[str(target)] = self.files.pop(str(source))
        self.history.append(("replace", str(target), self.files[str(target)]))

    def unlink(self, path, missing_ok=False):
        self.fault("unlink", path)
        self.files.pop(str(path), None)
        self.links.pop(str(path), None)

    def rmdir(self, path):
        self.fault("rmdir", path)
        if any(name.startswith(str(path) + "/") for name in self.files):
            raise OSError("not empty")
        self.dirs.remove(str(path))

    def open_gzip(self, path, mode):
        self.fault("gzip", path)
        return gzip.GzipFile(fileobj=io.BytesIO(self.files[str(path)]), mode=mode)

    def patches(self):
        return [
            patch.object(Path, "mkdir", lambda path, **kw: self.mkdir(path, **kw)),
            patch.object(Path, "resolve", lambda path, strict=False: self.resolve(path, strict)),
            patch.object(Path, "is_dir", lambda path: str(path) in self.dirs),
            patch.object(Path, "is_file", lambda path: str(path) in self.files),
            patch.object(Path, "is_symlink", lambda path: str(path) in self.links),
            patch.object(Path, "stat", lambda path: SimpleNamespace(st_size=len(self.files[str(path)]))),
            patch.object(Path, "chmod", lambda path, mode: self.chmod(path, mode)),
            patch.object(Path, "write_text", lambda path, value, **kw: self.write_text(path, value)),
            patch.object(Path, "unlink", lambda path, missing_ok=False: self.unlink(path, missing_ok)),
            patch.object(Path, "rmdir", lambda path: self.rmdir(path)),
            patch("chronicle_ops.restore.os.replace", self.replace),
            patch("chronicle_ops.restore.os.path.lexists", self.exists),
            patch.object(Path, "open", lambda path, mode: io.BytesIO(self.files[str(path)])),
            patch("chronicle_ops.dump.gzip.open", self.open_gzip),
        ]


class FakeRunner:
    def __init__(self, fs):
        self.fs = fs
        self.calls = []
        self.fail_at = {}
        self.outputs = {}
        self.services = "postgres\nbackend\nweb\ndb-init\ndb-backup\nrestore"
        self.startup = "postgres\nbackend\nweb\ndb-init\ndb-backup\nca-export"
        self.before = "postgres\nbackend\nweb\ndb-backup"
        self.after = "postgres"
        self.ps_count = 0
        self.hook = None

    def compose(self, *args, capture=False, quiet=False):
        status, output = self(["dc", *args], capture=capture, quiet=quiet)
        return SimpleNamespace(returncode=status, stdout=output)

    def __call__(self, args, capture=False, quiet=False):
        self.calls.append((args, capture, quiet))
        number = len(self.calls)
        if self.hook:
            self.hook(number, args)
        if number in self.fail_at:
            failure = self.fail_at[number]
            if isinstance(failure, BaseException):
                raise failure
            return failure, ""
        if number in self.outputs:
            return 0, self.outputs[number]
        if args[:5] == ["dc", "--profile", "restore", "config", "--services"]:
            return 0, self.services
        if args[:5] == ["dc", "--profile", "restore", "ps", "--status"]:
            self.ps_count += 1
            return 0, self.before if self.ps_count == 1 else self.after
        if args == ["dc", "config", "--services"]:
            return 0, self.startup
        return 0, ""


class RestoreTests(unittest.TestCase):
    lock = "/deployment/.chronicle-restore.lock"
    dump_path = "/deployment/backups/last/chronicle-latest.sql.gz"

    def setUp(self):
        self.fs = MemoryFiles()
        self.runner = FakeRunner(self.fs)
        self.out, self.err = io.StringIO(), io.StringIO()
        for item in self.fs.patches() + [patch("sys.stdout", self.out), patch("sys.stderr", self.err),
                                       patch("chronicle_ops.restore.compose", self.runner.compose),
                                       patch("chronicle_ops.restore.acquire_operation_lock", return_value=None),
                                       patch("chronicle_ops.restore.release_operation_lock"),
                                       patch("chronicle_ops.restore.write_text", self.fs.write_text),
                                       patch("chronicle_ops.restore.finish_operation") ]:
            item.start()
            self.addCleanup(item.stop)
        self.operation = Restore("/deployment", "/deployment/backups", "", self.digest(), "17",
                                 False, True, False, "123")

    def digest(self):
        return hashlib.sha256(self.fs.files[self.dump_path]).hexdigest()

    def phases(self):
        return [row[2].decode().strip() for row in self.fs.history
                if row[:2] == ("replace", self.lock + "/phase")]

    def args(self):
        return [row[0] for row in self.runner.calls]

    def recovery(self):
        return [args for args in self.args() if "--no-deps" in args and args[1] == "up"]

    def test_success_order_permissions_and_profile(self):
        self.assertEqual(self.operation.execute(), 0)
        self.assertEqual(self.phases(), ["prepared", "stopping-services", "restoring",
                                        "database-restored", "starting-services", "verified"])
        self.assertNotIn(self.lock, self.fs.dirs)
        self.assertEqual(self.args()[2], ["dc", "stop", "backend", "web", "db-init", "db-backup"])
        self.assertEqual(self.args()[4], ["dc", "--profile", "restore", "run", "--rm", "-e",
                                         "CHRONICLE_RESTORE_ORCHESTRATED=true", "-e",
                                         "CHRONICLE_RESTORE_TRUSTED_SHA256=" + self.digest(),
                                         "-e", "RESTORE_FILE=/backups/last/chronicle-latest.sql.gz", "restore"])
        self.assertEqual(self.args()[6], ["dc", "up", "-d", "--wait", "--wait-timeout", "17",
                                         "--remove-orphans", "--force-recreate", "postgres", "backend", "web", "db-init", "db-backup"])
        self.assertEqual(self.args()[7], ["dc", "run", "--rm", "--no-deps", "ca-export"])
        self.assertEqual(self.recovery(), [])
        self.assertIn(("chmod", self.lock, 0o700), self.fs.history)
        self.assertIn(("chmod", self.lock + "/.phase.123", 0o600), self.fs.history)

    def test_no_start(self):
        self.operation.no_start = True
        self.assertEqual(self.operation.execute(), 0)
        self.assertIn("CHRONICLE_RESTORE_LEAVE_STOPPED=true", self.args()[4])
        self.assertFalse(any(args[:2] == ["dc", "up"] for args in self.args()))
        self.assertIn("/deployment/.chronicle-stopped", self.fs.files)
        self.assertEqual(self.phases()[-1], "database-restored")
        self.assertIn("application services remain stopped because --no-start", self.out.getvalue())

    def test_no_start_continuity_rejection_preserves_destructive_phase(self):
        self.operation.no_start = True
        self.runner.fail_at[5] = 45
        self.assertEqual(self.operation.execute(), 1)
        self.assertIn("CHRONICLE_RESTORE_LEAVE_STOPPED=true", self.args()[4])
        self.assertEqual(self.fs.files[self.lock + "/phase"], b"restoring\n")
        self.assertEqual(self.recovery(), [])
        self.assertFalse(any(args[:2] == ["dc", "up"] for args in self.args()))

    def test_rollback_transaction_refusal_resumes_current_services_and_releases_lock(self):
        self.operation.no_start = True
        self.runner.fail_at[5] = EXIT_RESTORE_TRANSACTION_ROLLED_BACK
        self.assertEqual(self.operation.execute(), 1)
        self.assertEqual(self.recovery(), [["dc", "up", "-d", "--wait", "--wait-timeout", "17",
                                           "--no-deps", "backend", "web", "db-backup"]])
        self.assertNotIn(self.lock, self.fs.dirs)
        self.assertIn("live database was preserved", self.err.getvalue())

    def test_optional_services(self):
        self.runner.services = "postgres\nbackend\nweb\nrestore"
        self.runner.startup = "postgres\nbackend\n\nweb"
        self.assertEqual(self.operation.execute(), 0)
        self.assertEqual(self.args()[2], ["dc", "stop", "backend", "web", "db-init"])
        self.assertFalse(any(args[-1] == "ca-export" for args in self.args()))

    def test_each_command_failure_and_exact_recovery(self):
        messages = ["configuration is invalid",
                    "inspect running", "stop every", "verify that", "deliberately left stopped",
                    "post-restore Compose", "did not return healthy", "could not publish its local CA"]
        for step in range(1, 9):
            with self.subTest(step=step):
                self.setUp()
                self.runner.fail_at[step] = 42
                self.assertEqual(self.operation.execute(), 1)
                self.assertIn(messages[step - 1], self.err.getvalue())
                if step in (3, 4):
                    self.assertEqual(self.recovery(), [["dc", "up", "-d", "--wait", "--wait-timeout", "17",
                                                       "--no-deps", "backend", "web", "db-backup"]])
                else:
                    self.assertEqual(self.recovery(), [])
                self.assertEqual(self.lock in self.fs.dirs, step >= 5)
                if step >= 5:
                    phase = "restoring" if step == 5 else "starting-services"
                    self.assertEqual(self.fs.files[self.lock + "/phase"], (phase + "\n").encode())
                stops = [args for args in self.args() if args[:2] == ["dc", "stop"]]
                self.assertEqual(len(stops), 2 if step >= 7 else 1 if step >= 3 else 0)
                if step >= 7:
                    self.assertEqual(self.runner.calls[-1], (stops[-1], False, True))
                self.doCleanups()

    def test_exit_46_releases_lock_and_recovers_previous_services(self):
        self.runner.fail_at[5] = EXIT_REJECTED_BEFORE_MUTATION
        self.assertEqual(self.operation.execute(), 1)
        self.assertEqual(self.recovery(), [["dc", "up", "-d", "--wait", "--wait-timeout", "17",
                                           "--no-deps", "backend", "web", "db-backup"]])
        self.assertNotIn(self.lock, self.fs.dirs)
        self.assertIn("backup changed before database mutation", self.err.getvalue())

    def test_recovery_restart_failure_still_releases_lock(self):
        self.runner.fail_at = {3: 42, 4: 43}
        self.assertEqual(self.operation.execute(), 1)
        self.assertNotIn(self.lock, self.fs.dirs)
        self.assertIn("could not all be restarted", self.err.getvalue())
        self.assertIn("Diagnose Docker Compose, then run ./chronicle up.", self.err.getvalue())

    def test_no_previously_running_services(self):
        self.runner.before = "postgres"
        self.runner.fail_at[3] = 42
        self.assertEqual(self.operation.execute(), 1)
        self.assertEqual(self.recovery(), [])
        self.assertNotIn(self.lock, self.fs.dirs)

    def test_startup_and_ca_failure_stop_warning(self):
        for step, message in ((7, "startup failure"), (8, "CA export failure")):
            with self.subTest(step=step):
                self.setUp()
                self.runner.fail_at = {step: 42, step + 1: 43}
                self.assertEqual(self.operation.execute(), 1)
                self.assertIn("could not confirm every application service stopped after " + message,
                              self.err.getvalue())
                self.assertIn(self.lock, self.fs.dirs)
                self.doCleanups()

    def test_running_service_rejection(self):
        for running, message, recovery in (("postgres\nrestore", "already running", False),
                                          ("postgres\nbackend", "still running", True),
                                          ("postgres\nrestore", "different one-shot", True)):
            with self.subTest(message=message):
                self.setUp()
                if recovery:
                    self.runner.after = running
                else:
                    self.runner.before = running
                self.assertEqual(self.operation.execute(), 1)
                self.assertIn(message, self.err.getvalue())
                self.assertEqual(bool(self.recovery()), recovery)
                self.assertFalse(any(args[-1] == "restore" and "run" in args for args in self.args()))
                self.assertNotIn(self.lock, self.fs.dirs)
                self.doCleanups()

    def test_required_services(self):
        for missing in ("postgres", "backend", "web", "restore"):
            with self.subTest(missing=missing):
                self.runner.services = "\n".join(name for name in ("postgres", "backend", "web", "restore")
                                                 if name != missing)
                self.assertEqual(self.operation.execute(), 1)
                self.assertIn("missing required service: " + missing, self.err.getvalue())
                self.assertNotIn(self.lock, self.fs.dirs)

    def test_empty_startup_list(self):
        self.runner.startup = "ca-export\n"
        self.assertEqual(self.operation.execute(), 1)
        self.assertIn("no long-running services", self.err.getvalue())
        self.assertIn(self.lock, self.fs.dirs)

    def test_service_names_preserve_literal_line_endings(self):
        self.runner.services = "postgres\r\nbackend\nweb\nrestore"
        self.assertEqual(self.operation.execute(), 1)
        self.assertIn("missing required service: postgres", self.err.getvalue())
        self.assertNotIn(self.lock, self.fs.dirs)

    def test_timeout_validation(self):
        for value, message in (("0", "positive integer"), ("01", "positive integer"),
                               ("-1", "positive integer"), ("x", "positive integer"),
                               ("3601", "not exceed 3600")):
            with self.subTest(value=value):
                self.operation.timeout = value
                self.assertEqual(self.operation.execute(), 1)
                self.assertIn(message, self.err.getvalue())
                self.assertEqual(self.args(), [])

    def test_timeout_bound_does_not_wrap_large_integers(self):
        self.operation.timeout = "18446744073709551616"
        self.assertEqual(self.operation.execute(), 1)
        self.assertIn("must not exceed 3600", self.err.getvalue())
        self.assertEqual(self.args(), [])
        self.operation.timeout = "3600"
        self.assertEqual(self.operation.execute(), 0)
        self.assertIn("3600", self.args()[6])

    def test_missing_state_root(self):
        self.fs.dirs.remove("/deployment")
        self.assertEqual(self.operation.execute(), 1)
        self.assertIn("CHRONICLE_STATE_DIR does not exist: /deployment", self.err.getvalue())

    def test_control_character_path(self):
        self.operation.container_path = "/backups/bad\n.sql.gz"
        self.assertEqual(self.operation.execute(), 1)
        self.assertIn("must not contain control characters", self.err.getvalue())

    def test_missing_or_empty_dump(self):
        self.operation.container_path = "/backups/no.sql.gz"
        self.assertEqual(self.operation.execute(), 1)
        self.assertIn("dump is unavailable or unsafe", self.err.getvalue())
        self.operation.container_path = "/backups/last/chronicle-latest.sql.gz"
        self.fs.files[self.dump_path] = b""
        self.assertEqual(self.operation.execute(), 1)
        self.assertIn("restore dump is empty", self.err.getvalue())

    def test_confirmation(self):
        self.operation.assume_yes = False
        self.assertEqual(self.operation.execute(), 1)
        self.assertIn("confirmation requires a terminal", self.err.getvalue())
        self.operation.terminal = True
        with patch("builtins.input", return_value="n"):
            self.assertEqual(self.operation.execute(), 1)
        self.assertIn("restore cancelled", self.err.getvalue())

    def test_confirmation_acceptance(self):
        self.operation.assume_yes = False
        self.operation.terminal = True
        with patch("builtins.input", return_value="Y") as confirm:
            self.assertEqual(self.operation.execute(), 0)
        confirm.assert_called_once_with("Stop Chronicle and replace its database with this dump? [y/N] ")

    def test_interlocks_and_dangling_symlinks(self):
        for name, operation in ((".chronicle-upgrade.lock", "upgrade"),
                                (".chronicle-secret-rotation", "secret rotation")):
            with self.subTest(name=name):
                self.fs.links["/deployment/" + name] = "/missing"
                self.assertEqual(self.operation.execute(), 1)
                self.assertIn(operation + " is active or incomplete", self.err.getvalue())
                self.assertNotIn(self.lock, self.fs.dirs)
                self.fs.links.clear()

    def test_post_acquisition_interlocks(self):
        for name in (".chronicle-upgrade.lock", ".chronicle-secret-rotation"):
            with self.subTest(name=name):
                self.setUp()
                original = self.fs.mkdir
                def raced(path, **kwargs):
                    original(path, **kwargs)
                    self.fs.dirs.add("/deployment/" + name)
                with patch.object(Path, "mkdir", raced):
                    self.assertEqual(self.operation.execute(), 1)
                self.assertIn("started while the restore lock was being acquired", self.err.getvalue())
                self.assertNotIn(self.lock, self.fs.dirs)
                self.assertEqual(self.recovery(), [])
                self.doCleanups()

    def test_adoption_rollback_owner_can_restore_through_the_preserved_upgrade_lock(self):
        from chronicle_ops.reconcile import RECOVERY_FILE, RECOVERY_PHASE
        marker = '/deployment/.chronicle-upgrade.lock'
        self.fs.dirs.add(marker)
        self.fs.files[marker + '/' + RECOVERY_FILE] = json.dumps({
            'owner': '/new/selfhost', 'phase': RECOVERY_PHASE}).encode()
        self.operation.recovery_owner = '/new/selfhost'
        self.operation.no_start = True
        with patch.object(Path, 'read_text', lambda path: self.fs.files[str(path)].decode()):
            self.assertEqual(self.operation.execute(), 0)
        self.assertIn('CHRONICLE_RESTORE_LEAVE_STOPPED=true', self.args()[4])
        docs = Path(__file__).resolve().parents[2] / 'selfhost/docs/UPGRADE-ROLLBACK.md'
        # The adoption runbook must invoke the handoff that supplies this recovery owner.
        with open(docs) as handle:
            adoption = handle.read().split('After successful adoption,')[0]
        self.assertIn('./chronicle rollback --from /absolute/path/to/source/selfhost', adoption)
        self.assertNotIn('./chronicle restore --no-start', adoption)

    def test_existing_restore_lock(self):
        self.fs.dirs.add(self.lock)
        self.assertEqual(self.operation.execute(), 1)
        self.assertIn("another restore is active or incomplete", self.err.getvalue())
        self.assertIn(self.lock, self.fs.dirs)

    def test_metadata_failures(self):
        for action, path, message in (("chmod", self.lock, "protect restore lock"),
                                     ("write", self.lock + "/.owner-pid.123", "write restore operation metadata"),
                                     ("chmod", self.lock + "/.owner-pid.123", "protect restore operation metadata"),
                                     ("replace", self.lock + "/owner-pid", "publish restore operation metadata")):
            with self.subTest(action=action):
                self.setUp()
                self.fs.faults[(action, path)] = OSError("fixture")
                self.assertEqual(self.operation.execute(), 1)
                self.assertIn(message, self.err.getvalue())
                self.assertNotIn(self.lock, self.fs.dirs)
                self.assertEqual(self.recovery(), [])
                self.doCleanups()

    def test_each_phase_write_failure(self):
        for phase in ("prepared", "stopping-services", "restoring", "database-restored",
                      "starting-services", "verified"):
            with self.subTest(phase=phase):
                self.setUp()
                original = self.operation.write_lock
                def failing(name, value):
                    if name == "phase" and value == phase:
                        raise RestoreError("could not write restore operation metadata")
                    original(name, value)
                with patch.object(self.operation, "write_lock", failing):
                    self.assertEqual(self.operation.execute(), 1)
                self.assertEqual(self.lock in self.fs.dirs, phase not in ("prepared", "stopping-services"))
                self.assertEqual(self.recovery(), [])
                self.doCleanups()

    def test_lock_release_failure_after_success_preserves_lock(self):
        self.fs.faults[("rmdir", self.lock)] = OSError("fixture")
        self.assertEqual(self.operation.execute(), 1)
        self.assertIn(self.lock, self.fs.dirs)
        self.assertIn("operation lock could not be released", self.err.getvalue())
        self.assertIn("do not start Chronicle", self.err.getvalue())

    def test_lock_release_failure_before_mutation_warns(self):
        self.fs.faults[("rmdir", self.lock)] = OSError("fixture")
        self.runner.fail_at[3] = 42
        self.assertEqual(self.operation.execute(), 1)
        self.assertIn("could not release restore lock", self.err.getvalue())

    def test_release_missing_symlink_and_unlink_failure(self):
        self.assertTrue(self.operation.release())
        self.operation.held = True
        self.assertFalse(self.operation.release())
        self.fs.dirs.add(self.lock)
        self.fs.links[self.lock] = "/missing"
        self.assertFalse(self.operation.release())
        self.fs.links.clear()
        self.fs.files[self.lock + "/phase"] = b"prepared\n"
        self.fs.faults[("unlink", self.lock + "/phase")] = OSError("fixture")
        self.assertFalse(self.operation.release())

    def test_invalid_metadata_field(self):
        with self.assertRaisesRegex(RestoreError, "invalid restore lock field"):
            self.operation.write_lock("../bad", "value")

    def test_trust_digest_and_safe_framing(self):
        for content, digest, message in ((DUMP, "", "independently reviewed"),
                                         (DUMP, "A" * 64, "independently reviewed"),
                                         (DUMP, "0" * 64, "digest mismatch"),
                                         (b"SELECT 1;\n", None, "safe pg_dump restricted framing")):
            with self.subTest(message=message):
                self.fs.files[self.dump_path] = gzip.compress(content)
                self.operation.digest = self.digest() if digest is None else digest
                self.assertEqual(self.operation.execute(), 1)
                self.assertIn(message, self.err.getvalue())
                self.assertNotIn(self.lock, self.fs.dirs)

    def test_decompression_failure_is_rejected_before_stopping(self):
        self.fs.faults[("gzip", self.dump_path)] = EOFError()
        with self.assertRaisesRegex(RestoreError, "trust verification failed"):
            self.operation.trust_dump(Path(self.dump_path))
        self.assertEqual(self.args(), [])

    def test_signal_recovery_before_and_after_mutation(self):
        for step, signum, preserved in ((3, signal.SIGHUP, False), (5, signal.SIGTERM, True)):
            with self.subTest(step=step):
                self.setUp()
                self.runner.fail_at[step] = Interrupted(signum)
                self.assertEqual(self.operation.execute(), 128 + signum)
                self.assertEqual(self.lock in self.fs.dirs, preserved)
                self.assertEqual(bool(self.recovery()), not preserved)
                self.doCleanups()


class PathTests(unittest.TestCase):
    def setUp(self):
        self.fs = MemoryFiles()
        for item in self.fs.patches():
            item.start()
            self.addCleanup(item.stop)

    def test_reject_path_branches(self):
        cases = (("/elsewhere/a.sql.gz", "below /backups"), ("/backups", "below /backups"),
                 ("/backups/../a.sql.gz", "unsafe component"), ("/backups/a.sql", "end in .sql.gz"),
                 ("/backups/a.sql.gz", "cannot resolve"))
        for value, message in cases:
            with self.subTest(value=value):
                with self.assertRaisesRegex(RestoreError, message):
                    resolve_host_path("/deployment/backups", value)

    def test_resolved_escape_control_directory_and_runtime_error(self):
        path = "/deployment/backups/last/chronicle-latest.sql.gz"
        for target, message in (("/outside.sql.gz", "outside the backups directory"),
                                ("/deployment/backups/bad\n.sql.gz", "control character"),
                                ("/deployment/backups/last", "not a regular file")):
            with self.subTest(target=target):
                if target not in self.fs.dirs:
                    self.fs.files[target] = b"fixture"
                self.fs.links[path] = target
                with self.assertRaisesRegex(RestoreError, message):
                    resolve_host_path("/deployment/backups", "/backups/last/chronicle-latest.sql.gz")
        self.fs.faults[("resolve", path)] = RuntimeError("symlink loop")
        with self.assertRaisesRegex(RestoreError, "cannot resolve restore path: symlink loop"):
            resolve_host_path("/deployment/backups", "/backups/last/chronicle-latest.sql.gz")


class DumpTests(unittest.TestCase):
    def test_validator_cli_returns_the_recovery_contract_on_rejected_input(self):
        environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1",
                           PYTHONPATH=str(Path(__file__).resolve().parents[2] / "selfhost"))
        result = subprocess.run([sys.executable, "-m", "chronicle_ops.dump", "/missing-restore-fixture.sql.gz"],
                                env=environment, capture_output=True)
        self.assertEqual(result.returncode, EXIT_REJECTED_BEFORE_MUTATION)

    def framed(self, content):
        return b"-- PostgreSQL database dump\n\\restrict abc\n" + content + b"\n-- PostgreSQL database dump complete\n--\n\\unrestrict abc\n"

    def test_safe_sql_comments_quotes_and_copy_data(self):
        values = [b"SELECT 1;", b"SELECT 'PROGRAM', E'x', 'it''s', \"PR\"\"OGRAM\";",
                  b"SELECT $$PROGRAM \\evil$$, $body$PROGRAM$body$;",
                  b"SELECT 1 /* PROGRAM \\evil\n */; -- PROGRAM \\evil",
                  b"COPY public.events FROM stdin;\n\\evil PROGRAM\n\\.",
                  b"\n -- harmless\n\t\nSELECT 1;"]
        for value in values:
            with self.subTest(value=value):
                self.assertTrue(safe_dump(io.BytesIO(self.framed(value))))

    def test_dump_cannot_commit_or_escape_the_restore_transaction(self):
        for statement in (b'COMMIT;', b'END;', b'BEGIN;', b'START\nTRANSACTION;',
                          b'SELECT 1; COMMIT;', b'PREPARE TRANSACTION \'escape\';'):
            with self.subTest(statement=statement):
                self.assertFalse(safe_dump(io.BytesIO(self.framed(statement))))
        self.assertTrue(safe_dump(io.BytesIO(self.framed(b'CREATE FUNCTION f() RETURNS void AS $$BEGIN NULL; END$$ LANGUAGE plpgsql;'))))

    def test_pg_dump_multiline_statements_are_not_transaction_control(self):
        # Verbatim pg_dump 18.6 output: keywords that open a line inside one statement.
        statements = (b"CREATE SEQUENCE public.t_id_seq\n    AS integer\n    START WITH 1\n    INCREMENT BY 1\n    CACHE 1;",
                      b"ALTER TABLE public.t ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (\n"
                      b"    SEQUENCE NAME public.t_id_seq\n    START WITH 1\n    CACHE 1\n);",
                      b"CREATE VIEW public.v AS\n SELECT\n        CASE\n            WHEN (a > 1) THEN 'x'::text\n"
                      b"            ELSE 'y'::text\n        END AS c\n   FROM public.t;")
        for statement in statements:
            with self.subTest(statement=statement):
                self.assertTrue(safe_dump(io.BytesIO(self.framed(statement))))

    def test_lexes_strings_comments_and_dollar_tags_as_psql_does(self):
        self.assertTrue(safe_dump(io.BytesIO(self.framed(b"SELECT 1 /* a /* nested */ b */;"))))
        # A backslash ends a string at a different quote depending on E'' and
        # standard_conforming_strings, which the dump itself could change.
        refused = (b"SELECT 'x\\';", b"SELECT E'x\\'; COMMIT; --';", b"SELECT 'x\\'; COMMIT; --';",
                   b"SET standard_conforming_strings = off;\nSELECT 'a\\'b'; COMMIT; --';",
                   b"SELECT E'x'\n'y\\';junk';\nCOMMIT;\n--';",     # continuation stays an escape string
                   b"SELECT e/**/'x\\'; COMMIT; --';",              # identifier, comment, standard string
                   "SELECT \u00e9E'x\\'; COMMIT; --';".encode("latin1"),  # high-bit bytes continue identifiers
                   b"SELECT 1;\n/* outer /* inner */ still comment */\nCOMMIT;",
                   b"SELECT foo$x$;\nCOMMIT;\n$x$;",               # foo$x$ is an identifier to psql
                   b"SELECT 1;\x00 junk\nCOMMIT;",                 # psql ends the line at NUL
                   b"-- comment\rCOMMIT;",                           # CR ends a -- comment for psql
                   "SELECT $\u00e9$'$\u00e9$; COMMIT; SELECT $\u00e9$'$\u00e9$;".encode("latin1"),
                   b"PREPARE\nTRANSACTION 'x';",
                   b"COMMIT/*a/*b*/c*/WORK;",                         # a comment is whitespace to psql
                   b"COPY public.t TO/*a/*b*/c*/PROGRAM 'true';",
                   b"\xa0--comment")                                  # only ASCII whitespace is blank
        for dump in refused:
            with self.subTest(dump=dump):
                self.assertFalse(safe_dump(io.BytesIO(self.framed(dump))))

    def test_completion_marker_is_not_copy_data_or_quoted_sql(self):
        contents = (b"COPY public.events FROM stdin;\n-- PostgreSQL database dump complete\n\\.",
                    b"SELECT $$\n-- PostgreSQL database dump complete\n$$;")
        for content in contents:
            dump = b"-- PostgreSQL database dump\n\\restrict abc\n" + content + b"\n\\unrestrict abc\n"
            with self.subTest(content=content):
                self.assertFalse(safe_dump(io.BytesIO(dump)))

    def test_every_unsafe_framing_branch(self):
        values = [b"SELECT 1;", self.framed(b"\\evil"), self.framed(b"SELECT \\evil;"),
                  self.framed(b"COPY t TO PROGRAM 'cmd';"), self.framed(b"SELECT 'open"),
                  self.framed(b'SELECT "open'), self.framed(b"SELECT $tag$open"),
                  self.framed(b"SELECT /* open"), self.framed(b"COPY t FROM STDIN;\nrow"),
                  DUMP.replace(b"\\restrict fixture", b"\\restrict fixture\n\\restrict fixture"),
                  DUMP.replace(b"\\unrestrict fixture", b"\\unrestrict wrong"),
                  DUMP.replace(b"\\restrict fixture\n", b""),
                  DUMP.replace(b"-- PostgreSQL database dump\n", b""),
                  DUMP + b"SELECT 1;\n", DUMP + b"\\restrict extra\n", DUMP + b"\\unrestrict fixture\n"]
        for value in values:
            with self.subTest(value=value):
                self.assertFalse(safe_dump(io.BytesIO(value)))


class RestoreTransactionTests(unittest.TestCase):
    def test_continuity_proof_and_dump_share_transaction_and_producer_failure_cannot_commit(self):
        from chronicle_ops.verify import DATABASE_PRIVILEGES_SQL
        root = Path(__file__).resolve().parents[2]
        source = (root / 'selfhost/restore.sh').read_text()
        start = source.index('if {\ncat <<\'SQL\'\nBEGIN;')
        block = source[start:source.index('\n# ---------------------------------------------------------------------------------------\n# 7.', start)]
        digest = 'RESTORE_SQL_DIR=' + str(root / 'selfhost') + '\n'
        digest += source[source.index('CHECKPOINT_DIGEST_SQL=$(cat '):source.index('\nreadonly CHECKPOINT_DIGEST_SQL')]
        script = '''set -euo pipefail
RESTORE_FILE="$1/restore.sql.gz"
SAFETY_DUMP=synthetic-safety-dump
EXIT_RESTORE_TRANSACTION_ROLLED_BACK="$2"
psql_q() { cat >"$EVIDENCE"; return "$PSQL_STATUS"; }
gzip() { printf '%s\\n' 'CREATE TABLE public.restored_fixture (id integer);'; [[ "$PRODUCER_STATUS" == 0 ]]; }
''' + digest + '\n' + block
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            evidence = Path(folder) / 'stream'
            for proof, producer, expected in ((0, 0, 0), (3, 0, EXIT_RESTORE_TRANSACTION_ROLLED_BACK),
                                               (0, 1, EXIT_RESTORE_TRANSACTION_ROLLED_BACK), (2, 0, 1)):
                result = subprocess.run(['bash', '-c', script, 'fixture', folder, str(EXIT_RESTORE_TRANSACTION_ROLLED_BACK)],
                    env=dict(os.environ, PSQL_STATUS=str(proof), PRODUCER_STATUS=str(producer), EVIDENCE=str(evidence),
                             CHRONICLE_RESTORE_LEAVE_STOPPED='true', DATABASE_PRIVILEGES_SQL=DATABASE_PRIVILEGES_SQL),
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, expected, result.stderr)
                sql = evidence.read_text()
                self.assertEqual(sql.count('BEGIN;'), 1)
                self.assertEqual(sql.count('COMMIT;'), int(producer == 0))
                self.assertTrue(sql.startswith('BEGIN;\n'))
                if producer == 0:
                    self.assertLess(sql.index('CREATE TABLE public.restored_fixture'), sql.index('selected rollback backup predates'))
                    self.assertLess(sql.index('selected rollback backup predates'), sql.index('COMMIT;'))



class RollbackOwnershipTests(unittest.TestCase):
    CONFIG = {"services": {"postgres": {"image": "postgres@sha256:" + "a" * 64},
                           "monitoring-config": {"volumes": [
                               {"type": "volume", "source": "vl_data", "target": "/vldata"},
                               {"type": "volume", "source": "vm_data", "target": "/vmdata"},
                               {"type": "volume", "source": "backend_tls", "target": "/backend-tls", "read_only": True},
                               {"type": "bind", "source": "/bundle/monitoring/render-config.sh", "target": "/r.sh"}]}},
              "volumes": {"vl_data": {"name": "pilot_vl_data"}, "vm_data": {"name": "pilot_vm_data"},
                          "backend_tls": {"name": "pilot_backend_tls"}}}

    def returned(self, config, present):
        from chronicle_ops.restore import return_monitoring_volumes
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            return SimpleNamespace(returncode=0, stdout="\n".join(present))
        with patch("chronicle_ops.restore.compose", return_value=SimpleNamespace(stdout=json.dumps(config))), \
             patch("chronicle_ops.common.run", side_effect=run):
            return_monitoring_volumes("pilot")
        return [args for args in calls if args[:2] == ["docker", "run"]]

    def test_writable_monitoring_volumes_return_to_root_for_the_previous_release(self):
        chown, = self.returned(self.CONFIG, ["pilot_vl_data", "pilot_backend_tls", "other_vm_data"])
        self.assertIn("type=volume,src=pilot_vl_data,dst=/volume/0", chown)
        self.assertNotIn("type=volume,src=pilot_backend_tls,dst=/volume/1", chown)
        self.assertEqual(chown[chown.index("--entrypoint") + 1:], ["chown", self.CONFIG["services"]["postgres"]["image"], "-R", "0:0", "/volume/0"])

    def test_without_monitoring_or_its_volumes_nothing_runs(self):
        self.assertEqual(self.returned({"services": {"postgres": {"image": "p"}}, "volumes": {}}, []), [])
        self.assertEqual(self.returned(self.CONFIG, ["pilot_backend_tls"]), [])


if __name__ == "__main__":
    unittest.main()
