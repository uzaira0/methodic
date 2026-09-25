#!/usr/bin/env python3
"""Diff Chronicle's shared value sets across every consumer.

Surfaces compared:
  0. OpenAPI -> chronicle-api/chronicle.yaml component enums
  1. LinkML  -> generated/domain-contracts/chronicle-domain-contracts.json (root)
  2. Kotlin  -> chronicle-models/generated/domain-contracts/chronicle-domain-contracts.json
  3. Web     -> chronicle-web/src/modern/generated/chronicle-contracts.ts (tuples)
  4. Android -> no local redefinition of the canonical enums; every module id
                referenced as a CollectionModuleId constant, not a raw literal
  5. The tests/security/ast-grep raw-module-id rule must cover every module id

Exit 1 on any drift. Called from tests/security/domain-contract-guardrails.sh.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]

LINKML = ROOT / "generated/domain-contracts/chronicle-domain-contracts.json"
MODELS = ROOT / "chronicle-models/generated/domain-contracts/chronicle-domain-contracts.json"
WEB_TS = ROOT / "chronicle-web/src/modern/generated/chronicle-contracts.ts"
ASTG_RULE = ROOT / "tests/security/ast-grep/collection-module-id-no-raw-string.yml"
ANDROID = ROOT / "chronicle"

# canonical json key -> web tuple export name
TUPLES = {
    "activeCollectionModuleIds": None,  # derived below, compared against COLLECTION_MODULE_IDS
    "studyFeatures": "STUDY_FEATURES",
    "participantDataTypes": "PARTICIPANT_DATA_TYPES",
    "participationStatuses": "PARTICIPATION_STATUSES",
    "studyLifecycleStatuses": "STUDY_LIFECYCLE_STATUSES",
    "consentTriggers": "CONSENT_TRIGGERS",
    "androidSensorTypes": "ANDROID_SENSOR_TYPES",
    "iosSensorTypes": "IOS_SENSOR_TYPES",
}

failures: list[str] = []


def ts_tuple(text: str, name: str) -> list[str]:
    m = re.search(rf"export const {name} = \[(.*?)\] as const;", text, re.S)
    if not m:
        failures.append(f"chronicle-web generated contracts export no {name}")
        return []
    return re.findall(r"'([^']+)'", m.group(1))


def main() -> int:
    linkml = json.loads(LINKML.read_text())["contracts"]
    models = json.loads(MODELS.read_text())["contracts"]
    web = WEB_TS.read_text()

    # 1 vs 2 -- LinkML schema against the Kotlin-parsed mirror.
    for key in sorted(set(linkml) & set(models)):
        if linkml[key] != models[key]:
            failures.append(f"LinkML vs chronicle-models drift for '{key}'")

    # 1 vs 3 -- canonical sets against the web's generated tuples.
    module_ids = [m["id"] for m in linkml["collectionModules"]]
    if ts_tuple(web, "COLLECTION_MODULE_IDS") != module_ids:
        failures.append("web COLLECTION_MODULE_IDS != contract collectionModules")
    dispositions = [d["id"] for d in linkml["collectionDataDispositions"]]
    if ts_tuple(web, "COLLECTION_DATA_DISPOSITIONS") != dispositions:
        failures.append("web COLLECTION_DATA_DISPOSITIONS != contract collectionDataDispositions")
    for key, export in TUPLES.items():
        if export and ts_tuple(web, export) != linkml[key]:
            failures.append(f"web {export} != contract {key}")

    # 1 vs OpenAPI -- the published spec (source of chronicle-api.generated.ts and the
    #      payload contracts) must carry the same enum members.
    import yaml
    spec = yaml.safe_load((ROOT / "chronicle-api/chronicle.yaml").read_text())["components"]["schemas"]
    for schema, canon in (
        ("CollectionModuleId", module_ids),
        ("CollectionDataDisposition", dispositions),
        ("CollectionConsentTrigger", linkml["consentTriggers"]),
        ("ParticipationStatus", linkml["participationStatuses"]),
    ):
        got = spec.get(schema, {}).get("enum")
        if got is None:
            failures.append(f"OpenAPI has no enum schema {schema}")
        elif set(got) != set(canon):
            failures.append(
                f"OpenAPI {schema} drift: missing {sorted(set(canon) - set(got))}, extra {sorted(set(got) - set(canon))}"
            )

    # OpenAPI AndroidSensorSetting must carry the Kotlin model's fields (named units, so
    # no bare samplingRate) and the canonical sensor-type enum.
    kt = (ROOT / "chronicle-models/src/main/kotlin/com/openlattice/chronicle/android/AndroidSensorSetting.kt").read_text()
    kt_fields = set(re.findall(r"(?m)^\s+val (\w+):", kt))  # constructor params, not the companion
    sensor_setting = spec.get("AndroidSensorSetting", {})
    spec_fields = set(sensor_setting.get("properties", {})) - {"@class"}
    if spec_fields != kt_fields:
        failures.append(
            f"OpenAPI AndroidSensorSetting drift: missing {sorted(kt_fields - spec_fields)}, extra {sorted(spec_fields - kt_fields)}"
        )
    sensor_enum = spec.get("AndroidSensorType", {}).get("enum")
    if sensor_enum != linkml["androidSensorTypes"]:
        failures.append("OpenAPI AndroidSensorType enum != contract androidSensorTypes")
    items = sensor_setting.get("properties", {}).get("sensors", {}).get("items", {})
    if items.get("$ref") != "#/components/schemas/AndroidSensorType":
        failures.append("OpenAPI AndroidSensorSetting.sensors items must $ref AndroidSensorType")

    # 4 -- Android must not redefine a canonical enum.
    canonical = ("CollectionModuleId", "CollectionDataDisposition", "StudyFeature",
                 "CollectionPrivacyClass", "ConsentTrigger", "StudyLifecycleStatus")
    for kt in ANDROID.rglob("*.kt"):
        if "/build/" in str(kt):
            continue
        text = kt.read_text(errors="ignore")
        for sym in canonical:
            if re.search(rf"\benum class {sym}\b", text):
                failures.append(f"Android redefines canonical enum {sym}: {kt.relative_to(ROOT)}")

    # 5 -- the raw-literal guardrail must name every module id, and no production
    #      Android collection source may carry a module id as a bare string.
    rule = ASTG_RULE.read_text()
    covered = set(re.findall(r"pattern: '\"([a-z_]+)\"'", rule))
    uncovered = sorted(set(module_ids) - covered)
    if uncovered:
        failures.append(f"ast-grep raw-module-id rule does not cover: {', '.join(uncovered)}")
    literal = re.compile('"(' + "|".join(re.escape(i) for i in module_ids) + ')"')
    for kt in ANDROID.rglob("*.kt"):
        parts = str(kt)
        if "/build/" in parts or "/test/" in parts or "/androidTest" in parts:
            continue
        if "/collection/" not in parts:
            continue
        for n, line in enumerate(kt.read_text(errors="ignore").splitlines(), 1):
            stripped = line.lstrip()
            if stripped.startswith(("//", "*", "/*")):
                continue
            code = line.split("//", 1)[0]
            # log labels and WorkManager unique names are not wire ids
            if re.search(r"\blabel\s*=|WORK_NAME\s*=", code):
                continue
            m = literal.search(code)
            if m:
                failures.append(
                    f"raw module-id literal {m.group(0)} at {kt.relative_to(ROOT)}:{n}"
                    " -- use CollectionModuleId.<CONST>.id"
                )

    for f in failures:
        print(f"FAIL: {f}")
    if failures:
        print(f"\n{len(failures)} contract-drift failure(s)")
        return 1
    print("PASS: all Chronicle value sets agree across LinkML, chronicle-models, web, Android")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
