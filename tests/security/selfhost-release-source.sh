#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
python3 - "$ROOT_DIR" <<'PY'
import importlib.util
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import patch
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('release_builder', root / 'scripts/build-selfhost-release.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
revision = 'a' * 40
for head, status, reason in [(revision, ' M selfhost/restore.sh\n', 'modified tracked'), ('b'*40, '', 'does not match HEAD')]:
    def result(args, **kwargs):
        return subprocess.CompletedProcess(args, 0, head + '\n' if 'rev-parse' in args else status, '')
    with patch.object(builder.subprocess, 'run', side_effect=result), patch.object(builder, 'parse_args', return_value=SimpleNamespace(source_revision=revision)), patch.object(builder, 'tracked_source_paths', side_effect=AssertionError('unsafe release source reached the packaging boundary')):
        try:
            builder.main()
        except SystemExit as error:
            assert reason in str(error), str(error)
        else:
            raise AssertionError('unsafe release source was accepted')
with patch.object(builder.subprocess, 'run', side_effect=[subprocess.CompletedProcess([], 0, revision+'\n', ''), subprocess.CompletedProcess([], 0, '', '')]):
    builder.require_committed_release_source(root, revision)
print('3 committed-source provenance cases passed (synthetic Git responses; no Git state mutation)')
PY
