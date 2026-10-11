#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${ROOT_DIR}/selfhost:${ROOT_DIR}/tests/selfhost-py" \
  python3 -m unittest \
  test_runtime.RuntimeTests.test_monitoring_timeout_and_nonzero_warn_but_do_not_fail_operation \
  test_runtime.RuntimeTests.test_monitoring_success_is_quiet_and_bounded
echo 'self-host monitoring timeout test passed'
