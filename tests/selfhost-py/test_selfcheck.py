import io
from pathlib import Path
import signal
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "selfhost/backup-image"))
import selfcheck


class SelfcheckTests(unittest.TestCase):
    def setUp(self):
        for name, options in (("os.open", {"return_value": 17}), ("os.close", {}), ("fcntl.flock", {})):
            mock = patch("selfcheck." + name, **options)
            mock.start()
            self.addCleanup(mock.stop)

    source = {"database_bytes": 4096, "version": "112", "tables": ["studies", "study_participants"], "studies": 2, "study_participants": 3}

    def test_cleanup_on_success_failure_timeout_and_signal(self):
        for failure in (None, RuntimeError("restore failed"), RuntimeError("self-check interrupted by signal 15"), subprocess.TimeoutExpired("psql", 15)):
            with self.subTest(failure=failure), patch("selfcheck.os.replace"), patch("selfcheck.publish_backup"), \
                 patch("selfcheck.dump_snapshot", return_value=self.source), \
                 patch("selfcheck.check_dump", side_effect=failure), patch("selfcheck.drop_scratch") as drop, \
                 patch("sys.stdout", io.StringIO()), patch("sys.stderr", io.StringIO()):
                self.assertEqual(selfcheck.main(["dump", "chronicle", "backup.sql.gz", "-Z1"]), int(failure is not None))
                drop.assert_called_once_with()

    def test_reserved_source_never_drops_itself(self):
        with patch("selfcheck.drop_scratch") as drop, patch("sys.stderr", io.StringIO()):
            self.assertEqual(selfcheck.main(["dump", selfcheck.SCRATCH, "backup.sql.gz"]), 1)
            drop.assert_not_called()

    def test_cleanup_failure_turns_success_into_failure(self):
        with patch("selfcheck.dump_snapshot", return_value=self.source), patch("selfcheck.check_dump"), \
             patch("selfcheck.drop_scratch", side_effect=subprocess.CalledProcessError(1, "psql")), \
             patch("sys.stdout", io.StringIO()), patch("sys.stderr", io.StringIO()) as error:
            self.assertEqual(selfcheck.main(["dump", "chronicle", "backup.sql.gz"]), 1)
            self.assertIn("scratch cleanup failed", error.getvalue())

    def test_space_guard_uses_uncompressed_size_and_fails_closed(self):
        for disk in ("disk 100 1 0 1% /db", "disk 100 1 4 1% /db", "malformed"):
            with self.subTest(disk=disk), patch("selfcheck.validate_dump", return_value=4096), \
                 patch("selfcheck.psql", return_value=disk), \
                 patch("selfcheck.drop_scratch") as drop:
                with self.assertRaisesRegex(RuntimeError, "insufficient space"):
                    selfcheck.check_dump("chronicle", Path("backup.sql.gz"), self.source)
                drop.assert_not_called()

    def test_space_guard_also_reserves_the_source_database_size(self):
        source = dict(self.source, database_bytes=1024 * 1024)
        with patch("selfcheck.validate_dump", return_value=4096), \
             patch("selfcheck.psql", return_value="disk 100 1 16 1% /db"), \
             patch("selfcheck.drop_scratch") as drop:
            with self.assertRaisesRegex(RuntimeError, "insufficient space"):
                selfcheck.check_dump("chronicle", Path("backup.sql.gz"), source)
            drop.assert_not_called()

    def test_scratch_cleanup_is_bounded(self):
        with patch("selfcheck.subprocess.run", return_value=subprocess.CompletedProcess([], 0)) as call:
            selfcheck.drop_scratch()
            self.assertIn("DROP DATABASE IF EXISTS " + selfcheck.SCRATCH, call.call_args.kwargs["input"])
            self.assertEqual(call.call_args.kwargs["timeout"], 15)

    def test_signal_is_an_error_for_the_cleanup_path(self):
        with self.assertRaisesRegex(RuntimeError, "signal 15"):
            selfcheck.interrupted(signal.SIGTERM, None)
