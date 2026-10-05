#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
WORK_DIR=/home/opt/chronicle_work/launch-audit-1003/sol/webselfhost-logs
RUN_DIR=$(mktemp -d "${WORK_DIR}/W29.XXXXXX")
trap 'rm -rf -- "$RUN_DIR"' EXIT
ARCHIVE=/home/opt/chronicle_work/launch-audit/selfhost-upgrade/update-drill-0918-0922/chronicle-selfhost-2026.9.22.tar.gz
CHECKSUM="${ARCHIVE}.sha256"
SMOKE="$ROOT_DIR/tests/smoke/selfhost-release-smoke.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

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
import re
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
new_version = "2026.10.3"
new_name = f"chronicle-selfhost-{new_version}"
fixture = work / "fixture"
fixture.mkdir()
archive_bytes = work / "target.tar.gz"
stub = b'#!/usr/bin/env bash\nset -euo pipefail\nprintf "%s\\n" "$0" "$@" >"$UPDATE_EXEC_RECORD"\n'
with tarfile.open(archive_bytes, "w:gz") as archive:
    for name, data, mode in (
        (f"{new_name}/release-manifest.json",
         json.dumps({"release_version": new_version, "source_revision": current_revision}).encode(), 0o644),
        (f"{new_name}/selfhost/chronicle", stub, 0o755),
        (f"{new_name}/CHANGELOG.md", f"## [{new_version}]\n\n- Current fixture release.\n".encode(), 0o644),
    ):
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mode = mode
        archive.addfile(info, __import__("io").BytesIO(data))

archive_name = f"{new_name}.tar.gz"
(fixture / archive_name).write_bytes(archive_bytes.read_bytes())
target_digest = hashlib.sha256(archive_bytes.read_bytes()).hexdigest()
(fixture / f"{archive_name}.sha256").write_text(f"{target_digest}  {archive_name}\n", encoding="ascii")
(fixture / "latest.json").write_text(json.dumps({
    "tag_name": f"v{new_version}",
    "assets": [
        {"name": archive_name, "browser_download_url": f"https://updates.invalid/{archive_name}"},
        {"name": f"{archive_name}.sha256", "browser_download_url": f"https://updates.invalid/{archive_name}.sha256"},
    ],
    "body": "Synthetic current release fixture",
}), encoding="utf-8")
(fixture / "latest.json.url").write_text("https://updates.invalid/latest.json\n", encoding="ascii")
PY

mkdir -p "$RUN_DIR/bin"
cat >"$RUN_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
case "$url" in
  https://updates.invalid/latest.json) cat "$UPDATE_FIXTURE/latest.json" ;;
  https://updates.invalid/*.sha256) cat "$UPDATE_FIXTURE/${url##*/}" ;;
  https://updates.invalid/*.tar.gz) cat "$UPDATE_FIXTURE/${url##*/}" ;;
  *) echo "unexpected synthetic URL: $url" >&2; exit 22 ;;
esac
SH
chmod +x "$RUN_DIR/bin/curl"

old_bundle=$(<"$RUN_DIR/old-bundle.path")
[[ -n "$old_bundle" ]] || fail 'published old marker was not staged'
export UPDATE_EXEC_RECORD="$RUN_DIR/exec-record"
export UPDATE_FIXTURE="$RUN_DIR/fixture"
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
