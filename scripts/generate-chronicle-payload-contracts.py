#!/usr/bin/env python3
"""Generate web payload validators and canonical cross-language fixtures."""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_API_PATH = ROOT / "chronicle-api" / "chronicle.yaml"
DEFAULT_MODELS_DIR = ROOT / "chronicle-models"
OUTPUT_PATH = ROOT / "chronicle-web" / "src" / "modern" / "generated" / "chronicle-payload-contracts.generated.ts"
SENSOR_DATA_UPLOAD_PATH = "/chronicle/v3/study/{studyId}/participant/{participantId}/ios/{sourceDeviceId}"
COMPONENT_NAMES = (
    "IOSDevice",
    "SensorDataSample",
    "ScreenTimeUsageRecord",
    "ScreenTimeUsageEnvelope",
    "UserIdentificationRecord",
    "UserIdentificationEnvelope",
)


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def source_files(api_path: Path, models_dir: Path, registry: dict[str, Any]) -> list[tuple[str, Path]]:
    registry_path = models_dir / "fixtures" / "payloads" / "registry.json"
    paths = [
        ("chronicle-api/chronicle.yaml", api_path),
        ("chronicle-models/fixtures/payloads/registry.json", registry_path),
    ]
    seen_fixture_paths: set[str] = set()
    for family in registry["families"]:
        for fixture_path in family["fixtureFiles"]:
            if fixture_path in seen_fixture_paths:
                raise ValueError(f"Duplicate registry fixture path: {fixture_path}")
            seen_fixture_paths.add(fixture_path)
            path = models_dir / fixture_path
            if not path.is_file():
                raise ValueError(f"Registry fixture does not exist: {fixture_path}")
            paths.append((f"chronicle-models/{fixture_path}", path))
    return paths


def source_sha256(paths: list[tuple[str, Path]]) -> str:
    digest = hashlib.sha256()
    for logical_path, path in paths:
        digest.update(logical_path.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def ts_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def zod_expression(schema: dict[str, Any]) -> str:
    ref = schema.get("$ref")
    if ref:
        prefix = "#/components/schemas/"
        if not ref.startswith(prefix):
            raise ValueError(f"Unsupported OpenAPI reference: {ref}")
        return f"{ref.removeprefix(prefix)}Schema"

    schema_type = schema.get("type")
    if schema_type == "string":
        values = schema.get("enum")
        if values:
            expression = f"z.enum([{', '.join(ts_string(str(value)) for value in values)}])"
        else:
            expression = "z.string()"
            if schema.get("format") == "uuid":
                expression += ".uuid()"
            elif schema.get("format") == "date-time":
                expression += ".datetime({ offset: true })"
            if "minLength" in schema:
                expression += f".min({int(schema['minLength'])})"
            if "maxLength" in schema:
                expression += f".max({int(schema['maxLength'])})"
        return expression
    if schema_type in {"integer", "number"}:
        expression = "z.number().int()" if schema_type == "integer" else "z.number()"
        if "minimum" in schema:
            expression += f".min({schema['minimum']})"
        if "maximum" in schema:
            expression += f".max({schema['maximum']})"
        return expression
    if schema_type == "boolean":
        return "z.boolean()"
    if schema_type == "array":
        expression = f"z.array({zod_expression(schema['items'])})"
        if "minItems" in schema:
            expression += f".min({int(schema['minItems'])})"
        if "maxItems" in schema:
            expression += f".max({int(schema['maxItems'])})"
        return expression
    raise ValueError(f"Unsupported OpenAPI schema shape: {schema}")


def render_component(name: str, schema: dict[str, Any]) -> list[str]:
    if schema.get("type") != "object":
        raise ValueError(f"Expected object component for {name}")
    required = set(schema.get("required") or [])
    lines = [f"export const {name}Schema = z", "  .object({"]
    for property_name, property_schema in schema.get("properties", {}).items():
        expression = zod_expression(property_schema)
        if property_name not in required:
            expression += ".optional()"
        lines.append(f"    {ts_string(property_name)}: {expression},")
    unknown_key_policy = "strict" if schema.get("additionalProperties") is False else "passthrough"
    lines.extend(
        [
            "  })",
            f"  .{unknown_key_policy}();",
            f"export type {name} = z.infer<typeof {name}Schema>;",
            "",
        ]
    )
    return lines


def sensor_data_batch_schema(api: dict[str, Any]) -> dict[str, Any]:
    try:
        schema = api["paths"][SENSOR_DATA_UPLOAD_PATH]["post"]["requestBody"]["content"]["application/json"][
            "schema"
        ]
    except KeyError as error:
        raise ValueError(f"OpenAPI sensor-data upload schema is missing {error}") from error
    if schema.get("type") != "array":
        raise ValueError("OpenAPI sensor-data upload request must remain an array")
    return schema


def render_output(
    api: dict[str, Any],
    registry: dict[str, Any],
    paths: list[tuple[str, Path]],
    models_dir: Path,
) -> str:
    components = api["components"]["schemas"]
    missing = [name for name in COMPONENT_NAMES if name not in components]
    if missing:
        raise ValueError(f"OpenAPI components missing: {', '.join(missing)}")

    lines = ["", "import { z } from 'zod';", ""]
    for name in COMPONENT_NAMES:
        lines.extend(render_component(name, components[name]))
    lines.extend(
        [
            f"export const SensorDataSampleBatchSchema = {zod_expression(sensor_data_batch_schema(api))};",
            "export type SensorDataSampleBatch = z.infer<typeof SensorDataSampleBatchSchema>;",
            "",
        ]
    )

    lines.extend(
        [
            f"export const PAYLOAD_FIXTURE_REGISTRY = {json.dumps(registry, indent=2, ensure_ascii=True)} as const;",
            "",
            "export const PAYLOAD_FIXTURES = {",
        ]
    )
    for family in registry["families"]:
        for fixture_path in family["fixtureFiles"]:
            payload = load_json(models_dir / fixture_path)
            rendered = json.dumps(payload, indent=2, ensure_ascii=True)
            lines.append(f"  {ts_string(fixture_path)}: {rendered},")
    lines.extend(["} as const;", ""])

    body = "\n".join(lines)
    content_hash = hashlib.sha256(body.encode("utf-8")).hexdigest()
    header = [
        "// Generated by scripts/generate-chronicle-payload-contracts.py from chronicle-api and chronicle-models fixtures.",
        f"// Source-SHA256: {source_sha256(paths)}",
        f"// Content-SHA256: {content_hash}",
        "// Do not edit by hand.",
    ]
    return "\n".join(header) + "\n" + body


def expected_output(api_path: Path, models_dir: Path) -> str:
    registry = load_json(models_dir / "fixtures" / "payloads" / "registry.json")
    paths = source_files(api_path, models_dir, registry)
    api = yaml.safe_load(api_path.read_text(encoding="utf-8"))
    return render_output(api, registry, paths, models_dir)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if the generated web artifact is stale")
    parser.add_argument(
        "--api-spec",
        type=Path,
        default=Path(os.environ.get("CHRONICLE_API_SPEC", DEFAULT_API_PATH)),
        help="OpenAPI source (default: CHRONICLE_API_SPEC or chronicle-api/chronicle.yaml)",
    )
    parser.add_argument(
        "--models-dir",
        type=Path,
        default=Path(os.environ.get("CHRONICLE_MODELS_DIR", DEFAULT_MODELS_DIR)),
        help="chronicle-models checkout (default: CHRONICLE_MODELS_DIR or chronicle-models)",
    )
    args = parser.parse_args()
    api_path = args.api_spec.expanduser().resolve()
    models_dir = args.models_dir.expanduser().resolve()
    if not api_path.is_file():
        parser.error(f"OpenAPI source does not exist: {api_path}")
    if not models_dir.is_dir():
        parser.error(f"chronicle-models checkout does not exist: {models_dir}")
    expected = expected_output(api_path, models_dir)
    if args.check:
        actual = OUTPUT_PATH.read_text(encoding="utf-8") if OUTPUT_PATH.exists() else ""
        if actual == expected:
            print(f"OK: {OUTPUT_PATH.relative_to(ROOT)} is fresh")
            return 0
        print(f"{OUTPUT_PATH.relative_to(ROOT)} is stale", file=sys.stderr)
        for line in difflib.unified_diff(
            actual.splitlines(),
            expected.splitlines(),
            fromfile=str(OUTPUT_PATH.relative_to(ROOT)),
            tofile=f"{OUTPUT_PATH.relative_to(ROOT)} (expected)",
            lineterm="",
        ):
            print(line, file=sys.stderr)
        return 1

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(expected, encoding="utf-8")
    print(f"wrote {OUTPUT_PATH.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
