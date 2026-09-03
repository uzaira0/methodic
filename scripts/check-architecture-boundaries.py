#!/usr/bin/env python3
"""Fail-closed Chronicle source ownership and dependency-boundary checker."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import sys
import tempfile
from typing import Any

SOURCE_SUFFIXES = {".java", ".kt", ".kts", ".swift", ".ts", ".tsx", ".js", ".jsx"}


def load_manifest(path: pathlib.Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest.get("version") != 1:
        raise ValueError("architecture manifest version must be 1")
    return manifest


def matching_owners(relative_path: str, manifest: dict[str, Any]) -> list[str]:
    matches: list[str] = []
    for rule in manifest["owners"]:
        included = any(relative_path.startswith(prefix) for prefix in rule["prefixes"])
        excluded = any(
            relative_path.startswith(prefix) for prefix in rule.get("exclude_prefixes", [])
        )
        if included and not excluded:
            matches.append(rule["name"])
    return matches


def active_exception(
    relative_path: str,
    token: str,
    manifest: dict[str, Any],
    today: dt.date,
) -> bool:
    for exception in manifest.get("exceptions", []):
        if exception["path"] != relative_path or exception["token"] != token:
            continue
        required = ("owner", "reason", "expires")
        if any(not exception.get(field) for field in required):
            raise ValueError(f"incomplete boundary exception for {relative_path}: {token}")
        expiry = dt.date.fromisoformat(exception["expires"])
        if expiry < today:
            raise ValueError(f"expired boundary exception for {relative_path}: {token}")
        return True
    return False


def check(
    root: pathlib.Path,
    manifest: dict[str, Any],
    today: dt.date,
    *,
    include_optional: bool = False,
) -> list[str]:
    errors: list[str] = []
    forbidden_by_owner = {
        item["owner"]: item["tokens"] for item in manifest["forbidden_dependencies"]
    }
    required_roots = set(manifest["source_roots"])
    optional_roots = set(manifest.get("optional_source_roots", []))
    discovered_roots = required_roots | (optional_roots if include_optional else set())
    android_root = root / "chronicle"
    if android_root.is_dir():
        discovered_roots.update(
            str(path.relative_to(root) / "src" / "main")
            for path in android_root.glob("collection-*")
            if (path / "src" / "main").is_dir()
        )

    files: list[pathlib.Path] = []
    for source_root in sorted(discovered_roots):
        absolute_root = root / source_root
        if not absolute_root.is_dir():
            if source_root in required_roots or source_root in optional_roots:
                kind = "production" if source_root in required_roots else "opted-in optional"
                errors.append(f"declared {kind} source root is missing: {source_root}")
            continue
        files.extend(
            path for path in absolute_root.rglob("*") if path.is_file() and path.suffix in SOURCE_SUFFIXES
        )

    for path in sorted(set(files)):
        relative_path = path.relative_to(root).as_posix()
        owners = matching_owners(relative_path, manifest)
        if len(owners) != 1:
            errors.append(
                f"{relative_path}: expected exactly one architecture owner, found {owners or 'none'}"
            )
            continue
        owner = owners[0]
        source = path.read_text(encoding="utf-8", errors="replace")
        for token in forbidden_by_owner.get(owner, []):
            if token not in source:
                continue
            try:
                exempt = active_exception(relative_path, token, manifest, today)
            except ValueError as error:
                errors.append(str(error))
                continue
            if not exempt:
                errors.append(f"{relative_path}: {owner} may not depend on {token}")

    known_exception_paths = {item["path"] for item in manifest.get("exceptions", [])}
    for exception_path in sorted(known_exception_paths):
        if not (root / exception_path).is_file():
            errors.append(f"boundary exception references missing file: {exception_path}")
    return errors


def self_test() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        source_root = root / "models" / "src" / "main"
        source_root.mkdir(parents=True)
        source = source_root / "Example.kt"
        source.write_text("import forbidden.framework.Type\n", encoding="utf-8")
        manifest = {
            "version": 1,
            "source_roots": ["models/src/main"],
            "optional_source_roots": ["ios/src/main"],
            "owners": [{"name": "models", "prefixes": ["models/src/main/"]}],
            "forbidden_dependencies": [
                {"owner": "models", "tokens": ["forbidden.framework."]}
            ],
            "exceptions": [],
        }
        errors = check(root, manifest, dt.date(2026, 7, 13))
        if len(errors) != 1 or "may not depend" not in errors[0]:
            raise AssertionError(f"negative boundary fixture did not fire: {errors}")
        source.write_text("data class Example(val id: String)\n", encoding="utf-8")
        errors = check(root, manifest, dt.date(2026, 7, 13))
        if errors:
            raise AssertionError(f"positive boundary fixture failed: {errors}")

        optional_root = root / "ios" / "src" / "main"
        optional_root.mkdir(parents=True)
        (optional_root / "Example.swift").write_text("struct Example {}\n", encoding="utf-8")
        errors = check(root, manifest, dt.date(2026, 7, 13))
        if errors:
            raise AssertionError(f"present optional root was not skipped by default: {errors}")
        manifest["owners"].append({"name": "ios", "prefixes": ["ios/src/main/"]})
        errors = check(root, manifest, dt.date(2026, 7, 13), include_optional=True)
        if errors:
            raise AssertionError(f"present optional source root was not checked: {errors}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path)
    parser.add_argument("--manifest", type=pathlib.Path)
    parser.add_argument(
        "--include-optional",
        action="store_true",
        help="check optional source roots supplied by an explicit platform checkout",
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("[ok] architecture boundary fixtures passed")
        return 0

    script_root = pathlib.Path(__file__).resolve().parents[1]
    root = (args.root or script_root).resolve()
    manifest_path = args.manifest or root / "config" / "architecture-boundaries.json"
    optional_environment = os.environ.get("CHRONICLE_INCLUDE_OPTIONAL_SOURCE_ROOTS")
    if optional_environment not in (None, "0", "1"):
        parser.error("CHRONICLE_INCLUDE_OPTIONAL_SOURCE_ROOTS must be 0 or 1")
    include_optional = args.include_optional or optional_environment == "1"
    try:
        manifest = load_manifest(manifest_path)
        errors = check(
            root,
            manifest,
            dt.date.today(),
            include_optional=include_optional,
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"[fail] architecture boundary checker error: {error}", file=sys.stderr)
        return 2
    if errors:
        for error in errors:
            print(f"[fail] {error}", file=sys.stderr)
        print(f"[fail] architecture boundary check found {len(errors)} violation(s)", file=sys.stderr)
        return 1
    optional_note = "included" if include_optional else "skipped"
    print(
        "[ok] architecture ownership and dependency boundaries passed "
        f"(optional source roots {optional_note})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
