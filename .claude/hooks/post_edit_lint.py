#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path


def main() -> int:
    payload = json.load(sys.stdin)
    tool_input = payload.get("tool_input", {})
    file_path = tool_input.get("file_path") or ""
    if not file_path:
        return 0

    project_dir = Path(os.environ.get("CLAUDE_PROJECT_DIR", ".")).resolve()
    path = Path(file_path).resolve()

    try:
        relative = path.relative_to(project_dir)
    except ValueError:
        return 0

    rel = relative.as_posix()
    if not rel.startswith("chronicle-web/src/") or not rel.endswith(".js"):
        return 0

    subprocess.run(
        ["npx", "eslint", "--config", ".eslintrc", "--fix", rel[len("chronicle-web/"):]],
        cwd=project_dir / "chronicle-web",
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
