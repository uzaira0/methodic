#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "${ROOT_DIR}/tests/security/lib/selfhost-fixtures.sh"
WORK_DIR="${SELFHOST_OPERATOR_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-operator-W29}"
mkdir -p "$WORK_DIR"
RUN_DIR=$(mktemp -d "${WORK_DIR}/W29.XXXXXX")
trap 'rm -rf -- "$RUN_DIR"' EXIT
ARCHIVE="${SELFHOST_SMOKE_PREVIOUS_RELEASE_ARCHIVE:-${WORK_DIR}/chronicle-selfhost-2026.9.22.tar.gz}"
CHECKSUM="${SELFHOST_SMOKE_PREVIOUS_RELEASE_SHA256_FILE:-${ARCHIVE}.sha256}"
SMOKE="$ROOT_DIR/tests/smoke/selfhost-release-smoke.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -f "$ARCHIVE" && -f "$CHECKSUM" ]] ||
  fail 'provide the published 2026.9.22 archive and checksum with SELFHOST_SMOKE_PREVIOUS_RELEASE_ARCHIVE and SELFHOST_SMOKE_PREVIOUS_RELEASE_SHA256_FILE'

grep -Fq 'SELFHOST_SMOKE_PREVIOUS_RELEASE_ARCHIVE' "$SMOKE" ||
  fail 'release smoke cannot select a published previous-release artifact'
grep -Fq 'SELFHOST_SMOKE_PREVIOUS_RELEASE_SHA256_FILE' "$SMOKE" ||
  fail 'release smoke does not verify the prior artifact checksum sidecar'
grep -Fq './chronicle update' "$SMOKE" ||
  fail 'release smoke does not exercise the old CLI update handoff'

python3 - "$ARCHIVE" "$CHECKSUM" "$RUN_DIR" "$(git -C "$ROOT_DIR" rev-parse HEAD)" <<'PY'
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
import tarfile

archive_path, checksum_path, work_path = map(Path, sys.argv[1:4])
current_revision = sys.argv[4]
work = Path(work_path)
expected_name = archive_path.name
digest_text = Path(checksum_path).read_text(encoding="ascii").strip().split()
assert len(digest_text) == 2 and digest_text[1].lstrip("*") == expected_name
assert hashlib.sha256(archive_path.read_bytes()).hexdigest() == digest_text[0]

with tarfile.open(archive_path, "r:gz") as archive:
    members = archive.getmembers()
    manifests = [m for m in members if m.name.endswith("/release-manifest.json") and m.isfile()]
    assert len(manifests) == 1
    manifest_member = manifests[0]
    root = manifest_member.name.removesuffix("/release-manifest.json")
    manifest = json.load(archive.extractfile(manifest_member))
    old_version = manifest["release_version"]
    old_revision = manifest["source_revision"]
    assert old_version == "2026.9.22", old_version
    assert old_revision != current_revision, "fixture must prove distinct published/current revisions"
    for member in members:
        path = PurePosixPath(member.name)
        assert not path.is_absolute() and ".." not in path.parts and path.parts[0] == root
        assert member.isdir() or member.isfile(), f"unsupported archived member type: {member.name}"
    operator_name = f"{root}/selfhost/chronicle"
    operator_members = [m for m in members if m.name == operator_name and m.isfile()]
    assert len(operator_members) == 1 and operator_members[0].mode & 0o111
    target = work / root / "selfhost"
    target.mkdir(parents=True)
    (target / "chronicle").write_bytes(archive.extractfile(operator_members[0]).read())
    (target / "chronicle").chmod(operator_members[0].mode & 0o777)
    (work / root / "release-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    (target / ".published-marker").write_text(f"published release {old_version}\n", encoding="utf-8")

old_bundle = work / root / "selfhost"
(work / "old-bundle.path").write_text(str(old_bundle), encoding="utf-8")
PY

write_update_fixture "$RUN_DIR/fixture" 2026.9.22 v2026.10.3 valid \
  "$(git -C "$ROOT_DIR" rev-parse HEAD)" '' 'Synthetic current release fixture'
write_update_curl_fixture "$RUN_DIR/bin"

old_bundle=$(<"$RUN_DIR/old-bundle.path")
[[ -n "$old_bundle" ]] || fail 'published old marker was not staged'
export UPDATE_EXEC_RECORD="$RUN_DIR/exec-record"
export CURL_FIXTURE_DIR="$RUN_DIR/fixture"
CHRONICLE_RELEASES_URL=https://updates.invalid/latest.json \
  PATH="$RUN_DIR/bin:$PATH" bash "$old_bundle/chronicle" update >"$RUN_DIR/update.out" 2>&1 || {
  cat "$RUN_DIR/update.out" >&2
  fail 'published previous CLI failed its synthetic update handoff'
}
python3 - "$RUN_DIR/exec-record" "$old_bundle" "$RUN_DIR" <<'PY'
from pathlib import Path
import sys

record = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
old_bundle = Path(sys.argv[2]).resolve()
assert record[1:] == ["upgrade", "--from", str(old_bundle)], record
assert (old_bundle / ".published-marker").read_text(encoding="utf-8").strip() == "published release 2026.9.22"
target = Path(sys.argv[3]) / "chronicle-selfhost-2026.10.3"
assert (target / "release-manifest.json").is_file(), "verified target release was not extracted"
assert (Path(sys.argv[3]) / "chronicle-selfhost-2026.10.3.tar.gz").is_file(), "release archive was not downloaded"
PY
echo 'PASS: published previous CLI downloads, verifies, extracts, and hands off with distinct revisions'
