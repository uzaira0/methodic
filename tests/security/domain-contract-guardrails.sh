#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODELS_DIR="${CHRONICLE_MODELS_DIR:-$ROOT_DIR/chronicle-models}"
IOS_DIR_EXPLICIT=0
if [[ -n "${CHRONICLE_IOS_DIR:-}" ]]; then
  IOS_DIR="$CHRONICLE_IOS_DIR"
  IOS_DIR_EXPLICIT=1
else
  IOS_DIR="$ROOT_DIR/chronicle-ios"
fi
CHECK_IOS_CONTRACTS="${CHRONICLE_CHECK_IOS_CONTRACTS:-$IOS_DIR_EXPLICIT}"
API_SPEC="${CHRONICLE_API_SPEC:-$ROOT_DIR/chronicle-api/chronicle.yaml}"
LINKML_CONTRACT="$ROOT_DIR/generated/domain-contracts/chronicle-domain-contracts.json"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

case "$CHECK_IOS_CONTRACTS" in
  0|1) ;;
  *) fail "CHRONICLE_CHECK_IOS_CONTRACTS must be 0 or 1" ;;
esac

pass() {
  echo "PASS: $*"
}

skip() {
  echo "SKIP: $*"
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "required file missing: $file"
}

require_file_contains() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  require_file "$file"
  if ! grep -Eq "$pattern" "$file"; then
    fail "$description"
  fi
  pass "$description"
}

echo "=== Chronicle domain contract guardrails ==="

require_file "$LINKML_CONTRACT"
require_file "$ROOT_DIR/scripts/generate-chronicle-contracts.py"
require_file "$MODELS_DIR/generated/domain-contracts/chronicle-domain-contracts.json"
require_file "$MODELS_DIR/fixtures/domain-contracts/domain-contract-fixture.json"
require_file "$MODELS_DIR/scripts/check-domain-contracts.sh"

"$ROOT_DIR/scripts/generate-chronicle-contracts.py" --check
pass "LinkML-generated Chronicle contract artifacts are fresh"

require_file "$ROOT_DIR/scripts/generate-chronicle-payload-contracts.py"
CHRONICLE_MODELS_DIR="$MODELS_DIR" CHRONICLE_API_SPEC="$API_SPEC" \
  "$ROOT_DIR/scripts/generate-chronicle-payload-contracts.py" \
    --models-dir "$MODELS_DIR" \
    --api-spec "$API_SPEC" \
    --check
pass "OpenAPI-derived web payload contracts and canonical fixtures are fresh"

# Prove that both environment and explicit source overrides feed the payload
# generator. Each probe changes only source bytes, so a correctly routed check
# reports the committed artifact as stale (exit 1); ignoring an override would
# incorrectly report it as fresh.
PAYLOAD_OVERRIDE_PROBE="$(mktemp -d)"
trap 'rm -rf "$PAYLOAD_OVERRIDE_PROBE"' EXIT
mkdir -p "$PAYLOAD_OVERRIDE_PROBE/models"
cp "$API_SPEC" "$PAYLOAD_OVERRIDE_PROBE/chronicle.yaml"
cp -R "$MODELS_DIR/fixtures" "$PAYLOAD_OVERRIDE_PROBE/models/fixtures"
printf '\n# payload-generator override probe\n' >> "$PAYLOAD_OVERRIDE_PROBE/chronicle.yaml"
printf '\n ' >> "$PAYLOAD_OVERRIDE_PROBE/models/fixtures/payloads/registry.json"

expect_payload_check_stale() {
  local description="$1"
  shift
  local status
  if "$@" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "$status" -eq 1 ]] || fail "$description (expected stale exit 1, got $status)"
}

expect_payload_check_stale \
  "payload generator must honor CHRONICLE_API_SPEC" \
  env CHRONICLE_API_SPEC="$PAYLOAD_OVERRIDE_PROBE/chronicle.yaml" CHRONICLE_MODELS_DIR="$MODELS_DIR" \
    "$ROOT_DIR/scripts/generate-chronicle-payload-contracts.py" --check
expect_payload_check_stale \
  "payload generator must honor CHRONICLE_MODELS_DIR" \
  env CHRONICLE_API_SPEC="$API_SPEC" CHRONICLE_MODELS_DIR="$PAYLOAD_OVERRIDE_PROBE/models" \
    "$ROOT_DIR/scripts/generate-chronicle-payload-contracts.py" --check
expect_payload_check_stale \
  "payload generator explicit source flags must override environment defaults" \
  env CHRONICLE_API_SPEC="$API_SPEC" CHRONICLE_MODELS_DIR="$MODELS_DIR" \
    "$ROOT_DIR/scripts/generate-chronicle-payload-contracts.py" \
      --api-spec "$PAYLOAD_OVERRIDE_PROBE/chronicle.yaml" \
      --models-dir "$PAYLOAD_OVERRIDE_PROBE/models" \
      --check
rm -rf "$PAYLOAD_OVERRIDE_PROBE"
trap - EXIT
pass "Payload generator honors environment and explicit source overrides"

(
  cd "$MODELS_DIR"
  scripts/check-domain-contracts.sh
)
pass "chronicle-models implementation contract and fixture projection are fresh"

# iOS is intentionally pinned with `submodule.<name>.update=none` in methodic. An
# incidental developer checkout must not silently broaden root CI. Run this section
# only when CHRONICLE_CHECK_IOS_CONTRACTS=1 or CHRONICLE_IOS_DIR is explicitly supplied;
# otherwise the chronicle-ios repository owns its generated-artifact gate.
IOS_AVAILABLE=0
if [[ "$CHECK_IOS_CONTRACTS" -eq 1 ]]; then
  require_file "$IOS_DIR/scripts/generate-ios-contracts.py"
  IOS_AVAILABLE=1
fi
require_file "$API_SPEC"
if [[ "$IOS_AVAILABLE" -eq 1 ]]; then
  (
    cd "$IOS_DIR"
    CHRONICLE_MODELS_DIR="$MODELS_DIR" CHRONICLE_API_SPEC="$API_SPEC" \
      python3 scripts/generate-ios-contracts.py --check
  )
  pass "chronicle-ios generated Swift contracts, routes, and fixtures are fresh"
else
  skip "chronicle-ios is update=none; its repository CI owns generated artifacts unless root checking is explicitly enabled"
fi

python3 - "$ROOT_DIR" "$MODELS_DIR" "$LINKML_CONTRACT" "$IOS_AVAILABLE" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
models_dir = Path(sys.argv[2])
linkml_contract_path = Path(sys.argv[3])
ios_available = sys.argv[4] == "1"
contract = json.loads(linkml_contract_path.read_text(encoding="utf-8"))
models_contract = json.loads(
    (models_dir / "generated/domain-contracts/chronicle-domain-contracts.json").read_text(encoding="utf-8")
)
contracts = contract["contracts"]


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def pass_msg(message: str) -> None:
    print(f"PASS: {message}")


mirror_keys = [
    "collectionModules",
    "activeCollectionModuleIds",
    "activeDefaultEnabledCollectionModuleIds",
    "inactiveCollectionModuleIds",
    "androidSensorModuleIds",
    "privacyClasses",
    "androidSensorTypes",
    "androidSensorMappings",
    "iosSensorTypes",
    "studyFeatures",
    "participantDataTypes",
    "participationStatuses",
    "studyLifecycleStatuses",
    "consentTriggers",
    "collectionDataDispositions",
]
for key in mirror_keys:
    if contracts[key] != models_contract["contracts"][key]:
        fail(f"chronicle-models implementation mirror drift for {key}")
pass_msg("chronicle-models implementation mirror matches LinkML-generated domain contract")


# Tranche 4: chronicle-web consumes the GENERATED contract module. The guardrail no
# longer parses hand-maintained literal unions (they must not exist); it asserts the
# new invariants: generated imports present, no re-declared canonical unions, defaults
# and sensor mappings joined (not hand-written), and web-owned presentation covering
# exactly the active generated module ids. Descriptor label/description coverage is
# additionally enforced by chronicle-web's own test suite (study-constants.test.ts).
web_dir = root / "chronicle-web"
web_constants_path = web_dir / "src/modern/lib/study-constants.ts"
if not web_constants_path.exists():
    # An uninitialized chronicle-web submodule must fail the gate, not skip it:
    # every web invariant below would otherwise pass vacuously.
    fail("chronicle-web checkout missing or empty — init the submodule before running the guardrails")
web = web_constants_path.read_text(encoding="utf-8")
ops = (web_dir / "src/modern/state/study-operations-api.ts").read_text(encoding="utf-8")
zod = (web_dir / "src/modern/state/zod-schemas.ts").read_text(encoding="utf-8")

generated_import = re.compile(r"from '(?:\.\./|@/)generated/chronicle-contracts'")
for name, text in (
    ("study-constants.ts", web),
    ("study-operations-api.ts", ops),
    ("zod-schemas.ts", zod),
):
    if not generated_import.search(text):
        fail(f"chronicle-web {name} must import from the generated chronicle-contracts module")
pass_msg("chronicle-web migrated files consume the generated chronicle-contracts module")

canonical_unions = [
    ("study-constants.ts", web, "CollectionModuleId"),
    ("study-constants.ts", web, "CollectionDataDisposition"),
    ("study-operations-api.ts", ops, "ParticipationStatus"),
    ("study-operations-api.ts", ops, "StudyLifecycleStatus"),
    ("study-operations-api.ts", ops, "ParticipantDataType"),
    ("study-operations-api.ts", ops, "CollectionConsentTrigger"),
]
for name, text, symbol in canonical_unions:
    match = re.search(rf"export\s+type\s+{re.escape(symbol)}\s*=\s*([^;]+);", text)
    # Catch single- AND double-quoted literal unions; a re-declaration must not
    # slip through on quote style.
    if match and ("'" in match.group(1) or '"' in match.group(1)):
        fail(f"chronicle-web {name} re-declares canonical union {symbol} as string literals")
    # The canonical symbol must still be present (re-exported from or aliased to
    # the generated module) — a silently deleted re-export is drift too.
    if not re.search(rf"\b{re.escape(symbol)}\b", text):
        fail(f"chronicle-web {name} no longer exposes canonical symbol {symbol}")
pass_msg("chronicle-web declares no hand-maintained canonical value-set unions")

if not re.search(r"z\.enum\(\s*PARTICIPATION_STATUSES\s*\)", zod):
    fail("chronicle-web ParticipationStatusSchema must be z.enum(PARTICIPATION_STATUSES) from the generated tuple")
pass_msg("chronicle-web zod ParticipationStatusSchema is built from the generated tuple")

# Require actual membership-check usage, not just the import line: the guard
# body must test against the generated array (or the zod schema built from it).
if not re.search(
    r"PARTICIPATION_STATUSES[\s\S]{0,80}?\.includes\(|ParticipationStatusSchema\.safeParse\(", ops
):
    fail("chronicle-web isParticipationStatus must test membership against the generated PARTICIPATION_STATUSES array")
pass_msg("chronicle-web participation-status guard is driven by the generated array")

if re.search(r"defaultEnabled\s*:\s*(?:true|false)\b", web):
    fail("chronicle-web study-constants.ts hand-writes defaultEnabled; join it from COLLECTION_MODULE_CONTRACTS")
if re.search(r"sensorType\s*:\s*'", web):
    fail("chronicle-web study-constants.ts hand-writes sensorType; join it from ANDROID_SENSOR_MAPPINGS")
pass_msg("chronicle-web module defaults and sensor mappings are joined from generated contract data")

presentation_match = re.search(
    r"const\s+COLLECTION_MODULE_PRESENTATION\s*=\s*\[(.*?)\]\s*as const",
    web,
    flags=re.S,
)
if not presentation_match:
    fail("Unable to find chronicle-web COLLECTION_MODULE_PRESENTATION")
presented = re.findall(r"value:\s*'([^']+)'", presentation_match.group(1))
active_id_set = set(contracts["activeCollectionModuleIds"])
if len(presented) != len(set(presented)) or set(presented) != active_id_set:
    fail(
        "chronicle-web COLLECTION_MODULE_PRESENTATION coverage drift: "
        f"missing={sorted(active_id_set - set(presented))}, "
        f"stale={sorted(set(presented) - active_id_set)}"
    )
pass_msg("chronicle-web module presentation covers exactly the active generated module ids")

if ios_available:
    ios_dir = root / "chronicle-ios"
    forbidden = re.compile(r"\b(CollectionModuleId|CollectionDataDisposition|ConsentTrigger|StudyFeature|StudyLifecycleStatus)\b")
    hits = []
    swift_files_scanned = 0
    for path in ios_dir.rglob("*.swift"):
        if ".build" in path.parts or "DerivedData" in path.parts:
            continue
        swift_files_scanned += 1
        text = path.read_text(encoding="utf-8", errors="ignore")
        if forbidden.search(text):
            hits.append(str(path.relative_to(root)))
    if swift_files_scanned == 0:
        fail("chronicle-ios checkout was supplied but contains no Swift sources")
    if hits:
        fail("iOS must not reintroduce local shared-domain enum definitions/usages before generated contracts: " + ", ".join(hits[:20]))
    pass_msg(f"iOS has no local shared-domain enum duplicates covered by the contract artifact ({swift_files_scanned} Swift files scanned)")
else:
    pass_msg("iOS duplicate scan delegated to chronicle-ios repository CI (update=none)")

android_settings = root / "chronicle/settings.gradle"
android_build = root / "chronicle/app/build.gradle"
server_settings = root / "chronicle-server/settings.gradle"
server_build = root / "chronicle-server/build.gradle"
for path in [android_settings, android_build, server_settings, server_build]:
    if not path.exists():
        fail(f"required downstream build file missing: {path.relative_to(root)}")
pass_msg("downstream Android/server build files are present")
PY

# Web descriptor label/description coverage lives in chronicle-web's own test suite.
# Run it when bun and the web dependencies are available; the textual invariants above
# already cover the structural checks when they are not.
WEB_DIR="$ROOT_DIR/chronicle-web"
if [[ -f "$WEB_DIR/src/modern/lib/study-constants.test.ts" ]]; then
  if command -v bun >/dev/null 2>&1 && [[ -d "$WEB_DIR/node_modules" ]]; then
    # Do not swallow the test output: on failure the diagnostics are the point.
    (cd "$WEB_DIR" && bun test src/modern/lib/study-constants.test.ts) ||
      fail "chronicle-web study-constants coverage test suite failed"
    pass "chronicle-web descriptor coverage test suite passes"
  else
    skip "bun/web dependencies unavailable here; descriptor coverage test runs in chronicle-web CI (build.yml bun test)"
  fi
fi

require_file_contains "$ROOT_DIR/chronicle/settings.gradle" \
  "includeBuild\\((chronicleModelsDir|'\\.\\./chronicle-models')\\)" \
  "Android build includes local chronicle-models composite source"
require_file_contains "$ROOT_DIR/chronicle/settings.gradle" \
  "CHRONICLE_MODELS_DIR|chronicleModelsDir" \
  "Android build documents configurable chronicle-models source path"
require_file_contains "$ROOT_DIR/chronicle/app/build.gradle" \
  "com\\.openlattice:chronicle-models:0\\.1\\.0-SNAPSHOT" \
  "Android app depends on chronicle-models artifact"
require_file_contains "$ROOT_DIR/chronicle-server/settings.gradle" \
  "include ':chronicle-models'" \
  "Server settings include chronicle-models project"
require_file_contains "$ROOT_DIR/chronicle-server/build.gradle" \
  "implementation\\(project\\(\":chronicle-models\"\\)\\)" \
  "Server depends on chronicle-models project"

pass "Domain contract guardrails passed"
