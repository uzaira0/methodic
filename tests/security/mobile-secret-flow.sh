#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RUN_PARENT="${MOBILE_SECRET_FLOW_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/mobile-secret-flow}"

fail() {
  printf 'mobile secret-flow test failed: %s\n' "$*" >&2
  exit 1
}

[[ "$RUN_PARENT" == /* ]] || fail "test run parent must be absolute"
case "$RUN_PARENT" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
    fail "test run parent must not use a system temporary directory"
    ;;
esac

umask 077
/bin/mkdir -p "$RUN_PARENT"
RUN_DIR="$(/usr/bin/mktemp -d "${RUN_PARENT}/run.XXXXXX")"
/bin/chmod 0700 "$RUN_DIR"
trap '/bin/rm -rf -- "$RUN_DIR"' EXIT

FIXTURE="${RUN_DIR}/chronicle-ios"
COMMANDS="${RUN_DIR}/commands"
ARGS_LOG="${RUN_DIR}/child-argv.log"
OUTPUT="${RUN_DIR}/output.log"
SECRET_FILE="${RUN_DIR}/fixture-secret"
SECRET='fixture-mobile-secret-never-in-argv-or-env-0123456789'
/bin/mkdir -p "$FIXTURE/scripts" "$FIXTURE/secrets" "$FIXTURE/chronicle/Config" "$COMMANDS"
/bin/cp "${ROOT_DIR}/chronicle-ios/scripts/generate-ios-config.sh" "$FIXTURE/scripts/"
/bin/cp "${ROOT_DIR}/chronicle-ios/scripts/decrypt-ios-secret.sh" "$FIXTURE/scripts/"
/bin/chmod 0755 "$FIXTURE/scripts/generate-ios-config.sh" "$FIXTURE/scripts/decrypt-ios-secret.sh"
printf '%s' "$SECRET" >"$SECRET_FILE"
printf 'fixture ciphertext\n' >"$FIXTURE/secrets/mobile-signing-secret.age"
printf 'fixture identity\n' >"${RUN_DIR}/age-key.txt"
/bin/chmod 0600 "$SECRET_FILE" "${RUN_DIR}/age-key.txt"

cat >"${COMMANDS}/fixture-command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

for key in MOBILE_SIGNING_SECRET PRODUCTION_MOBILE_SIGNING_SECRET; do
  [[ -z "${!key+x}" ]] || {
    printf 'secret variable %s reached child environment\n' "$key" >&2
    exit 81
  }
done
expected="$(/bin/cat "${MOBILE_SECRET_FLOW_EXPECTED_FILE}")"
for argument in "$@"; do
  [[ "$argument" != *"$expected"* ]] || {
    printf 'secret reached child argv\n' >&2
    exit 82
  }
done
name="$(basename "$0")"
printf '%s\n' "$name" >>"${MOBILE_SECRET_FLOW_ARGS_LOG}"
case "$name" in
  age) /bin/cat "${MOBILE_SECRET_FLOW_EXPECTED_FILE}" ;;
  cat|chmod|mkdir|mv) exec "/bin/${name}" "$@" ;;
  mktemp) exec /usr/bin/mktemp "$@" ;;
  *) exit 83 ;;
esac
EOF
/bin/chmod 0755 "${COMMANDS}/fixture-command"
for command in age cat chmod mkdir mktemp mv; do
  /bin/ln -s fixture-command "${COMMANDS}/${command}"
done

PATH="${COMMANDS}:${PATH}" \
MOBILE_SECRET_FLOW_EXPECTED_FILE="$SECRET_FILE" \
MOBILE_SECRET_FLOW_ARGS_LOG="$ARGS_LOG" \
CHRONICLE_AGE_KEY="${RUN_DIR}/age-key.txt" \
  /bin/bash "$FIXTURE/scripts/decrypt-ios-secret.sh" >"$OUTPUT" 2>&1 \
  || fail "sealed-secret decrypt/generate fixture failed"

CONFIG="${FIXTURE}/chronicle/Config/Chronicle.local.xcconfig"
[[ -f "$CONFIG" && ! -L "$CONFIG" ]] || fail "generator did not create the local xcconfig"
mode="$(stat -c '%a' "$CONFIG" 2>/dev/null || stat -f '%Lp' "$CONFIG")"
[[ "$mode" == 600 ]] || fail "generated xcconfig mode is $mode, expected 600"
python3 - "$CONFIG" "$SECRET_FILE" "$OUTPUT" "$ARGS_LOG" <<'PY'
from pathlib import Path
import sys

config, secret_file, output, args_log = map(Path, sys.argv[1:])
secret = secret_file.read_text(encoding="utf-8")
assignment = f"MOBILE_SIGNING_SECRET = {secret}"
lines = config.read_text(encoding="utf-8").splitlines()
if lines.count(assignment) != 1:
    raise SystemExit("generated xcconfig does not contain the decrypted secret exactly once")
if secret in output.read_text(encoding="utf-8"):
    raise SystemExit("secret was printed")
if secret in args_log.read_text(encoding="utf-8"):
    raise SystemExit("secret reached child argv")
PY
for required_child in age cat mkdir mktemp chmod mv; do
  grep -Fqx "$required_child" "$ARGS_LOG" || fail "$required_child custody probe did not run"
done

printf 'mobile secret-flow test passed\n'
