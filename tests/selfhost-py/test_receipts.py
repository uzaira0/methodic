import io
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "selfhost"))
from chronicle_ops.receipts import finish_operation, write_operation_receipt


class ReceiptTests(unittest.TestCase):
    def test_receipt_contract_private_atomic_and_durable(self):
        stream = io.StringIO()
        stream.name = "/state/operator-receipts/operations/.pending"
        stream.fileno = lambda: 17
        temporary = MagicMock()
        temporary.__enter__.return_value = stream
        with patch.dict(os.environ, {"CHRONICLE_OPS_STATE": "/state", "CHRONICLE_OPS_VERSION": "1.2.3"}), \
             patch.object(Path, "is_symlink", return_value=False), patch.object(Path, "mkdir") as mkdir, \
             patch.object(Path, "chmod", autospec=True) as protect, patch.object(Path, "unlink"), \
             patch("chronicle_ops.receipts.tempfile.NamedTemporaryFile", return_value=temporary) as create, \
             patch("chronicle_ops.receipts.os.chmod") as chmod, patch("chronicle_ops.receipts.os.fsync") as sync, \
             patch("chronicle_ops.receipts.os.replace") as publish, patch("chronicle_ops.receipts.os.open", return_value=18), \
             patch("chronicle_ops.receipts.os.close"):
            write_operation_receipt("restore", "failure", "restore_failed", 17)
            data = json.loads(stream.getvalue())
            self.assertEqual({key: data[key] for key in ("operation", "outcome", "failureCategory", "durationSeconds", "releaseVersion")},
                             {"operation": "restore", "outcome": "failure", "failureCategory": "restore_failed", "durationSeconds": 17, "releaseVersion": "1.2.3"})
            self.assertTrue(data["timestamp"].endswith("Z"))
            self.assertEqual(create.call_args.kwargs["dir"], Path("/state/operator-receipts/operations"))
            chmod.assert_called_once_with(Path(stream.name), 0o600)
            self.assertEqual([call.args[-1] for call in protect.call_args_list], [0o700, 0o700])
            self.assertEqual([call.args[0] for call in sync.call_args_list], [17, 18])
            self.assertEqual(publish.call_args.args[0], Path(stream.name))

    def test_invalid_contract_or_symlink_never_creates_a_receipt(self):
        with patch.dict(os.environ, {"CHRONICLE_OPS_STATE": "/state"}), \
             patch("chronicle_ops.receipts.tempfile.NamedTemporaryFile") as create:
            for args in (("../bad", "failure"), ("restore", "maybe"), ("restore", "failure", "../bad")):
                with self.subTest(args=args), self.assertRaises(ValueError):
                    write_operation_receipt(*args)
            with patch.object(Path, "is_symlink", return_value=True), self.assertRaises(ValueError):
                write_operation_receipt("restore", "success")
            create.assert_not_called()


    def test_finish_records_one_matching_receipt_and_monitoring_outcome(self):
        for status, outcome, category in ((0, "success", "none"), (41, "failure", "upgrade_failed")):
            with self.subTest(status=status), patch("chronicle_ops.receipts.time.monotonic", return_value=117), \
                 patch("chronicle_ops.receipts.write_operation_receipt") as write, \
                 patch("chronicle_ops.receipts.record_operation") as record:
                finish_operation("upgrade", status, "upgrade_failed", 100)
                write.assert_called_once_with("upgrade", outcome, category, 17)
                record.assert_called_once_with("upgrade", outcome, category)
