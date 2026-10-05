#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
command -v python3 >/dev/null || { echo 'FAIL: missing tool: python3' >&2; exit 1; }
RUN_PARENT="${SELFHOST_UPDATE_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-update-command}"
[[ "$RUN_PARENT" == /* ]] || { echo 'FAIL: test run parent must be absolute' >&2; exit 1; }
case "$RUN_PARENT" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
    echo 'FAIL: test run parent must not use a system temporary directory' >&2
    exit 1
    ;;
esac
[[ ! -L "$RUN_PARENT" ]] || { echo 'FAIL: test run parent must not be a symlink' >&2; exit 1; }
mkdir -p "$RUN_PARENT"
RUN_DIR=$(mktemp -d "${RUN_PARENT}/run.XXXXXX")
cleanup() {
  chmod -R u+rwX -- "$RUN_DIR" 2>/dev/null || true
  rm -rf -- "$RUN_DIR"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$RUN_DIR/http" "$RUN_DIR/releases/current/selfhost" "$RUN_DIR/bin"
cp "$ROOT_DIR/selfhost/chronicle" "$RUN_DIR/releases/current/selfhost/chronicle"
operator="$RUN_DIR/releases/current/selfhost/chronicle"
export UPDATE_EXEC_RECORD="$RUN_DIR/exec-argv"
export CHRONICLE_RELEASES_URL='https://updates.invalid/latest.json'
cat >"$RUN_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
name="${url##*/}"
if [[ -n "${CURL_FIXTURE_INTERRUPT_NAME:-}" && "$name" == "$CURL_FIXTURE_INTERRUPT_NAME" ]]; then
  printf 'partial archive'
  kill -INT "$PPID"
  sleep 5
  exit 130
fi
case "$url" in
  https://updates.invalid/latest.json) cat "$CURL_FIXTURE_DIR/latest.json" ;;
  https://updates.invalid/*.sha256|https://updates.invalid/*.tar.gz)
    cat "$CURL_FIXTURE_DIR/$name"
    ;;
  *) echo "unexpected synthetic update URL: $url" >&2; exit 22 ;;
esac
SH
chmod +x "$RUN_DIR/bin/curl"
export PATH="$RUN_DIR/bin:$PATH"
export CURL_FIXTURE_DIR="$RUN_DIR/http"

fixture() {
  python3 - "$RUN_DIR" "$@" <<'PY'
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile

root = Path(sys.argv[1])
current, latest, mode = sys.argv[2:]
(root / "releases/current/release-manifest.json").write_text(json.dumps({"release_version": current}))
name = "chronicle-selfhost-" + latest.removeprefix("v")
archive_path = root / "http" / (name + ".tar.gz")
stub = b'#!/usr/bin/env bash\nset -euo pipefail\nprintf "%s\\n" "$0" "$@" > "$UPDATE_EXEC_RECORD"\n'
changelog = (
    "# Changelog\n\n"
    f"## [{latest.removeprefix('v')}]\n- Synthetic release notes.\n\n"
    f"## [{current}]\n- Existing release notes.\n"
).encode()
with tarfile.open(archive_path, "w:gz") as archive:
    files = [
        (name + "/selfhost/chronicle", stub, 0o755),
        (name + "/CHANGELOG.md", changelog, 0o644),
    ]
    if mode != "missing-manifest":
        files.append((name + "/release-manifest.json",
                      json.dumps({"release_version": latest.removeprefix("v")}).encode(), 0o644))
    if mode == "traversal":
        files.append((name + "/../escaped", b"must not extract", 0o644))
    if mode == "too-many-members":
        files.extend((f"{name}/filler/{i}", b"", 0o644) for i in range(20001))
    for path, data, permissions in files:
        member = tarfile.TarInfo(path)
        member.size = len(data)
        member.mode = permissions
        archive.addfile(member, io.BytesIO(data))
digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
if mode == "corrupt":
    digest = "0" * 64
archive_path.with_suffix(".gz.sha256").write_text(f"{digest}  {archive_path.name}\n")
assets = [{"name": filename, "browser_download_url": f"https://updates.invalid/{filename}"}
          for filename in (archive_path.name, archive_path.name + ".sha256")]
(root / "http/latest.json").write_text(json.dumps({
    "tag_name": latest, "assets": assets,
    "body": "### Security\n- BREAKING: fixture release note"}))
PY
}

expect_status() {
  local expected=$1 actual=0
  shift
  bash "$operator" update "$@" >"$RUN_DIR/output" 2>&1 || actual=$?
  if [[ "$actual" -ne "$expected" ]]; then
    cat "$RUN_DIR/output" >&2
    fail "expected exit $expected, got $actual"
  fi
}

fixture 1.2.3 v1.2.3 valid
expect_status 0 --check
grep -Fq 'Current: 1.2.3; latest: v1.2.3' "$RUN_DIR/output" || fail 'missing version report'
grep -Fq 'BREAKING: fixture release note' "$RUN_DIR/output" || fail '--check did not print release notes'
expect_status 1
grep -Fq 'not newer' "$RUN_DIR/output" || fail 'equal release was not refused'
echo 'PASS: equal version --check exits 0; update refuses equal version'

fixture 1.2.3 v1.10.0 valid
expect_status 3 --check
[[ ! -e "$RUN_DIR/releases/chronicle-selfhost-1.10.0.tar.gz" ]] || fail '--check downloaded assets'
echo 'PASS: newer version --check exits 3 without downloading'

fixture 1.10.0 v1.2.3 valid
expect_status 0 --check
expect_status 1
fixture 1.2.3-rc.2 v1.2.3-rc.10 valid
expect_status 3 --check
fixture 1.2.3-rc.10 v1.2.3 valid
expect_status 3 --check
echo 'PASS: numeric and prerelease ordering; downgrade refused'

rm "$RUN_DIR/releases/current/release-manifest.json"
expect_status 1 --check
grep -Fq 'missing current release manifest' "$RUN_DIR/output" || fail 'missing manifest diagnostic'
echo 'PASS: missing current manifest fails clearly'

fixture 1.2.3 v1.2.4 corrupt
expect_status 1
grep -Fq 'bad checksum' "$RUN_DIR/output" || fail 'missing checksum diagnostic'
[[ ! -e "$RUN_DIR/releases/chronicle-selfhost-1.2.4" && ! -e "$UPDATE_EXEC_RECORD" ]] \
  || fail 'corrupt checksum reached extraction or exec'
echo 'PASS: corrupted checksum fails before extraction'

fixture 1.2.3 v1.2.4 missing-manifest
expect_status 1
grep -Fq 'missing new release manifest' "$RUN_DIR/output" || fail 'missing archive manifest diagnostic'
[[ ! -e "$RUN_DIR/releases/chronicle-selfhost-1.2.4" ]] || fail 'manifest-less archive extracted'
fixture 1.2.3 v1.2.4 traversal
expect_status 1
[[ ! -e "$RUN_DIR/releases/escaped" && ! -e "$UPDATE_EXEC_RECORD" ]] || fail 'unsafe archive extracted'
grep -Fq 'unsafe or duplicate' "$RUN_DIR/output" || fail 'missing unsafe archive diagnostic'
fixture 1.2.3 v1.2.4 too-many-members
expect_status 1
grep -Fq 'too many members' "$RUN_DIR/output" || fail 'oversized archive inventory was not refused'
[[ ! -e "$RUN_DIR/releases/chronicle-selfhost-1.2.4" && ! -e "$UPDATE_EXEC_RECORD" ]] \
  || fail 'oversized archive extracted'
echo 'PASS: missing new manifest, archive traversal and oversized inventory rejected before extraction'

fixture 1.2.3 v1.2.4 valid
expect_status 0
new="$RUN_DIR/releases/chronicle-selfhost-1.2.4"
[[ -f "$new/release-manifest.json" && -f "$new.tar.gz.sha256" ]] || fail 'new bundle not beside current'
for dir in "$new" "$new/selfhost"; do
  mode=$(stat -c '%a' "$dir" 2>/dev/null || stat -f '%Lp' "$dir")
  [[ "$mode" == 755 ]] || fail "extracted $dir is mode $mode; container users (config-guard) cannot search it"
done
cmp "$operator" "$ROOT_DIR/selfhost/chronicle" || fail 'current operator changed'
python3 - "$UPDATE_EXEC_RECORD" "$new/selfhost/chronicle" "$RUN_DIR/releases/current/selfhost" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_text().splitlines() == [sys.argv[2], "upgrade", "--from", sys.argv[3]]
PY
echo 'PASS: valid bundle extracted beside current; exec receives upgrade --from current/selfhost'

expect_status 1
grep -Fq 'refusing to overwrite' "$RUN_DIR/output" || fail 'existing bundle was not protected'
echo 'PASS: existing release paths are never overwritten'

# Ctrl-C during the download must clean up: a partial archive would block every retry.
fixture 1.2.3 v1.2.5 valid
CURL_FIXTURE_INTERRUPT_NAME='chronicle-selfhost-1.2.5.tar.gz' expect_status 1
grep -Fq 'interrupted by signal' "$RUN_DIR/output" || { cat "$RUN_DIR/output" >&2; fail 'interrupt was not reported'; }
[[ ! -e "$RUN_DIR/releases/chronicle-selfhost-1.2.5.tar.gz" && ! -e "$RUN_DIR/releases/chronicle-selfhost-1.2.5" ]] \
  || fail 'interrupted update left a partial download behind'
expect_status 0
echo 'PASS: interrupted download is cleaned up and the retry succeeds'
echo 'PASS: selfhost-update-command'
