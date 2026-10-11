#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "${ROOT_DIR}/tests/security/lib/selfhost-fixtures.sh"
for tool in python3 ssh-keygen; do
  command -v "$tool" >/dev/null || { echo "FAIL: missing tool: $tool" >&2; exit 1; }
done
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
/bin/cp -R "${ROOT_DIR}/selfhost/chronicle_ops" "$RUN_DIR/releases/current/selfhost/"
prepare_update_signer "$RUN_DIR" "$RUN_DIR/releases/current/selfhost"
operator="$RUN_DIR/releases/current/selfhost/chronicle"
printf 'COMPOSE_PROJECT_NAME=chronicle-selfhost\nCHRONICLE_STATE_DIR=.\nMIN_FREE_DISK_GIB=0\n' >"$RUN_DIR/releases/current/selfhost/.env"
chmod 600 "$RUN_DIR/releases/current/selfhost/.env"
export UPDATE_EXEC_RECORD="$RUN_DIR/exec-argv"
export CHRONICLE_RELEASES_URL='https://updates.invalid/latest.json'
write_update_curl_fixture "$RUN_DIR/bin"
export PATH="$RUN_DIR/bin:$PATH"
export CURL_FIXTURE_DIR="$RUN_DIR/http"

fixture() {
  printf '{"release_version":"%s"}\n' "$1" >"$RUN_DIR/releases/current/release-manifest.json"
  write_update_fixture "$RUN_DIR/http" "$@"
  sign_update_fixture "$RUN_DIR" "${2#v}" "${3:-valid}"
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
if grep -Fq 'BREAKING: fixture release note' "$RUN_DIR/output"; then fail '--check printed unauthenticated release notes'; fi
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

fixture 1.2.3 v1.2.4 valid
printf '%s\n' 'tampered signature' >"$RUN_DIR/http/chronicle-selfhost-1.2.4.tar.gz.sha256.sig"
expect_status 1
grep -Fq 'invalid release signature' "$RUN_DIR/output" || fail 'missing signature diagnostic'
[[ ! -e "$RUN_DIR/releases/chronicle-selfhost-1.2.4" && ! -e "$UPDATE_EXEC_RECORD" ]] \
  || fail 'tampered signature reached extraction or exec'
echo 'PASS: tampered signature fails before extraction or exec'

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

expect_status 0
grep -Fq 'Handing off to' "$RUN_DIR/output" || fail 'failed handoff could not be retried'
echo 'PASS: verified clean extraction is reused after failed handoff'
touch "$new/selfhost/.env"
expect_status 1
grep -Fq 'refusing to overwrite' "$RUN_DIR/output" || fail 'existing bundle was not protected'
echo 'PASS: existing release paths are never overwritten'
rm "$new/selfhost/.env"
printf '\n# damage\n' >>"$new/selfhost/restore.sh"
expect_status 1
grep -Fq 'checksum mismatch' "$RUN_DIR/output" || fail 'damaged retained extraction reached handoff'
[[ -d "$new" ]] || fail 'retry removed an existing extraction'

# Ctrl-C during the download must clean up: a partial archive would block every retry.
fixture 1.2.3 v1.2.5 valid
CURL_FIXTURE_INTERRUPT_NAME='chronicle-selfhost-1.2.5.tar.gz' expect_status 1
grep -Fq 'interrupted by signal' "$RUN_DIR/output" || { cat "$RUN_DIR/output" >&2; fail 'interrupt was not reported'; }
[[ ! -e "$RUN_DIR/releases/chronicle-selfhost-1.2.5.tar.gz" && ! -e "$RUN_DIR/releases/chronicle-selfhost-1.2.5" ]] \
  || fail 'interrupted update left a partial download behind'
expect_status 0
echo 'PASS: interrupted download is cleaned up and the retry succeeds'
echo 'PASS: selfhost-update-command'
