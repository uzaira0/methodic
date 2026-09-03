#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/build-android-apk.yml"
HANDOFF="$ROOT_DIR/docs/handoff/play-selfhost-release-handoff-2026-08-20.md"
BASELINE="$ROOT_DIR/docs/handoff/play-release-phase0-baseline-receipt.tsv"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_literal() {
  local literal="$1"
  grep -Fq -- "$literal" "$WORKFLOW" || fail "Android release workflow omits: $literal"
}

require_count() {
  local expected="$1" literal="$2" actual
  actual="$(grep -Fc -- "$literal" "$WORKFLOW" || true)"
  [[ "$actual" -eq "$expected" ]] ||
    fail "expected $expected occurrence(s) of '$literal', found $actual"
}

require_handoff_literal() {
  local literal="$1"
  if ! python3 - "$HANDOFF" "$literal" <<'PY'
from pathlib import Path
import sys

document = " ".join(Path(sys.argv[1]).read_text(encoding="utf-8").split())
required = " ".join(sys.argv[2].split())
raise SystemExit(0 if required in document else 1)
PY
  then
    fail "corrective-release contract omits: $literal"
  fi
}

require_literal 'release_candidate_id:'
require_literal 'attestations: write'
require_literal 'id-token: write'
require_literal 'uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
require_literal 'name: chronicle-play-sealed-subjects'
require_literal 'PLAY_UPLOAD_CERT_SHA256: ${{ vars.PLAY_UPLOAD_CERT_SHA256 }}'
require_literal '--expected-rc-id "$RELEASE_CANDIDATE_ID"'
require_literal '--expected-cert-sha256 "$normalized_upload_cert"'
require_literal '--release-authority-sha "$GITHUB_SHA"'
require_literal 'app/build/play-aab-evidence/github-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}'
require_literal 'subject-path: attestation-subjects/outputs/bundle/playRelease/app-play-release.aab'
require_literal 'subject-path: attestation-subjects/play-aab-evidence/github-${{ github.run_id }}-${{ github.run_attempt }}/play-aab-verification-receipt.json'
require_literal 'chronicle/app/build/outputs/mapping/playRelease/mapping.txt'
require_literal 'chronicle/app/build/play-aab-evidence/github-${{ github.run_id }}-${{ github.run_attempt }}/**'
require_count 2 'uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8'
require_handoff_literal 'exact released root and child SHAs'
require_handoff_literal 'versionCode` must be greater than the released and current Play Console maximum'
require_handoff_literal 'identify the superseded release by its root/child SHAs, sealed-receipt'
require_handoff_literal 'never mutate, overwrite, or relabel the prior receipt or artifact'
require_handoff_literal 'repeat Internal Testing delivery identity'
require_handoff_literal 'declaration/listing/asset comparison'
require_handoff_literal 'every migration/rollback/restore test affected by the fix'
require_handoff_literal 'requires a new promotion record and new scoped owner authorization'
require_handoff_literal 'play-release-phase0-baseline-receipt.tsv'

if grep -Eq -- 'verify-play-aab\.sh.*(--allow-unpinned-cert|--allow-unsealed-rc|--skip-build)' "$WORKFLOW"; then
  fail 'sealed workflow enables a diagnostic verifier bypass'
fi
if grep -Fq 'play:release) tasks=(":app:bundlePlayRelease")' "$WORKFLOW"; then
  fail 'workflow rebuilds Play release outside the sealed verifier'
fi
if grep -Fq 'PLAY_UPLOAD_CERT_SHA256: ${{ secrets.' "$WORKFLOW"; then
  fail 'public upload-certificate identity is hidden in an unreviewable secret instead of a repository variable'
fi

python3 - "$WORKFLOW" <<'PY'
from pathlib import Path
import sys
import yaml

workflow = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
if workflow.get("permissions") != {"contents": "read"}:
    raise SystemExit("FAIL: build workflow has unnecessary write permissions")
attestation_job = workflow.get("jobs", {}).get("attest-play-release", {})
permissions = attestation_job.get("permissions")
if permissions != {
    "contents": "read",
    "attestations": "write",
    "id-token": "write",
}:
    raise SystemExit("FAIL: Play attestation job permissions are not the exact minimum")
PY

python3 - "$BASELINE" '179d1fb5ade421fca7b8a67b2bf9c5320ad83999700f17663934f719757c8db0' <<'PY'
import csv
import hashlib
from pathlib import Path
import re
import sys

receipt = Path(sys.argv[1])
if not receipt.is_file():
    raise SystemExit("FAIL: phase-zero baseline receipt is missing")
if hashlib.sha256(receipt.read_bytes()).hexdigest() != sys.argv[2]:
    raise SystemExit("FAIL: phase-zero baseline receipt differs from its reviewed source digest")
with receipt.open(encoding="utf-8", newline="") as stream:
    reader = csv.DictReader(stream, delimiter="\t")
    expected_header = [
        "record_type",
        "repository",
        "authority_or_workflow",
        "sha",
        "run_id",
        "attempt",
        "event",
        "check_name",
        "conclusion",
        "artifact_ids",
        "terminal_disposition",
        "url",
    ]
    if reader.fieldnames != expected_header:
        raise SystemExit("FAIL: phase-zero baseline receipt has an unexpected schema")
    rows = list(reader)

if any(None in row or set(row) != set(expected_header) for row in rows):
    raise SystemExit("FAIL: phase-zero baseline receipt contains malformed or surplus columns")
allowed_record_types = {"authority", "ci", "deferred-pr"}
if {row["record_type"] for row in rows} - allowed_record_types:
    raise SystemExit("FAIL: phase-zero baseline receipt contains an unclassified record type")
if len(rows) != 29:
    raise SystemExit("FAIL: phase-zero baseline receipt must contain exactly 29 reviewed records")

expected_authorities = {
    "methodic": ("origin/develop", "3f1dc5424cee4be49823892bfcf74a30d2e906b9", "merged-and-reachable"),
    "chronicle": ("origin/develop", "6b0324836185df93928718d2fbbf6a7368db18a7", "merged-and-reachable"),
    "chronicle-api": ("origin/develop", "0b1709ddaf5901c119af05c73d3d8221509ecef4", "merged-and-reachable"),
    "chronicle-ios": ("origin/develop (optional)", "af39244d34675500363ea909a63c52a3140784fc", "optional-not-initialized-by-default"),
    "chronicle-models": ("origin/main", "3cc7d8ef93e84765a503f5500a83536f85512010", "merged-and-reachable"),
    "chronicle-server": ("origin/develop", "935f4434382c8d1521ee72ef317468875a9efd8f", "merged-and-reachable"),
    "chronicle-web": ("origin/develop", "e104691d067708b8aff66474cef4cb39940e05e8", "merged-and-reachable"),
    "rhizome": ("origin/develop", "6071adba852a8cd5b7c79837ccb26bdc5804fa54", "merged-and-reachable"),
    "rhizome-client": ("origin/develop", "2b74422d6698cd029def3f77683a6745b45dafe5", "merged-and-reachable"),
}
authorities = [row for row in rows if row["record_type"] == "authority"]
if {row["repository"] for row in authorities} != set(expected_authorities):
    raise SystemExit("FAIL: phase-zero receipt does not cover the exact root/child authority set")
if len(authorities) != len(expected_authorities):
    raise SystemExit("FAIL: phase-zero receipt contains duplicate authority rows")
for row in authorities:
    actual = (row["authority_or_workflow"], row["sha"], row["terminal_disposition"])
    if actual != expected_authorities[row["repository"]]:
        raise SystemExit(f"FAIL: authority mapping differs for {row['repository']}")
    if not re.fullmatch(r"[0-9a-f]{40}", row["sha"]):
        raise SystemExit(f"FAIL: invalid authority SHA for {row['repository']}")

ci_rows = [row for row in rows if row["record_type"] == "ci"]
if len(ci_rows) != 13:
    raise SystemExit("FAIL: phase-zero receipt must contain all 13 reviewed CI records")
authority_sha = {row["repository"]: row["sha"] for row in authorities}
for row in ci_rows:
    if row["sha"] != authority_sha.get(row["repository"]):
        raise SystemExit(f"FAIL: CI evidence is not bound to authority SHA for {row['repository']}")
    if not row["run_id"].isdigit() or not row["attempt"].isdigit():
        raise SystemExit("FAIL: CI evidence lacks numeric run ID/attempt")
    if row["event"] != "push" or row["conclusion"] != "success":
        raise SystemExit("FAIL: CI baseline is not a successful push receipt")
    if not row["check_name"] or not row["url"]:
        raise SystemExit("FAIL: CI evidence lacks check name or URL")

deferred = [row for row in rows if row["record_type"] == "deferred-pr"]
if len(deferred) != 7 or any(
    row["terminal_disposition"] != "deferred-separate-dependency-review" for row in deferred
):
    raise SystemExit("FAIL: receipt must contain the exact seven deferred dependency PR records")
PY

printf 'Play release sealing guardrails passed.\n'
