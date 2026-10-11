#!/usr/bin/env bash
# Confirm the single-owner rules reject copies and accept owner/helper usage.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$ROOT_DIR" <<'PY'
from collections import Counter
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
fixtures = root / "tests/security/fixtures/single-owner"
for rule in sorted((root / "tests/security/ast-grep").glob("*-single-owner.yml")):
    expected = Counter()
    for fixture in fixtures.rglob("*"):
        if fixture.suffix not in (".kt", ".java"):
            continue
        for line, text in enumerate(fixture.read_text().splitlines(), 1):
            marker = text.strip().removeprefix("// ruleid: ")
            if text.strip().startswith("// ruleid: ") and marker.startswith(rule.stem):
                expected[(marker, str(fixture), line + 1)] += 1
    result = subprocess.run(
        ["ast-grep", "scan", "--rule", str(rule), str(fixtures), "--json=compact"],
        capture_output=True, text=True,
    )
    if result.returncode not in (0, 1):
        sys.exit(result.stderr)
    actual = Counter((match["ruleId"], match["file"], match["range"]["start"]["line"] + 1)
                     for match in json.loads(result.stdout))
    if not expected or actual != expected:
        sys.exit(f"FAIL {rule.stem}: expected {expected}, got {actual}")
    print(f"PASS {rule.stem}: {sum(actual.values())} deliberate violations; allowed fixtures clean")
PY
