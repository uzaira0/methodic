#!/usr/bin/env python3
"""Verify every active `bun run` invocation resolves to package.json."""

from __future__ import annotations

import json
import pathlib
import re
import sys


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    package_json = json.loads((root / "chronicle-web" / "package.json").read_text(encoding="utf-8"))
    known = set(package_json.get("scripts", {}))
    scan_roots = (root / ".github", root / "scripts", root / "chronicle-web" / "scripts")
    allowed_suffixes = {".yml", ".yaml", ".sh", ".ts"}
    errors: list[str] = []
    for scan_root in scan_roots:
        for path in sorted(scan_root.rglob("*")):
            if not path.is_file() or path.suffix not in allowed_suffixes:
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            for script in re.findall(r"\bbun\s+run\s+([A-Za-z0-9:_-]+)", text):
                if script not in known:
                    errors.append(f"{path.relative_to(root)} references missing bun script {script}")
    if errors:
        for error in errors:
            print(f"[fail] {error}", file=sys.stderr)
        return 1
    print("[ok] every active bun run reference resolves to package.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
