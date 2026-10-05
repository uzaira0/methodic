#!/usr/bin/env bash
# Local source/configuration and synthetic deployment regressions; no host access.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
python3 "$ROOT_DIR/tests/deployment/webselfhost_p2_regressions.py" --all
