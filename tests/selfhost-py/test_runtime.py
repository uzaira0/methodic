import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "selfhost"))
from chronicle_ops.__main__ import main
from chronicle_ops.common import Interrupted, compose, run
from chronicle_ops.receipts import record_operation


class RuntimeTests(unittest.TestCase):
    def test_timeout_terminates_and_reaps_a_real_child_process(self):
        script = '''
import signal, subprocess, sys, time
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
def stop(*args):
    child.wait()
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
print(child.pid, flush=True)
time.sleep(60)
'''
        with self.assertRaises(subprocess.TimeoutExpired) as caught:
            run([sys.executable, "-c", script], capture=True, timeout=0.5)
        child = int(caught.exception.output)
        try:
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
        finally:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_compose_preserves_arguments_and_capture_stream_quiet_modes(self):
        with patch.dict(os.environ, {"CHRONICLE_OPS_PROJECT": "pilot"}), \
             patch("chronicle_ops.common.subprocess.run") as call:
            compose("exec", "two words", "quote'", "line\nbreak", capture=True)
            self.assertEqual(call.call_args.args[0], ["docker", "compose", "-p", "pilot", "exec", "two words", "quote'", "line\nbreak"])
            self.assertEqual(call.call_args.kwargs["stdout"], subprocess.PIPE)
            compose("stop", quiet=True)
            self.assertEqual(call.call_args.kwargs["stdout"], subprocess.DEVNULL)
            self.assertEqual(call.call_args.kwargs["stderr"], subprocess.DEVNULL)
            compose("up")
            self.assertIsNone(call.call_args.kwargs["stdout"])

    def test_main_restore_config_and_signal_handler(self):
        with patch.dict(os.environ, {"CHRONICLE_OPS_STATE": "/state", "CHRONICLE_OPS_BACKUPS": "/backups", "RESTORE_START_WAIT_TIMEOUT_SECONDS": "17"}), \
             patch("chronicle_ops.__main__.Restore") as restore, \
             patch("chronicle_ops.__main__.signal.signal") as install:
            restore.return_value.execute.return_value = 0
            self.assertEqual(main(["restore", "--no-start", "--trusted-sha256=digest"]), 0)
            self.assertEqual(restore.call_args.args, ("/state", "/backups", "", "digest", "17", True, False))
            self.assertEqual([row.args[0] for row in install.call_args_list], [signal.SIGHUP, signal.SIGINT, signal.SIGTERM])
            with self.assertRaises(Interrupted) as caught:
                install.call_args.args[1](signal.SIGTERM, None)
            self.assertEqual(caught.exception.status, 143)

    def test_monitoring_timeout_and_nonzero_warn_but_do_not_fail_operation(self):
        for failure in (subprocess.TimeoutExpired("docker", 15), subprocess.CompletedProcess([], 42)):
            with self.subTest(failure=failure), \
                 patch.dict(os.environ, {"COMPOSE_FILE": "overlays/monitoring.yml"}), \
                 patch("chronicle_ops.receipts.compose", side_effect=[subprocess.CompletedProcess([], 0, "operational-probe\n"), failure]), \
                 patch("sys.stderr", new_callable=io.StringIO) as output:
                record_operation("restore", "failure", "restore_failed")
                self.assertIn("could not be recorded within 15 seconds", output.getvalue())

    def test_monitoring_success_is_quiet_and_bounded(self):
        with patch.dict(os.environ, {"COMPOSE_FILE": "overlays/monitoring.yml"}), \
             patch("chronicle_ops.receipts.compose", side_effect=[subprocess.CompletedProcess([], 0, "operational-probe\n"), subprocess.CompletedProcess([], 0)]) as call, \
             patch("sys.stderr", new_callable=io.StringIO) as output:
            record_operation("restore", "success")
            self.assertEqual(output.getvalue(), "")
            self.assertEqual(call.call_args.kwargs, {"quiet": True, "timeout": 15})
            # exec into the running probe; a one-off run would reconcile the project's networks.
            self.assertEqual(call.call_args.args, ("exec", "-T", "operational-probe", "/monitoring/record-operation.sh",
                                                   "restore", "success", "none"))

    def test_verify_failure_and_signal_always_record_receipts(self):
        for result in (1, Interrupted(signal.SIGTERM)):
            with self.subTest(result=result), patch("chronicle_ops.__main__.signal.signal"), \
                 patch("chronicle_ops.common.acquire_operation_lock", return_value=None), \
                 patch.dict(os.environ, CHRONICLE_OPS_STATE="/state"), \
                 patch("chronicle_ops.verify.verify", side_effect=result if isinstance(result, BaseException) else None, return_value=result), \
                 patch("chronicle_ops.__main__.finish_operation") as finish:
                status = main(["verify"])
                self.assertEqual(status, 143 if isinstance(result, Interrupted) else 1)
                self.assertEqual(finish.call_args.args[:3], ("verify", status, "verification_failed"))
