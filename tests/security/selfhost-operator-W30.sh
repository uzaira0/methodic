#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
WORK_DIR=/home/opt/chronicle_work/launch-audit-1003/sol/webselfhost-logs
RUN_DIR="$(mktemp -d "${WORK_DIR}/W30.XXXXXX")"
trap 'rm -rf -- "$RUN_DIR"' EXIT
INSTALL_ROOT="${RUN_DIR}/releases"
CURRENT_BUNDLE="${INSTALL_ROOT}/current"
CURRENT_SELFHOST="${CURRENT_BUNDLE}/selfhost"
FIXTURE_DIR="${RUN_DIR}/curl-fixtures"
BIN_DIR="${RUN_DIR}/bin"
OUTPUT="${RUN_DIR}/update.log"

fail() { echo "FAIL W30: $*" >&2; exit 1; }

mkdir -p "$CURRENT_SELFHOST" "$FIXTURE_DIR" "$BIN_DIR"
cp "${ROOT_DIR}/selfhost/chronicle" "${CURRENT_SELFHOST}/chronicle"
chmod 0755 "${CURRENT_SELFHOST}/chronicle"
printf '{"release_version":"1.0.0","source_revision":"synthetic-current"}\n' \
  >"${CURRENT_BUNDLE}/release-manifest.json"
cat >"${CURRENT_SELFHOST}/.env" <<'EOF'
COMPOSE_PROJECT_NAME=chronicle-w30
CHRONICLE_STATE_DIR=.
MOBILE_SIGNING_ENABLED=false
MOBILE_SIGNING_REQUIRED=false
EOF
chmod 0600 "${CURRENT_SELFHOST}/.env"

cat >"${BIN_DIR}/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
case "$url" in
  https://updates.invalid/latest.json) fixture=latest.json ;;
  https://updates.invalid/chronicle-selfhost-1.3.0.tar.gz) fixture=chronicle-selfhost-1.3.0.tar.gz ;;
  https://updates.invalid/chronicle-selfhost-1.3.0.tar.gz.sha256) fixture=chronicle-selfhost-1.3.0.tar.gz.sha256 ;;
  *) echo "unexpected URL in local curl fixture: $url" >&2; exit 9 ;;
esac
cat "${W30_FIXTURE_DIR}/${fixture}"
SH
chmod 0755 "${BIN_DIR}/curl"

python3 - "$FIXTURE_DIR" <<'PY'
from pathlib import Path
import hashlib
import io
import json
import sys
import tarfile

root = Path(sys.argv[1])
name = "chronicle-selfhost-1.3.0"
notes = """# Changelog

## [Unreleased]

## [1.3.0]
- Operator note release 1.3.

## [1.2.0]
- Operator note release 1.2.

## [1.1.0]
- Operator note release 1.1.

## [1.0.0]
- Current release note must not be repeated.
"""
operator = b"#!/usr/bin/env bash\nprintf 'HANDOFF EXECUTED\\n'\nprintf '%s\\0' \"$0\" \"$@\" >\"$W30_HANDOFF_RECORD\"\n"
archive_path = root / f"{name}.tar.gz"
with tarfile.open(archive_path, "w:gz") as archive:
    for member_name, data, mode in (
        (f"{name}/release-manifest.json",
         json.dumps({"release_version": "1.3.0", "source_revision": "synthetic-target"}).encode(), 0o644),
        (f"{name}/selfhost/chronicle", operator, 0o755),
        (f"{name}/CHANGELOG.md", notes.encode(), 0o644),
    ):
        member = tarfile.TarInfo(member_name)
        member.size = len(data)
        member.mode = mode
        archive.addfile(member, io.BytesIO(data))

digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
(root / f"{name}.tar.gz.sha256").write_text(f"{digest}  {name}.tar.gz\n", encoding="ascii")
(root / "latest.json").write_text(json.dumps({
    "tag_name": "v1.3.0",
    "body": "release page summary must not replace bundled notes",
    "assets": [
        {"name": f"{name}.tar.gz", "browser_download_url": f"https://updates.invalid/{name}.tar.gz"},
        {"name": f"{name}.tar.gz.sha256", "browser_download_url": f"https://updates.invalid/{name}.tar.gz.sha256"},
    ],
}), encoding="utf-8")
PY

if (
  cd "$CURRENT_SELFHOST"
  env \
    "PATH=${BIN_DIR}:${PATH}" \
    "W30_FIXTURE_DIR=${FIXTURE_DIR}" \
    "W30_HANDOFF_RECORD=${RUN_DIR}/handoff.args" \
    CHRONICLE_RELEASES_URL=https://updates.invalid/latest.json \
    ./chronicle update
) >"$OUTPUT" 2>&1; then
  :
else
  cat "$OUTPUT" >&2
  fail 'verified synthetic update did not complete its handoff'
fi

for note in 'Operator note release 1.3.' 'Operator note release 1.2.' 'Operator note release 1.1.'; do
  grep -Fq "$note" "$OUTPUT" || fail "verified changelog omitted an intervening release: $note"
done
if grep -Fq 'Current release note must not be repeated' "$OUTPUT"; then
  fail 'current release notes were included in the update range'
fi
python3 - "$OUTPUT" "${RUN_DIR}/handoff.args" <<'PY'
from pathlib import Path
import sys

output = Path(sys.argv[1]).read_text()
handoff = Path(sys.argv[2]).read_bytes().split(b"\0")
positions = [output.index(note) for note in (
    "Operator note release 1.3.",
    "Operator note release 1.2.",
    "Operator note release 1.1.",
)]
assert positions == sorted(positions), "intervening changelog entries were not shown newest-first"
assert output.index("Handing off to ") > positions[-1], "upgrade handoff began before the notes were shown"
assert output.index("HANDOFF EXECUTED") > positions[-1], "upgrade operator ran before the notes were shown"
assert handoff[-1] == b"" and handoff[0].endswith(b"selfhost/chronicle")
assert handoff[1:3] == [b"upgrade", b"--from"]
PY
echo 'PASS W30: checksum-verified changelog notes for every intervening release precede update handoff'
