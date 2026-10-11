#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "${ROOT_DIR}/tests/security/lib/selfhost-fixtures.sh"
WORK_DIR="${SELFHOST_OPERATOR_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-operator-W30}"
mkdir -p "$WORK_DIR"
RUN_DIR="$(mktemp -d "${WORK_DIR}/W30.XXXXXX")"
trap 'rm -rf -- "$RUN_DIR"' EXIT
INSTALL_ROOT="${RUN_DIR}/releases"
CURRENT_BUNDLE="${INSTALL_ROOT}/current"
CURRENT_SELFHOST="${CURRENT_BUNDLE}/selfhost"
FIXTURE_DIR="${RUN_DIR}/http"
BIN_DIR="${RUN_DIR}/bin"
OUTPUT="${RUN_DIR}/update.log"

fail() { echo "FAIL W30: $*" >&2; exit 1; }

mkdir -p "$CURRENT_SELFHOST" "$FIXTURE_DIR" "$BIN_DIR"
cp "${ROOT_DIR}/selfhost/chronicle" "${CURRENT_SELFHOST}/chronicle"
/bin/cp -R "${ROOT_DIR}/selfhost/chronicle_ops" "${CURRENT_SELFHOST}/"
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

write_update_curl_fixture "$BIN_DIR"
prepare_update_signer "$RUN_DIR" "$CURRENT_SELFHOST"
cat >"${RUN_DIR}/CHANGELOG.md" <<'NOTES'
# Changelog

## [Unreleased]

## [1.3.0]
- Operator note release 1.3.

## [1.2.0]
- Operator note release 1.2.

## [1.1.0]
- Operator note release 1.1.

## [1.0.0]
- Current release note must not be repeated.
NOTES
write_update_fixture "$FIXTURE_DIR" 1.0.0 v1.3.0 valid synthetic-target \
  "${RUN_DIR}/CHANGELOG.md" 'release page summary must not replace bundled notes'
sign_update_fixture "$RUN_DIR" 1.3.0

if (
  cd "$CURRENT_SELFHOST"
  env \
    "PATH=${BIN_DIR}:${PATH}" \
    "CURL_FIXTURE_DIR=${FIXTURE_DIR}" \
    "UPDATE_EXEC_RECORD=${RUN_DIR}/handoff.args" \
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
handoff = Path(sys.argv[2]).read_bytes().splitlines()
positions = [output.index(note) for note in (
    "Operator note release 1.3.",
    "Operator note release 1.2.",
    "Operator note release 1.1.",
)]
assert positions == sorted(positions), "intervening changelog entries were not shown newest-first"
assert output.index("Handing off to ") > positions[-1], "upgrade handoff began before the notes were shown"
assert output.index("HANDOFF EXECUTED") > positions[-1], "upgrade operator ran before the notes were shown"
assert handoff[0].endswith(b"selfhost/chronicle")
assert handoff[1:3] == [b"upgrade", b"--from"]
PY
echo 'PASS W30: checksum-verified changelog notes for every intervening release precede update handoff'
