#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# Execute the actual Python handoff with injected Compose, then check the receipt contract.
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${ROOT_DIR}/selfhost:${ROOT_DIR}/tests/selfhost-py" \
  python3 -m unittest test_upgrade.UpgradeTests test_receipts.ReceiptTests \
  test_runtime.RuntimeTests.test_monitoring_success_is_quiet_and_bounded
echo 'PASS: failed and successful upgrades each write one matching receipt and metric'
