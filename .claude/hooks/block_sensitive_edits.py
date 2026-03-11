#!/usr/bin/env python3
import json
import sys
from pathlib import Path


PROTECTED_PATTERNS = (
    ".env",
    "docker/.env",
    "signing.properties",
    "keystore",
    ".pem",
    ".key",
    "google-services.json",
)


def main() -> int:
    payload = json.load(sys.stdin)
    tool_input = payload.get("tool_input", {})
    file_path = tool_input.get("file_path") or ""
    path = Path(file_path)
    target = path.as_posix()

    if any(pattern in target for pattern in PROTECTED_PATTERNS):
        print(
            f"Blocked edit to sensitive file: {target}. "
            "Handle secrets and environment files explicitly and outside automatic edits."
        )
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
